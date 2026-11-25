import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { pathKey, stateLocation } from '../lib/local-state.mjs';

const digest = value => createHash('sha256').update(value).digest('hex');
const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const here = path.dirname(fileURLToPath(import.meta.url));

export function checkConsent(plan, fingerprint, consent) {
  if (consent.fingerprint !== fingerprint || consent.noWritersToolsOrUnsavedWork !== true
    || !consent.confirmedBy?.trim() || !Number.isFinite(Date.parse(consent.confirmedAt))
    || !Array.isArray(consent.paths) || !consent.paths.length || !Array.isArray(consent.ignoredFiles)) {
    throw new Error('explicit dated human confirmation and exact plan fingerprint required');
  }
  const selected = plan.items.filter(item => consent.paths.some(p => pathKey(p) === pathKey(item.path)));
  if (selected.length !== consent.paths.length || new Set(consent.paths.map(pathKey)).size !== selected.length) {
    throw new Error('consent paths must be an exact plan subset');
  }
  const expected = selected.flatMap(item => item.ignoredFiles.map(name => ({ path: item.path, name })));
  const identity = item => `${pathKey(item.path)}\0${item.name}`;
  if (JSON.stringify(expected.map(identity).sort()) !== JSON.stringify(consent.ignoredFiles.map(identity).sort())) {
    throw new Error('separately named ignored-file consent required');
  }
  return selected;
}

function snapshot(root, run) {
  const git = args => run('git', ['-C', root, ...args]);
  return {
    registry: git(['worktree', 'list', '--porcelain']),
    refs: git(['for-each-ref', '--format=%(refname) %(objectname)']),
    stashes: git(['stash', 'list', '--format=%H']),
  };
}

export function compareRemoval(before, after, item) {
  const blocks = before.registry.trim().split(/\r?\n\r?\n/);
  const kept = blocks.filter(block => pathKey(block.split(/\r?\n/)[0].slice(9)) !== pathKey(item.path));
  const normal = text => text.trim().replaceAll('\r', '');
  if (blocks.length - kept.length !== 1 || normal(kept.join('\n\n')) !== normal(after.registry)
    || before.refs.split(/\r?\n/).filter(line => !line.startsWith(`refs/heads/${item.branch.replace(/^refs\/heads\//, '')} `)).join('\n')
      !== after.refs.replaceAll('\r', '') || before.stashes !== after.stashes) {
    throw new Error('collateral registry/ref/stash change; reconcile without another mutation');
  }
}

export async function manageExecution({ command, options, state, file, run, verifyRemoval, main }) {
  if (!options['--plan'] || !options['--fingerprint'] || !options['--approval']) throw new Error('plan, fingerprint and approval required');
  const planFile = stateLocation(options['--plan']);
  const raw = fs.readFileSync(planFile);
  const fingerprint = digest(raw);
  if (fingerprint !== options['--fingerprint']) throw new Error('reviewed plan changed');
  const plan = JSON.parse(raw);
  const approvalFile = stateLocation(options['--approval']);
  if (command === 'approve') {
    if (!options['--evidence']) throw new Error('human confirmation evidence file required; never infer consent');
    const consent = read(options['--evidence']);
    checkConsent(plan, fingerprint, consent);
    fs.writeFileSync(approvalFile, `${JSON.stringify(consent, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    return { approval: approvalFile, execution: 'not started; native tool confirmation still required' };
  }
  const consent = read(approvalFile);
  const selected = checkConsent(plan, fingerprint, consent);
  const entry = selected.find(item => pathKey(item.path) === pathKey(options['--path'] || '.'));
  const item = state.items.find(row => entry && row.id === pathKey(entry.path));
  if (!item || item.head !== entry.recoverySha) throw new Error('exact approved ledger target required');
  if (command === 'execute' && item.blocker) throw new Error('unresolved target blocker; explicit evidence invalidation required');
  const prefix = `${approvalFile}.${digest(pathKey(item.path)).slice(0, 20)}`;
  const journal = stateLocation(`${prefix}.operation.json`);
  const execution = stateLocation(`${prefix}.execution.txt`);
  const recovery = stateLocation(`${prefix}.recovery.csv`);
  const { DatabaseSync } = await import('node:sqlite');
  const lock = new DatabaseSync(stateLocation(`${file}.operations.sqlite`));
  let locked = false;
  try {
    lock.exec('PRAGMA busy_timeout=1000');
    lock.exec('BEGIN IMMEDIATE');
    locked = true;
    if (command === 'reconcile') {
      const intent = read(journal);
      if (intent.fingerprint !== fingerprint || intent.path !== item.path || intent.head !== item.head) {
        throw new Error('operation identity mismatch');
      }
      verifyRemoval(item, execution, recovery);
      compareRemoval(intent.before, snapshot(item.root, run), item);
      if (item.lane !== 'removed') await main(['record', '--state', file, '--path', item.path, '--status', 'removed',
        '--reason', 'Approved executor DONE and full recovery verified; native collateral comparison passed.',
        '--evidence', execution, '--recovery', recovery]);
      return { reconciled: true, path: item.path, mutationReplayed: false };
    }
    if (fs.existsSync(journal)) throw new Error('prior operation exists; reconcile only, never replay automatically');
    const verified = await main(['verify-plan', '--state', file, '--plan', planFile, '--fingerprint', fingerprint, '--path', item.path]);
    if (!verified.verified) throw new Error('fresh verification failed');
    const prune = spawnSync('git', ['-C', item.root, 'worktree', 'prune', '--dry-run', '--verbose'], { encoding: 'utf8', timeout: 60000 });
    if (prune.status !== 0 || prune.stdout || prune.stderr) throw new Error('collateral prune preview not empty');
    const status = run('git', ['-C', item.path, 'status', '--porcelain', '--untracked-files=all']).trim();
    if (status && status !== '?? .sge-wt-claim') throw new Error('files or claim changed');
    if (status || fs.lstatSync(path.join(item.path, '.sge-wt-claim'), { throwIfNoEntry: false })) {
      const bash = process.env.SGE_BASH || (process.platform === 'win32'
        ? path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe') : 'bash');
      const lease = run(bash, [path.join(here, '../worktrees/resume-or-create.sh'), 'claim-state', item.path],
        { timeout: 10000, windowsHide: true });
      if (lease.trim() !== 'free') throw new Error('files or claim changed');
    }
    const before = snapshot(item.root, run);
    fs.writeFileSync(journal, JSON.stringify({ fingerprint, path: item.path, head: item.head,
      asOf: new Date().toISOString(), before, execution, recovery }), { flag: 'wx', mode: 0o600 });
    const log = fs.openSync(execution, 'wx', 0o600);
    let result;
    try {
      result = spawnSync(process.env.SGE_BASH || (process.platform === 'win32'
        ? path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe') : 'bash'),
      [path.join(here, 'execute.sh'), '--audit', verified.auditFile, '--select', entry.selector, '--recovery', recovery],
      { stdio: ['ignore', log, log], timeout: 600000, windowsHide: true });
    } finally { fs.closeSync(log); }
    if (result.error || result.status !== 0) throw new Error('executor incomplete; reconcile receipts, do not replay');
    verifyRemoval(item, execution, recovery);
    compareRemoval(before, snapshot(item.root, run), item);
    await main(['record', '--state', file, '--path', item.path, '--status', 'removed',
      '--reason', 'Approved serial executor DONE and full recovery verified; native collateral comparison passed.',
      '--evidence', execution, '--recovery', recovery]);
    return { removed: true, path: item.path, recovery };
  } finally { if (locked) lock.exec('ROLLBACK'); lock.close(); }
}
