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
    const bash = process.env.SGE_BASH || (process.platform === 'win32'
      ? path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe') : 'bash');
    const discovery = spawnSync(bash,
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
    // The lease is the only claim (sge#3697): the retired sge-worktrees registry
    // never expired, so it no longer gates admission. decide-ref read the lease
    // through roc_claim_state as this session, so a lease older than
    // SGE_WT_CLAIM_TTL_MIN (default 30) is free and a fresh foreign one is not.
    // A claim that is not a regular "<owner> <epoch>" file still needs review.
    // Exactly one newline-terminated "<owner> <epoch>" line: roc_claim_state
    // reads an unterminated or extra-field claim as free.
    const claimFile = path.join(worktree, '.sge-wt-claim');
    const claimVerdict = claim => {
      const stat = fs.lstatSync(claimFile, { throwIfNoEntry: false });
      if (stat && (!stat.isFile() || stat.isSymbolicLink() || stat.size > 4096
        || !/^\S+ [0-9]+\n$/.test(fs.readFileSync(claimFile, 'utf8')))) {
        return result('needs-review', 'malformed-claim');
      }
      return ['free', 'mine'].includes(claim) ? null : result('backoff', 'live-claim-within-ttl');
    };
    const early = claimVerdict(fields.claim);
    if (early) return early;
    const head = git(worktree, ['rev-parse', 'HEAD']);
    if (operation === 'inspect') return result('inspected', 'candidate-not-admitted', { worktree, head });
    // The commit re-reads the lease under the shared lease lock (lease-lock.sh:
    // same directory, same staleness), held until COMMIT, so no lease writer can
    // publish a fresh foreign lease between that re-read and the binding.
    const lock = path.join(git(worktree, ['rev-parse', '--absolute-git-dir']), 'sge-wt-claim.lock');
    const leaseToken = acquireLeaseLock(lock);
    if (!leaseToken) return result('backoff', 'lease-lock-busy');
    try {
      const recheck = spawnSync(bash, [path.join(here, 'resume-or-create.sh'), 'claim-state', worktree],
        { encoding: 'utf8', timeout: 30000, env: { ...process.env, SGE_AGENT_ID: session } });
      if (recheck.error || recheck.status !== 0) return result('needs-review', 'lease-recheck-failed');
      const late = claimVerdict(recheck.stdout.trim());
      if (late) return late;
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
    } finally { releaseLeaseLock(lock, leaseToken); }
  } finally { db.close(); }
}

// The shared lease lock (skills/worktrees/lease-lock.sh): an atomic mkdir in the
// worktree's git admin dir. Waits up to SGE_LEASE_LOCK_WAIT_MS (default 5000)
// and breaks a lock older than SGE_LEASE_LOCK_STALE_S (default 600), a crashed
// holder's. Same protocol as the shell: the holder's token file h.<pid>.<rand>
// marks its own lock instance (release only removes that instance), and a break
// is serialised by <lock>.break with the age re-read under it (CodeRabbit, #3701).
function leaseAgeMs(p) {
  try { return Date.now() - fs.statSync(p).mtimeMs; } catch { return -1; }
}

function breakStaleLeaseLock(lock, staleMs) {
  if (leaseAgeMs(lock) < staleMs) return false;
  const brk = `${lock}.break`;
  try { fs.mkdirSync(brk); } catch {
    if (leaseAgeMs(brk) >= 10000) { try { fs.rmdirSync(brk); } catch { /* another breaker */ } }
    return false;
  }
  try {
    if (leaseAgeMs(lock) < staleMs) return false;
    for (const entry of fs.readdirSync(lock)) {
      if (entry.startsWith('h.')) fs.rmSync(path.join(lock, entry), { force: true });
    }
    fs.rmdirSync(lock);
    return true;
  } catch { return false; } finally { try { fs.rmdirSync(brk); } catch { /* already gone */ } }
}

function acquireLeaseLock(lock) {
  const waitMs = Number(process.env.SGE_LEASE_LOCK_WAIT_MS || 5000);
  const staleMs = Number(process.env.SGE_LEASE_LOCK_STALE_S || 600) * 1000;
  const deadline = Date.now() + waitMs;
  const pause = new Int32Array(new SharedArrayBuffer(4));
  const token = `h.${process.pid}.${Math.random().toString(36).slice(2)}`;
  for (;;) {
    try {
      fs.mkdirSync(lock);
      try { fs.writeFileSync(path.join(lock, token), ''); } catch { try { fs.rmdirSync(lock); } catch { /* */ } return null; }
      return token;
    } catch (error) { if (error.code !== 'EEXIST') return null; }
    if (breakStaleLeaseLock(lock, staleMs)) continue;
    if (Date.now() >= deadline) return null;
    Atomics.wait(pause, 0, 0, 100);
  }
}

function releaseLeaseLock(lock, token) {
  try { fs.unlinkSync(path.join(lock, token)); } catch { return; /* broken or removed with its worktree */ }
  try { fs.rmdirSync(lock); } catch { /* removed with its worktree */ }
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
