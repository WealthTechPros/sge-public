// Known-sources register reader/checker (SPEC-108 §2.1b, #3106).
// docs/sge-sources.yaml holds POINTERS to where evidence lives (Teams chat ids,
// SharePoint paths, work-item ids, mailbox filters), never content or secrets.
//
// Dependency-free; accepts a deliberately tiny YAML subset (see the schema in
// docs/sge-sources.example.yaml). Any deviation rejects the WHOLE file with a
// fixed reason code (never raw text), so a bad entry cannot be half-injected.
//
// CLI:
//   node sge-sources.mjs summary <projectDir>   -> one JSON line (used by cortex-recall.sh)
//   node sge-sources.mjs check <file>           -> exit 0 ok | 1 rejected (code on stdout)
import { lstatSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const REL_PATH = 'docs/sge-sources.yaml'; // fixed: never configurable
export const KINDS = ['teams-chat', 'sharepoint', 'workitem', 'mailbox-filter', 'other'];
export const LIMITS = {
  fileBytes: 16384, fileEntries: 50, summaryEntries: 12,
  id: 200, description: 160, tag: 32, tags: 6, line: 280,
};
const KEYS = new Set(['kind', 'id', 'description', 'tags']);

class Reject extends Error { constructor(code) { super(code); this.code = code; } }
const rej = (code) => { throw new Reject(code); };

const UUID = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
const SECRET_RES = [
  /\b(?:ghp|gho|ghu|ghs|ghr|github_pat|sk|pk|xox[abprs]|AKIA|ASIA|AIza|eyJ)[-_A-Za-z0-9]{10,}/,
  /\bBearer\s+\S{6,}/i,
  /\b(?:password|passwd|pwd|secret|token|api[_-]?key|sig|sas|signature|access[_-]?key)\s*[:=]\s*\S+/i,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
];

// Credential markers are checked on the ORIGINAL text, so a work-item UUID can
// never mask `password=<uuid>`; the UUID exclusion applies only to the opaque-run check.
function secretCheck(text) {
  if (SECRET_RES.some((re) => re.test(text))) rej('secret-detected');
  if (/[A-Za-z0-9+_]{32,}={0,2}/.test(text.replace(UUID, ''))) rej('secret-detected');
}

// Rejects (does not redact): a credential in a pointer file is a defect to fix at source.
function vet(value, max) {
  if (value.length > max) rej('value-too-long');
  if (/[\p{Cc}\p{Zl}\p{Zp}]/u.test(value)) rej('control-char');
  secretCheck(value);
  const bare = value.replace(UUID, '');
  if (/[A-Za-z0-9+_]{32,}={0,2}/.test(bare)) rej('secret-detected'); // long opaque run
  for (const m of bare.matchAll(/\b([a-z][a-z0-9+.-]*):\/\/(\S*)/gi)) {
    const scheme = m[1].toLowerCase();
    if (scheme !== 'https' && scheme !== 'http') rej('bad-url');
    const rest = m[2];
    const authority = rest.split(/[/?#]/)[0];
    if (authority.includes('@')) rej('url-userinfo');
    if (/[?#]/.test(rest)) rej('url-query');
  }
}

function scalar(raw) {
  let v = raw.trim();
  if (v === '' || /^[|>&*!%`]/.test(v)) rej('malformed');
  if (v[0] === '"' || v[0] === "'") {
    const q = v[0];
    if (v.length < 2 || v[v.length - 1] !== q) rej('malformed');
    v = v.slice(1, -1);
    if (q === '"') { try { v = JSON.parse('"' + v + '"'); } catch { rej('malformed'); } }
  } else if (/^[[{]/.test(v)) rej('malformed');
  return v;
}

function parseTags(raw) {
  const v = raw.trim();
  if (!/^\[.*\]$/.test(v)) rej('malformed');
  const inner = v.slice(1, -1).trim();
  if (!inner) return [];
  return inner.split(',').map((t) => scalar(t));
}

export function parse(text) {
  if (Buffer.byteLength(text, 'utf8') > LIMITS.fileBytes) rej('oversize');
  const entries = [];
  let cur = null, sawSources = false, sawVersion = false;
  for (const rawLine of text.replace(/^﻿/, '').split(/\r?\n/)) {
    if (/\t/.test(rawLine)) rej('malformed');
    const t = rawLine.trim();
    if (t.startsWith('#')) { secretCheck(t); continue; }
    if (t === '') continue;
    let m;
    if ((m = /^version:\s*(.+)$/.exec(rawLine))) {
      if (sawVersion || scalar(m[1]) !== '1') rej('malformed');
      sawVersion = true; continue;
    }
    if ((m = /^sources:\s*(.*)$/.exec(rawLine))) {
      if (sawSources) rej('malformed');
      sawSources = true;
      if (m[1].trim() === '[]') continue;
      if (m[1].trim() !== '') rej('malformed');
      continue;
    }
    if (!sawSources) rej('malformed');
    if ((m = /^\s+-\s+([a-z]+):\s*(.*)$/.exec(rawLine))) {
      cur = {}; entries.push(cur);
      if (entries.length > LIMITS.fileEntries) rej('too-many-entries');
      setKey(cur, m[1], m[2]);
    } else if ((m = /^\s{2,}([a-z]+):\s*(.*)$/.exec(rawLine)) && cur) {
      setKey(cur, m[1], m[2]);
    } else rej('malformed');
  }
  return entries.map(finish);
}

function setKey(obj, key, raw) {
  if (!KEYS.has(key) || key in obj) rej('malformed');
  obj[key] = key === 'tags' ? parseTags(raw) : scalar(raw);
}

function finish(e) {
  if (!KINDS.includes(e.kind)) rej('bad-kind');
  if (!e.id || !e.description) rej('malformed');
  vet(e.id, LIMITS.id);
  vet(e.description, LIMITS.description);
  const tags = e.tags || [];
  if (tags.length > LIMITS.tags) rej('too-many-tags');
  for (const t of tags) { if (!/^[A-Za-z0-9._-]+$/.test(t)) rej('malformed'); vet(t, LIMITS.tag); }
  return { kind: e.kind, id: e.id, description: e.description, tags };
}

// Returns {status:'ok'|'empty'|'absent'|'rejected', reason?, entries?}.
export function load(projectDir) {
  const file = join(projectDir, REL_PATH);
  try {
    let st;
    try { st = lstatSync(file); } catch { return { status: 'absent' }; }
    if (st.isSymbolicLink() || !st.isFile()) rej('symlink');
    if (st.size > LIMITS.fileBytes) rej('oversize');
    const entries = parse(readFileSync(file, 'utf8'));
    return entries.length ? { status: 'ok', entries } : { status: 'empty' };
  } catch (e) {
    return { status: 'rejected', reason: e instanceof Reject ? e.code : 'unreadable' };
  }
}

export function summarise(entries) {
  const shown = entries.slice(0, LIMITS.summaryEntries).map((e) => {
    // Truncate the description BEFORE quoting so the closing quote always survives.
    const pre = `- [${e.kind}] ${e.id}: `;
    const fmt = (d, tg) => `${pre}${JSON.stringify(d)}${tg.length ? ` {${tg.join(',')}}` : ''}`;
    let line = fmt(e.description, e.tags);
    if (line.length > LIMITS.line) {
      let tg = e.tags;
      if (fmt('…', tg).length > LIMITS.line) tg = [];
      let d = e.description;
      while (d.length && fmt(`${d}…`, tg).length > LIMITS.line) d = d.slice(0, -1);
      line = fmt(`${d}…`, tg);
    }
    return line;
  });
  return { lines: shown, omitted: Math.max(0, entries.length - shown.length) };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [cmd, arg] = process.argv.slice(2);
  try {
    if (cmd === 'summary') {
      const r = load(arg || process.cwd());
      const out = { status: r.status };
      if (r.reason) out.reason = r.reason;
      if (r.entries) Object.assign(out, summarise(r.entries));
      process.stdout.write(JSON.stringify(out) + '\n');
    } else if (cmd === 'check') {
      const abs = arg || '';
      const st = (() => { try { return lstatSync(abs); } catch { return null; } })();
      if (!st || !st.isFile()) { process.stdout.write('rejected: absent\n'); process.exit(1); }
      try {
        const n = parse(readFileSync(abs, 'utf8')).length;
        process.stdout.write(`ok: ${n} entries\n`);
      } catch (e) {
        process.stdout.write(`rejected: ${e instanceof Reject ? e.code : 'unreadable'}\n`);
        process.exit(1);
      }
    } else { process.stdout.write('usage: sge-sources.mjs summary <dir> | check <file>\n'); process.exit(2); }
  } catch { process.stdout.write('{"status":"rejected","reason":"unreadable"}\n'); }
}
