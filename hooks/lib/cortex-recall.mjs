// Bounded, fail-open Cortex read for hooks/cortex-recall.sh (SPEC-108 §2.1, #3101).
// Spawns the vendored sge-memory MCP bundle over stdio (the existing Cortex
// client; no new egress, no schema or ranking change), calls read_graph once,
// and prints ONE JSON line: {status:"ok"|"empty"|"unavailable", reason?, items?}.
// Items are pointers/short facts only: type + name + a truncated, redacted,
// single-line first observation. Raw error text is never forwarded.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

const DURABLE = new Set(['pattern', 'convention', 'gotcha']);
const MAX_NAME = 80, MAX_TYPE = 40, MAX_FACT = 160;
// Pre-ask guard mode (SPEC-108 2.1c): SGE_CORTEX_PREASK_QUERY switches the one
// read from read_graph to a local-stdio search_nodes call, capped at 3 hits.
const query = process.env.SGE_CORTEX_PREASK_QUERY || '';
const MAX_ITEMS = query ? 3 : 8;
const timeoutMs = Number(process.env.SGE_CORTEX_RECALL_TIMEOUT_MS) || 4000;
const bundle = process.env.SGE_CORTEX_BUNDLE ||
  (process.env.CLAUDE_PLUGIN_ROOT && resolve(process.env.CLAUDE_PLUGIN_ROOT, 'mcp/sge-cortex/dist/sge-cortex.bundle.mjs'));

const out = (o) => { process.stdout.write(JSON.stringify(o) + '\n'); process.exit(0); };
const unavailable = (reason) => out({ status: 'unavailable', reason });

const SECRET_RES = [
  /\b(?:ghp|gho|ghu|ghs|ghr|github_pat|sk|pk|xox[abprs]|AKIA)[-_A-Za-z0-9]{12,}/g,
  /\bBearer\s+[A-Za-z0-9._~+\/=-]{8,}/gi,
  /\b(?:password|passwd|pwd|secret|token|api[_-]?key)\s*[:=]\s*\S+/gi,
  /\b[A-Za-z0-9+\/_-]{32,}={0,2}/g,
  /\b[a-z][a-z0-9+.-]*:\/\/[^\s/@]+:[^\s/@]+@/gi,
];
const clean = (s, max) => {
  let t = String(s ?? '').replace(/[\p{Cc}\p{Zl}\p{Zp}]+/gu, ' ').replace(/\s+/g, ' ').trim();
  for (const re of SECRET_RES) t = t.replace(re, '[redacted]');
  return t.length > max ? t.slice(0, max - 1) + '…' : t;
};

if (!bundle || !existsSync(bundle)) unavailable('no-bundle');

// Local-only by construction (#3125): the bundle selects its remote/broker store
// from the environment, so strip every remote selector before spawning. Only a
// local file store (or in-memory) can be reached from this hook.
const childEnv = { ...process.env };
delete childEnv.SGE_CORTEX_BROKER_URL;
const libsql = (childEnv.LIBSQL_URL || '').trim();
if (libsql && !libsql.startsWith('file:') && libsql !== ':memory:') delete childEnv.LIBSQL_URL;
const child = spawn(process.execPath, [bundle], { stdio: ['pipe', 'pipe', 'ignore'], env: childEnv });
const timer = setTimeout(() => { child.kill(); unavailable('timeout'); }, timeoutMs);
child.on('error', () => unavailable('spawn-failed'));
child.on('exit', () => unavailable('exited'));
const send = (m) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...m }) + '\n');

let buf = '';
child.stdout.on('data', (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.id === 1) {
      send({ method: 'notifications/initialized' });
      send({ id: 2, method: 'tools/call', params: query
        ? { name: 'search_nodes', arguments: { query, limit: MAX_ITEMS } }
        : { name: 'read_graph', arguments: {} } });
    } else if (m.id === 2) {
      clearTimeout(timer);
      if (m.error || m.result?.isError) { child.kill(); unavailable('error'); }
      let graph; try { graph = JSON.parse(m.result.content[0].text); } catch { child.kill(); unavailable('bad-response'); }
      const items = (graph.entities || [])
        .filter((e) => query || DURABLE.has(e.entityType))
        .slice(0, MAX_ITEMS)
        .map((e) => ({ type: clean(e.entityType, MAX_TYPE), name: clean(e.name, MAX_NAME), fact: clean((e.observations || [])[0], MAX_FACT) }));
      child.kill();
      out({ status: items.length ? 'ok' : 'empty', items });
    }
  }
});
send({ id: 1, method: 'initialize', params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'sge-cortex-recall', version: '1' } } });
