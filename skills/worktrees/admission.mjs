#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { pathKey, stateLocation } from '../lib/local-state.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const git = (root, args) => {
  const result = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8', timeout: 10000 });
  if (result.status !== 0 || result.error) throw new Error('native discovery unavailable');
  return result.stdout.trim();
};

export async function admission(request) {
  const { operation, repository, task, session, store } = request;
  if (request.schemaVersion !== 1 || !['init', 'inspect', 'admit', 'pause', 'handoff'].includes(operation)
    || !/^[a-zA-Z0-9._-]{1,128}$/.test(request.requestId || '')
    || !path.isAbsolute(repository || '') || !path.isAbsolute(store || '')) throw new Error('invalid admission request');
  const root = fs.realpathSync.native(repository);
  const common = fs.realpathSync.native(git(root, ['rev-parse', '--path-format=absolute', '--git-common-dir']));
  const origin = git(root, ['remote', 'get-url', 'origin']);
  if (!/^https:\/\/(?:[^/@]+@)?(?:dev\.azure\.com\/[^/]+\/[^/]+\/_git\/[^/]+|github\.com\/[^/]+\/[^/]+?)(?:\.git)?\/?$/i.test(origin)) {
    throw new Error('unsupported verified repository origin');
  }
  const identity = `${pathKey(common)}\0${origin.toLowerCase().replace(/\.git\/?$/, '').replace(/\/$/, '')}`;
  const filename = stateLocation(store);
  const result = (outcome, reasonCode, extra = {}) => ({ schemaVersion: 1, requestId: request.requestId,
    repository: root, task, outcome, reasonCode, observedAt: new Date().toISOString(), ...extra });
  if (operation !== 'init' && (!/^(github:(issue|pr)|azdo:(wi|pr))\/[1-9][0-9]*$/.test(task || '')
    || !/^[a-zA-Z0-9._-]{1,128}$/.test(session || ''))) throw new Error('explicit host task and session required');
  // Read the host from the URL's authority, never a substring: a GitHub repo
  // named `dev.azure.com` (https://github.com/x/dev.azure.com/) passes the
  // origin check above and must still count as GitHub (CodeQL
  // js/incomplete-url-substring-sanitization, sge alert 880).
  const azdoOrigin = /^https:\/\/(?:[^/@]+@)?dev\.azure\.com\//i.test(origin);
  if (operation !== 'init' && (task.startsWith('azdo:') !== azdoOrigin)) {
    throw new Error('task host must match verified repository');
  }
  const { DatabaseSync } = await import('node:sqlite');
  if (operation === 'init') {
    fs.mkdirSync(path.dirname(filename), { recursive: true });
    const fd = fs.openSync(filename, 'wx', 0o600);
    fs.closeSync(fd);
    const db = new DatabaseSync(filename);
    try {
      db.exec(`PRAGMA user_version=1;
        CREATE TABLE admissions(repo TEXT NOT NULL, task TEXT NOT NULL, path TEXT NOT NULL UNIQUE,
          origin TEXT NOT NULL, owner TEXT NOT NULL, generation INTEGER NOT NULL,
          state TEXT NOT NULL, head TEXT NOT NULL, request TEXT NOT NULL, PRIMARY KEY(repo,task));`);
    } finally { db.close(); }
    return result('initialized', 'explicit-empty-store-reconcile-existing-work-before-binding');
  }
  if (!fs.existsSync(filename)) return result('blocked', 'store-missing-no-automatic-recreation');
  const db = new DatabaseSync(filename);
  try {
    db.exec('PRAGMA busy_timeout=1000');
    if (db.prepare('PRAGMA user_version').get().user_version !== 1) throw new Error('unsupported admission schema');
    const current = db.prepare('SELECT * FROM admissions WHERE repo=? AND task=?').get(identity, task);
    if (operation === 'pause' || operation === 'handoff') {
      if (!current || current.owner !== session || current.generation !== request.generation) return result('backoff', 'owner-generation-mismatch');
      if (operation === 'handoff') {
        if (current.state !== 'paused' || !/^[a-zA-Z0-9._-]{1,128}$/.test(request.successorSession || '')
          || request.successorSession === session || request.expectedHead !== current.head
          || git(current.path, ['rev-parse', 'HEAD']) !== current.head) {
          return result('needs-review', 'pause-and-exact-head-required-before-handoff');
        }
        const updated = db.prepare("UPDATE admissions SET owner=?,generation=generation+1,request=? WHERE repo=? AND task=? AND owner=? AND generation=? AND state='paused'")
          .run(request.successorSession, request.requestId, identity, task, session, request.generation);
        if (updated.changes !== 1) return result('backoff', 'concurrent-owner-change');
        return result('handed-off', 'explicit-paused-owner-transfer', { worktree: current.path, generation: current.generation + 1 });
      }
      const pausedHead = git(current.path, ['rev-parse', 'HEAD']);
      const updated = db.prepare("UPDATE admissions SET state='paused',head=? WHERE repo=? AND task=? AND owner=? AND generation=?")
        .run(pausedHead, identity, task, session, request.generation);
      if (updated.changes !== 1) return result('backoff', 'concurrent-owner-change');
      return result('paused', 'original-retained', { worktree: current.path, head: pausedHead, generation: current.generation });
    }
    const discovery = spawnSync(process.env.SGE_BASH || (process.platform === 'win32'
      ? path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe') : 'bash'),
    [path.join(here, 'resume-or-create.sh'), 'decide-ref', task, root],
    { encoding: 'utf8', timeout: 60000, env: { ...process.env, SGE_AGENT_ID: session }, maxBuffer: 1024 * 1024 });
    if (discovery.error || discovery.status !== 0) return result('needs-review', 'host-or-task-discovery-incomplete');
    const fields = Object.fromEntries(discovery.stdout.trim().split(/\r?\n/).map(line => {
      const colon = line.indexOf(':'); return [line.slice(0, colon), line.slice(colon + 1)];
    }));
    if (fields.verdict !== 'resume' || !fields.worktree || fields.worktree === '-') {
      return result('needs-review', 'existing-binding-required-no-automatic-create');
    }
    const worktree = fs.realpathSync.native(fields.worktree);
    if (pathKey(git(worktree, ['rev-parse', '--path-format=absolute', '--git-common-dir'])) !== pathKey(common)) {
      return result('blocked', 'foreign-native-binding');
    }
    const registry = path.join(common, 'sge-worktrees');
    if (fs.existsSync(registry)) {
      if (fs.lstatSync(registry).isSymbolicLink() || !fs.lstatSync(registry).isDirectory()) {
        return result('needs-review', 'unsafe-legacy-registration');
      }
      const entries = fs.readdirSync(registry).filter(name => name.endsWith('.entry'));
      if (entries.length > 1000) return result('needs-review', 'legacy-registration-budget-exceeded');
      for (const name of entries) {
        const entry = path.join(registry, name), stat = fs.lstatSync(entry);
        if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 65536) return result('needs-review', 'unsafe-legacy-registration');
        const record = Object.fromEntries(fs.readFileSync(entry, 'utf8').trim().split(/\r?\n/).map(line => {
          const index = line.indexOf('='); return [line.slice(0, index), line.slice(index + 1)];
        }));
        if (!record.path || !record.session) return result('needs-review', 'incomplete-legacy-registration');
        if (pathKey(record.path) === pathKey(worktree) && record.session !== session) {
          return result('needs-review', 'foreign-legacy-registration');
        }
      }
    }
    const claimFile = path.join(worktree, '.sge-wt-claim');
    const stat = fs.lstatSync(claimFile, { throwIfNoEntry: false });
    if (stat) {
      if (!stat.isFile() || stat.isSymbolicLink() || fs.readFileSync(claimFile, 'utf8').trim().split(/\s+/)[0] !== session) {
        return result('needs-review', 'foreign-or-malformed-claim-no-expiry-takeover');
      }
    }
    const head = git(worktree, ['rev-parse', 'HEAD']);
    if (operation === 'inspect') return result('inspected', 'candidate-not-admitted', { worktree, head });
    db.exec('BEGIN IMMEDIATE');
    try {
      const row = db.prepare('SELECT * FROM admissions WHERE repo=? AND task=?').get(identity, task);
      if (row && (row.owner !== session || pathKey(row.path) !== pathKey(worktree)
        || row.generation !== request.generation && row.request !== request.requestId)) {
        db.exec('ROLLBACK');
        return result('backoff', 'existing-owner-or-generation', { worktree: row.path });
      }
      if (!row) {
        if (git(worktree, ['rev-parse', 'HEAD']) !== head || git(worktree, ['symbolic-ref', '--short', 'HEAD']) !== fields.branch) {
          throw new Error('native binding changed during admission');
        }
        db.prepare('INSERT INTO admissions VALUES(?,?,?,?,?,1,?,?,?)')
          .run(identity, task, worktree, origin, session, 'active', head, request.requestId);
      } else {
        db.prepare("UPDATE admissions SET state='active',head=?,request=? WHERE repo=? AND task=?")
          .run(head, request.requestId, identity, task);
      }
      db.exec('COMMIT');
      return result('resume', 'existing-task-bound', { worktree, head, generation: row?.generation || 1,
        boundary: 'cooperating sessions only; native locks, permissions, rescue checks and unmanaged writers remain independent' });
    } catch (error) { db.exec('ROLLBACK'); throw error; }
  } finally { db.close(); }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.slice(2).join(' ') !== '--request-stdin') throw new Error('use --request-stdin');
    const text = fs.readFileSync(0, 'utf8');
    if (text.length > 65536) throw new Error('request too large');
    const result = await admission(JSON.parse(text));
    console.log(JSON.stringify(result));
    if (!['initialized', 'inspected', 'resume', 'paused', 'handed-off'].includes(result.outcome)) process.exitCode = 10;
  } catch {
    console.error('admission blocked: invalid request, unavailable engine/store or incomplete evidence; retain originals');
    process.exitCode = 1;
  }
}
