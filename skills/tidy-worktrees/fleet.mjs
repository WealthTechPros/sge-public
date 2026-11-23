#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { pathKey as key, stateLocation as outputLocation } from '../lib/local-state.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const sha = /^[0-9a-f]{40}$/;
const digest = value => createHash('sha256').update(value).digest('hex');
const read = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const bash = () => process.env.SGE_BASH || (process.platform === 'win32'
  ? path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe') : 'bash');

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8', timeout: 60000, maxBuffer: 32 * 1024 * 1024, ...options, shell: false,
  });
  if (result.error || result.status !== 0) throw new Error('command failed or timed out; retain target');
  return result.stdout;
}

export function importQueue(queue) {
  if (!Array.isArray(queue.rows) || !Number.isFinite(Date.parse(queue.cutoff))) throw new Error('invalid queue/cutoff');
  const seen = new Set();
  const items = queue.rows.map(row => {
    if (!row.root || !row.path || !row.state || !Array.isArray(row.evidence)) throw new Error('incomplete queue row');
    const id = key(row.path);
    if (seen.has(id)) throw new Error('duplicate target path');
    seen.add(id);
    const age = Date.parse(row.creationTimeSnapshot);
    const removed = row.state.startsWith('REMOVED_');
    const reviewed = row.state !== 'PENDING_REVIEW';
    const lane = removed ? 'removed' : Number.isFinite(age) && age >= Date.parse(queue.cutoff)
      ? 'today' : !reviewed ? 'review' : row.state.includes('USEFUL') || row.state.includes('STASH')
        ? 'recovery' : row.state === 'RELEASED_VERIFIED_MERGED_AWAITING_REMOVAL_PLAN' ? 'cleanup' : 'retained';
    return {
      id, root: path.resolve(row.root), path: path.resolve(row.path), branch: row.branch,
      head: row.recoverySha, age: row.creationTimeSnapshot || null, lane,
      importedState: row.state, reviewed, evidence: row.evidence,
      next: lane === 'review' ? 'assess selected target' : lane === 'recovery'
        ? 'qualify original writer/task, preserve and finish valuable slice' : 'reuse existing assessment; revalidate before action',
    };
  });
  return { version: 1, revision: 0, cutoff: queue.cutoff, scope: queue.scope, items };
}

export function packet(state, lane = 'review', limit = 5) {
  if (!['review', 'cleanup', 'recovery', 'merge', 'retained'].includes(lane)) throw new Error('invalid lane');
  if (!Number.isInteger(limit) || limit < 1 || limit > 5) throw new Error('packet limit must be 1..5');
  return state.items.filter(item => item.lane === lane && !item.blocker)
    .sort((a, b) => (a.priority ?? 1000) - (b.priority ?? 1000)).slice(0, limit);
}

export function applyAudit(state, selected, report, auditFile, inspectedAt) {
  if (!report || !Array.isArray(report.items)) throw new Error('malformed audit');
  for (const item of selected) {
    const match = report.items.find(row => row.kind === 'worktree' && key(row.path || '.') === item.id);
    item.inspectedAt = inspectedAt;
    item.auditFile = auditFile;
    if (!match || report.refused || report.open_pr_set_known !== true || !sha.test(match.tip || '')) {
      item.lane = 'retained';
      item.next = 'missing or refused evidence; retain original';
      continue;
    }
    item.audit = match;
    if (item.head !== match.tip || item.baseHead && item.baseHead !== report.base_tip) {
      item.invalidation = 'target/base HEAD changed; previous assessment/approval not reusable';
      item.reviewed = false;
    }
    item.head = match.tip;
    item.baseHead = report.base_tip;
    item.branch = match.name;
    // A mechanical bucket cannot establish the value of dirty or unfinished work.
    item.lane = ['A', 'D'].includes(match.bucket) ? 'cleanup'
      : match.pr_state === 'open' ? 'merge'
        : match.bucket === 'B' || match.sub_verdict?.startsWith('NEEDS-DECISION') ? 'recovery' : 'retained';
    item.next = item.lane === 'cleanup' ? 'fresh exact cleanup plan and separate consent'
      : item.lane === 'merge' ? 'finish acceptance; await authorised merge, then invalidate/re-audit'
        : item.lane === 'recovery' ? 'review value, qualify writer/task, preserve, complete owning checks and draft PR'
          : match.reason || 'unknown - retain';
  }
}

function save(file, state, previous) {
  outputLocation(file);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const lock = `${file}.lock`;
  const fd = fs.openSync(lock, 'wx', 0o600);
  const temp = `${file}.${randomUUID()}.tmp`;
  try {
    if ((fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null) !== previous) {
      throw new Error('ledger changed concurrently; do not overwrite');
    }
    state.revision++;
    fs.writeFileSync(temp, `${JSON.stringify(state, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    fs.renameSync(temp, file);
  } finally {
    fs.closeSync(fd);
    if (fs.existsSync(temp)) fs.unlinkSync(temp);
    fs.unlinkSync(lock);
  }
}

export function counts(state) {
  const result = {};
  for (const item of state.items) result[item.lane] = (result[item.lane] || 0) + 1;
  const preserved = item => item.publication?.verified === true && item.publication.sourceSha === item.head;
  return { snapshot: true, total: state.items.length, lanes: result,
    blocked: state.items.filter(item => item.blocker).length,
    removed: result.removed || 0,
    remotelyPreserved: state.items.filter(item => item.lane !== 'removed' && preserved(item)).length,
    remaining: state.items.length - (result.removed || 0),
    classificationOnly: state.items.filter(item => item.reviewed && item.lane !== 'removed' && !preserved(item)).length };
}

export function planItem(item, report, names) {
  const match = report.items.find(row => row.kind === 'worktree' && key(row.path || '.') === item.id);
  if (report.refused || report.open_pr_set_known !== true || !sha.test(report.base_tip || '') || !match || !['A', 'D'].includes(match.bucket)
    || !sha.test(match.tip || '') || match.tip !== item.head || !match.commands?.length) {
    throw new Error('target not freshly cleanup-eligible; retain');
  }
  const ignored = [...names].sort();
  return {
    path: item.path, branch: match.name, recoverySha: match.tip, baseHead: report.base_tip, bucket: match.bucket,
    reason: match.reason, auditRepo: report.repo,
    selector: `${report.repo}::worktree:${match.name}@${match.tip}`,
    ignoredFileCount: ignored.length, ignoredFilenameSha256: digest(ignored.join('\0')),
    ignoredFiles: ignored, approved: false,
  };
}

// A reviewed plan is bound to the source tip, branch AND the base it was judged
// against; a base that has moved since review needs a fresh plan and consent.
// The fresh report is checked directly so a refused audit (which leaves the
// ledger's previous head/base untouched) can never pass on stale values.
export function verifyApprovedIdentity(item, entry, report) {
  if (!item || !report || report.refused || !sha.test(entry.recoverySha || '') || !sha.test(entry.baseHead || '')
    || item.head !== entry.recoverySha || item.branch !== entry.branch
    || item.baseHead !== entry.baseHead || report.base_tip !== entry.baseHead
    || key(item.root) !== key(entry.auditRepo) || key(report.repo) !== key(entry.auditRepo)) {
    throw new Error('approved target identity or base changed; fresh plan required; retain');
  }
}

export function verifyIgnored(entry, names) {
  const current = [...names].sort();
  if (current.length !== entry.ignoredFileCount || digest(current.join('\0')) !== entry.ignoredFilenameSha256) {
    throw new Error('ignored filenames changed; fresh plan and separate consent required');
  }
}

function csvRows(text) {
  const rows = [];
  let row = [], value = '', quoted = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (char === '"') {
      if (quoted && text[i + 1] === '"') { value += '"'; i++; }
      else quoted = !quoted;
    } else if (!quoted && (char === ',' || char === '\n')) {
      row.push(value);
      value = '';
      if (char === '\n') { rows.push(row); row = []; }
    } else if (quoted || char !== '\r') value += char;
  }
  if (quoted) throw new Error('malformed recovery CSV');
  if (value || row.length) rows.push([...row, value]);
  return rows;
}

export function verifyRemoval(item, execution, recovery) {
  if (!recovery || !sha.test(item.head || '')) throw new Error('full recovery handle required');
  const branch = item.branch.replace(/^refs\/heads\//, '');
  const rows = csvRows(fs.readFileSync(recovery, 'utf8'));
  if (rows[0]?.join(',') !== 'repo,kind,name,path,tip,bucket,reason,restore'
    || !rows.slice(1).some(row => row.length === 8 && key(row[0]) === key(item.root)
      && row[1] === 'worktree' && row[2] === branch && key(row[3]) === item.id && row[4] === item.head)) {
    throw new Error('exact full-SHA recovery row missing');
  }
  const done = fs.readFileSync(execution, 'utf8').split(/\r?\n/).some(line => {
    const fields = line.split('\t');
    return fields[0] === 'DONE' && fields[1] === path.basename(item.root)
      && fields[2] === 'worktree' && fields[3] === branch && fields[4] === item.head.slice(0, 12);
  });
  if (!done) throw new Error('exact executor DONE receipt missing');
  try { fs.lstatSync(item.path); throw new Error('worktree still exists'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (run('git', ['-C', item.root, 'for-each-ref', '--format=%(refname)', `refs/heads/${branch}`]).trim()
    || run('git', ['-C', item.root, 'worktree', 'list', '--porcelain']).split('\n')
      .some(line => line.startsWith('worktree ') && key(line.slice(9)) === item.id)) {
    throw new Error('branch or native worktree entry still present');
  }
  run('git', ['-C', item.root, 'cat-file', '-e', `${item.head}^{commit}`]);
}

export async function main(args) {
  const command = args.shift();
  const options = {};
  while (args.length) {
    const name = args.shift();
    if (!['--state', '--queue', '--lane', '--limit', '--out', '--path', '--reason', '--status', '--evidence', '--recovery', '--plan', '--fingerprint', '--priority', '--blocker', '--approval'].includes(name)
      || !args.length || options[name] !== undefined) throw new Error('invalid arguments');
    options[name] = args.shift();
  }
  if (!options['--state']) throw new Error('--state required');
  const file = outputLocation(options['--state']);
  if (command === 'init') {
    if (fs.existsSync(file)) throw new Error('existing ledger: resume, do not overwrite or re-import');
    const state = importQueue(read(options['--queue']));
    state.importSource = path.resolve(options['--queue']);
    save(file, state, null);
    return counts(state);
  }
  const previous = fs.readFileSync(file, 'utf8');
  const state = JSON.parse(previous);
  if (state.version !== 1 || !Array.isArray(state.items)) throw new Error('unknown ledger version');
  const limit = Number(options['--limit'] || 5);
  if (!Number.isInteger(limit) || limit < 1 || limit > 5) throw new Error('packet limit must be 1..5');
  const lane = options['--lane'] || 'review';
  if (command === 'status') return counts(state);
  if (command === 'blocked') return state.items.filter(item => item.blocker).slice(0, limit);
  if (command === 'next') return packet(state, lane, limit);
  if (command === 'preserved') {
    const item = state.items.find(row => row.id === key(options['--path'] || '.'));
    if (!item || !options['--evidence']) throw new Error('exact target and publication evidence required');
    const branch = item.branch.replace(/^refs\/heads\//, '');
    const remote = run('git', ['-C', item.root, 'ls-remote', '--exit-code', 'origin', `refs/heads/${branch}`]).trim();
    if (remote !== `${item.head}\trefs/heads/${branch}`) throw new Error('remote source head differs; not preserved');
    const evidence = path.resolve(options['--evidence']);
    const content = fs.readFileSync(evidence);
    item.publication = { verified: true, sourceSha: item.head, branch, asOf: new Date().toISOString(),
      boundary: 'committed source only; dirty, ignored, stashes, buffers and acceptance remain separate' };
    item.evidence.push({ file: evidence, sha256: digest(content), asOf: item.publication.asOf });
    save(file, state, previous);
    return item.publication;
  }
  if (command === 'invalidate') {
    const item = state.items.find(row => row.id === key(options['--path'] || ''));
    if (!item || !options['--reason'] || item.lane === 'removed') throw new Error('exact target and invalidation reason required');
    item.lane = 'review';
    delete item.blocker;
    item.invalidation = options['--reason'];
    save(file, state, previous);
    return item;
  }
  if (command === 'record') {
    const item = state.items.find(row => row.id === key(options['--path'] || ''));
    if (!item || !['retained', 'recovery', 'merge', 'removed'].includes(options['--status']) || !options['--reason']
      || !options['--evidence']) throw new Error('record requires target, disposition, reason and evidence file');
    const evidence = path.resolve(options['--evidence']);
    if (!fs.statSync(evidence).isFile()) throw new Error('evidence missing');
    if (options['--priority'] !== undefined) {
      const priority = Number(options['--priority']);
      if (!Number.isInteger(priority) || priority < 0 || priority > 100) throw new Error('priority must be 0..100');
      item.priority = priority;
    }
    if (options['--status'] === 'removed') {
      verifyRemoval(item, evidence, options['--recovery']);
      item.recoveryFile = path.resolve(options['--recovery']);
      delete item.blocker;
    }
    item.lane = options['--status'];
    item.reviewed = true;
    item.next = options['--reason'];
    if (options['--blocker']) {
      const blocker = read(options['--blocker']);
      if (!['owner', 'preservation', 'permission', 'host-evidence', 'acceptance', 'approval'].includes(blocker.kind)
        || !['owner', 'nextAction', 'unblockEvidence'].every(field => typeof blocker[field] === 'string' && blocker[field].trim())
        || options['--status'] === 'removed') throw new Error('typed blocker needs owner, nextAction and unblockEvidence');
      item.blocker = { ...blocker, asOf: new Date().toISOString() };
    }
    item.evidence.push({ file: evidence, sha256: digest(fs.readFileSync(evidence)), asOf: new Date().toISOString() });
    save(file, state, previous);
    return item;
  }
  if (['approve', 'execute', 'reconcile'].includes(command)) {
    const { manageExecution } = await import('./fleet-execution.mjs');
    return manageExecution({ command, options, state, file, previous, save, run, verifyRemoval, main });
  }
  if (!['audit', 'plan', 'verify-plan'].includes(command)) throw new Error('usage: init|status|next|blocked|audit|record|invalidate|plan|verify-plan|approve|execute|reconcile --state <file>');
  if (command === 'plan' && (!options['--out'] || fs.existsSync(outputLocation(options['--out'])))) {
    throw new Error('plan needs a new --out file; never overwrite prior approval');
  }
  let reviewedPlan, approvedEntry;
  if (command === 'verify-plan') {
    if (!options['--plan'] || !options['--path'] || !/^[0-9a-f]{64}$/.test(options['--fingerprint'] || '')) {
      throw new Error('verification needs exact plan, target and reviewed plan fingerprint');
    }
    const raw = fs.readFileSync(options['--plan']);
    if (digest(raw) !== options['--fingerprint']) throw new Error('reviewed plan changed');
    reviewedPlan = JSON.parse(raw);
    approvedEntry = reviewedPlan.items?.find(item => key(item.path) === key(options['--path']));
    if (!approvedEntry) throw new Error('target missing from reviewed plan');
  }
  const selected = command === 'verify-plan'
    ? state.items.filter(item => item.id === key(options['--path']))
    : packet(state, command === 'plan' ? 'cleanup' : lane, limit);
  if (command === 'verify-plan' && selected.length !== 1) throw new Error('exact ledger target required');
  if (command === 'verify-plan' && selected[0].blocker) throw new Error('unresolved target blocker; explicit evidence invalidation required');
  const deadline = Date.now() + 600000;
  const reports = new Map();
  const store = path.dirname(outputLocation(path.join(`${file}.audits`, 'probe.json')));
  fs.mkdirSync(store, { recursive: true });
  for (const item of selected) {
    if (reports.has(key(item.root))) continue;
    if (Date.now() >= deadline) break;
    try {
      const raw = run(bash(), [path.join(here, 'audit.sh'), '--fetch', item.root], {
        timeout: Math.max(1, deadline - Date.now()),
        env: { ...process.env, SGE_TIDY_BULK_COMPLETED: '1' },
      });
      const parsed = JSON.parse(raw);
      if (!Array.isArray(parsed) || parsed.length !== 1) throw new Error('expected one audit');
      const artifact = outputLocation(path.join(store, `${randomUUID()}.json`));
      fs.writeFileSync(artifact, raw, { flag: 'wx', mode: 0o600 });
      reports.set(key(item.root), { report: parsed[0], artifact });
    } catch {
      reports.set(key(item.root), { report: { items: [], refused: true }, artifact: null });
    }
  }
  const completed = [];
  for (const item of selected) {
    const result = reports.get(key(item.root));
    if (!result) continue;
    applyAudit(state, [item], result.report, result.artifact, new Date().toISOString());
    completed.push(item);
  }
  save(file, state, previous);
  if (command === 'audit') return { processed: completed, remaining: counts(state), mutations: 'remote-tracking fetch and local ledger only' };
  if (command === 'verify-plan') {
    const item = completed[0];
    verifyApprovedIdentity(item, approvedEntry, item && reports.get(key(item.root))?.report);
    const names = run('git', ['-C', item.path, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z'])
      .split('\0').filter(Boolean);
    planItem(item, reports.get(key(item.root)).report, names);
    verifyIgnored(approvedEntry, names);
    if (digest(fs.readFileSync(options['--plan'])) !== options['--fingerprint']) throw new Error('reviewed plan changed during verification');
    return {
      verified: true, path: item.path, recoverySha: item.head, ignoredFilenameSha256: approvedEntry.ignoredFilenameSha256,
      auditFile: item.auditFile,
      approval: 'still required; a matching fingerprint is not human consent',
      executorArguments: ['--audit', item.auditFile, '--select', `${reports.get(key(item.root)).report.repo}::worktree:${item.branch}@${item.head}`],
      execution: 'use the reviewed recovery-file path; coordinator executes this target immediately, serially',
    };
  }
  const planFile = outputLocation(options['--out']);
  const plan = {
    approved: false, asOf: new Date().toISOString(), items: [], retained: [],
    requiredConsent: ['exact paths/full tips', 'no writers or unsaved buffers', 'separately named ignored-file disposal'],
    execution: 'coordinator only: Phase2b for locks; existing executor serially, with junction and collateral-prune checks',
    automaticMerge: false, automaticDeletion: false,
  };
  for (const item of completed) {
    try {
      if (item.lane !== 'cleanup') throw new Error('ineligible');
      const ignored = run('git', ['-C', item.path, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z'])
        .split('\0').filter(Boolean);
      const entry = planItem(item, reports.get(key(item.root)).report, ignored);
      entry.auditFile = item.auditFile;
      entry.executorArguments = ['--audit', item.auditFile, '--select', entry.selector,
        '--recovery', `${planFile}.${plan.items.length + 1}.recovery.csv`];
      plan.items.push(entry);
    } catch { plan.retained.push({ path: item.path, reason: 'changed, unsafe or incomplete evidence - retain and revalidate' }); }
  }
  fs.mkdirSync(path.dirname(planFile), { recursive: true });
  fs.writeFileSync(planFile, `${JSON.stringify(plan, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
  return { plan: planFile, fingerprint: digest(fs.readFileSync(planFile)), candidates: plan.items.length, retained: plan.retained };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(result => console.log(JSON.stringify(result, null, 2)))
    .catch(error => { console.error(`fleet: ${error.code || error.message}; retain originals`); process.exitCode = 1; });
}
