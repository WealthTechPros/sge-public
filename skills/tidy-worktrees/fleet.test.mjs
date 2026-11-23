import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { pathKey } from '../lib/local-state.mjs';
import { importQueue, packet, applyAudit, counts, planItem, verifyIgnored, verifyRemoval, verifyApprovedIdentity, main } from './fleet.mjs';
import { checkConsent, compareRemoval } from './fleet-execution.mjs';

const head = 'a'.repeat(40);
const base = 'b'.repeat(40);
const root = path.resolve(os.tmpdir(), 'fleet fixture repo');
const row = (name, state = 'PENDING_REVIEW') => ({
  root, path: path.join(root, name), state, recoverySha: head,
  branch: `refs/heads/feat/${name}`, evidence: ['prior metadata'],
  creationTimeSnapshot: '2026-11-20T00:00:00Z',
});
const queue = rows => ({ rows, cutoff: '2026-11-22T00:00:00Z', scope: 'explicit known roots' });
const audit = (item, bucket = 'A') => ({
  repo: root, base_tip: base, refused: false, open_pr_set_known: true,
  items: [{ kind: 'worktree', path: item.path, name: 'feat/done', tip: head,
    bucket, reason: 'fixture', pr_state: 'merged', commands: ['not executed'] }],
});

test('imports existing reviews and removals without restarting them; unknown age remains reviewable', () => {
  const unknown = row('unknown');
  delete unknown.creationTimeSnapshot;
  const state = importQueue(queue([row('pending'), row('done', 'REMOVED_PREVIOUSLY_VERIFIED'),
    row('reviewed', 'EXISTING_REVIEW_REUSE_REVALIDATE_BEFORE_ACTION'),
    row('valuable', 'KEEP_USEFUL_DIRTY_RECONCILE'), unknown]));
  assert.deepEqual(packet(state).map(item => path.basename(item.path)), ['pending', 'unknown']);
  assert.equal(counts(state).lanes.recovery, 1);
  assert.equal(counts(state).lanes.removed, 1);
  assert.equal(packet(state, 'retained')[0].reviewed, true);
  state.items.find(item => path.basename(item.path) === 'unknown').priority = 0;
  assert.equal(path.basename(packet(state)[0].path), 'unknown');
  assert.throws(() => importQueue(queue([row('duplicate'), row('duplicate')])), /duplicate/);
  assert.throws(() => packet(state, 'review', 6), /1..5/);
});

test('failed or missing evidence retains originals; dirty and open-PR work never becomes cleanup', () => {
  for (const variation of ['refused', 'missing', 'dirty', 'open']) {
    const state = importQueue(queue([row('work')]));
    const item = state.items[0];
    const report = audit(item);
    if (variation === 'refused') report.refused = true;
    if (variation === 'missing') report.items = [];
    if (variation === 'dirty') Object.assign(report.items[0], { bucket: 'C', sub_verdict: 'NEEDS-DECISION:UNCOMMITTED' });
    if (variation === 'open') Object.assign(report.items[0], { bucket: 'C', pr_state: 'open' });
    applyAudit(state, [item], report, 'artifact.json', 'now');
    assert.notEqual(item.lane, 'cleanup', variation);
    assert.throws(() => planItem(item, report, []), /eligible/, variation);
  }
});

test('target changes invalidate only that assessment; an unchanged reviewed target stays reviewed', () => {
  const state = importQueue(queue([row('one', 'EXISTING_REVIEW_REUSE_REVALIDATE_BEFORE_ACTION'), row('two')]));
  const report = audit(state.items[0]);
  applyAudit(state, [state.items[0]], report, 'audit.json', 'now');
  assert.equal(state.items[0].reviewed, true);
  report.items[0].tip = 'c'.repeat(40);
  applyAudit(state, [state.items[0]], report, 'new.json', 'later');
  assert.equal(state.items[0].reviewed, false);
  assert.match(state.items[0].invalidation, /HEAD changed/);
  assert.equal(state.items[1].lane, 'review');
});

test('plan binds full source SHA and every ignored filename, not ignored contents or approval', () => {
  const item = importQueue(queue([row('done')])).items[0];
  const plan = planItem(item, audit(item), ['node_modules/a', 'node_modules/b\nname']);
  assert.equal(plan.recoverySha, head);
  assert.equal(plan.ignoredFileCount, 2);
  assert.equal(plan.approved, false);
  assert.notEqual(plan.ignoredFilenameSha256, planItem(item, audit(item), ['node_modules/a']).ignoredFilenameSha256);
  verifyIgnored(plan, ['node_modules/b\nname', 'node_modules/a']);
  assert.throws(() => verifyIgnored(plan, ['node_modules/a', 'new-precious-file']), /fresh plan/);
  const changed = audit(item); changed.items[0].tip = 'f'.repeat(40);
  assert.throws(() => planItem(item, changed, []), /eligible/);
});

test('verify-plan rejects a reviewed plan once the base has advanced; an unchanged base stays valid', () => {
  const state = importQueue(queue([row('done')]));
  const item = state.items[0];
  const report = audit(item);
  applyAudit(state, [item], report, 'audit.json', 'now');
  const entry = planItem(item, report, []);
  verifyApprovedIdentity(item, entry, report);
  const refused = { ...audit(item), refused: true };
  applyAudit(state, [item], refused, 'refused.json', 'refused');
  assert.throws(() => verifyApprovedIdentity(item, entry, refused), /fresh plan/);
  assert.throws(() => verifyApprovedIdentity(item, entry, undefined), /fresh plan/);
  const advanced = audit(item); advanced.base_tip = 'e'.repeat(40);
  applyAudit(state, [item], advanced, 'fresh.json', 'later');
  assert.equal(item.head, entry.recoverySha);
  assert.throws(() => verifyApprovedIdentity(item, entry, advanced), /fresh plan/);
  assert.throws(() => verifyApprovedIdentity(item, { ...entry, baseHead: undefined }, advanced), /fresh plan/);
  assert.throws(() => verifyApprovedIdentity({ ...item, head: undefined, baseHead: base },
    { ...entry, recoverySha: undefined }, report), /fresh plan/);
});

test('recording removal requires full recovery/actual DONE evidence and absent local copies', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fleet-removal-'));
  try {
    const repo = path.join(dir, 'repo');
    const git = args => {
      const result = spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8' });
      assert.equal(result.status, 0, result.stderr);
      return result.stdout.trim();
    };
    fs.mkdirSync(repo);
    git(['init', '-q']);
    git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
      'commit', '-q', '--allow-empty', '-m', 'fixture']);
    const current = git(['rev-parse', 'HEAD']);
    const target = path.join(dir, 'removed');
    const item = importQueue(queue([{ ...row('gone'), root: repo, path: target, recoverySha: current }])).items[0];
    item.branch = 'feat/gone';
    const csv = path.join(dir, 'recovery.csv');
    const log = path.join(dir, 'execution.txt');
    fs.writeFileSync(csv, `repo,kind,name,path,tip,bucket,reason,restore\n"${repo}",worktree,"feat/gone","${target}","${current}",A,"merged","restore"\n`);
    fs.writeFileSync(log, `WOULD\trepo\tworktree\tfeat/gone\t${current.slice(0, 12)}\tpreview\n`);
    assert.throws(() => verifyRemoval(item, log, csv), /DONE/);
    fs.writeFileSync(log, `DONE\trepo\tworktree\tfeat/gone\t${current.slice(0, 12)}\tremoved\n`);
    fs.mkdirSync(target);
    assert.throws(() => verifyRemoval(item, log, csv), /still exists/);
    fs.rmdirSync(target);
    git(['branch', 'feat/gone']);
    assert.throws(() => verifyRemoval(item, log, csv), /still present/);
    git(['branch', '-d', 'feat/gone']);
    verifyRemoval(item, log, csv);
    fs.writeFileSync(csv, fs.readFileSync(csv, 'utf8').replace(current, '0'.repeat(40)));
    assert.throws(() => verifyRemoval(item, log, csv), /full-SHA/);
  } finally { fs.rmSync(dir, { recursive: true }); }
});

test('a fresh invocation resumes the same ledger, refuses re-import/concurrent writer, and records exact invalidation', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fleet-state-'));
  try {
    const file = path.join(dir, 'state.json');
    const input = path.join(dir, 'queue.json');
    fs.writeFileSync(input, JSON.stringify(queue([row('one'), row('reviewed', 'KEEP_UNCOMMITTED_OR_UNBORN_NO_COMPLETE_RECOVERY')])));
    await main(['init', '--state', file, '--queue', input]);
    const before = fs.readFileSync(file, 'utf8');
    await assert.rejects(main(['init', '--state', file, '--queue', input]), /resume/);
    assert.equal(fs.readFileSync(file, 'utf8'), before);
    const entry = path.resolve(import.meta.dirname, 'fleet.mjs');
    const result = spawnSync(process.execPath, [entry, 'next', '--state', file], { encoding: 'utf8' });
    assert.equal(result.status, 0);
    assert.equal(JSON.parse(result.stdout).length, 1);
    fs.writeFileSync(`${file}.lock`, 'another writer');
    await assert.rejects(main(['invalidate', '--state', file, '--path', row('reviewed').path, '--reason', 'PR changed']), /EEXIST/);
    assert.equal(fs.readFileSync(file, 'utf8'), before);
    fs.unlinkSync(`${file}.lock`);
    await main(['invalidate', '--state', file, '--path', row('reviewed').path, '--reason', 'PR changed']);
    assert.equal((await main(['next', '--state', file])).length, 2);
    assert.equal((await main(['status', '--state', file])).snapshot, true);
    assert.equal(fs.existsSync(`${file}.lock`), false);
  } finally { fs.rmSync(dir, { recursive: true }); }
});

test('no output intermediates in a synchronised folder, including a symlink to it', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fleet-location-'));
  try {
    const target = path.join(dir, 'OneDrive');
    fs.mkdirSync(target);
    fs.symlinkSync(target, path.join(dir, 'innocent'), process.platform === 'win32' ? 'junction' : 'dir');
    await assert.rejects(main(['status', '--state', path.join(dir, 'innocent', 'state.json')]), /synchronised/);
    assert.deepEqual(fs.readdirSync(target), []);
    const state = path.join(dir, 'state.json');
    const input = path.join(dir, 'queue.json');
    fs.writeFileSync(input, JSON.stringify(queue([row('pending')])));
    await main(['init', '--state', state, '--queue', input]);
    fs.symlinkSync(target, `${state}.audits`, process.platform === 'win32' ? 'junction' : 'dir');
    await assert.rejects(main(['audit', '--state', state]), /synchronised/);
    assert.deepEqual(fs.readdirSync(target), []);
  } finally { fs.rmSync(dir, { recursive: true }); }
});

test('typed blockers leave the runnable queue until an explicit evidence invalidation', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fleet-blocker-'));
  try {
    const file = path.join(dir, 'state.json'), input = path.join(dir, 'queue.json');
    const evidence = path.join(dir, 'evidence.txt'), blocker = path.join(dir, 'blocker.json');
    fs.writeFileSync(input, JSON.stringify(queue([row('blocked'), row('ready')])));
    fs.writeFileSync(evidence, 'fixture source observation');
    fs.writeFileSync(blocker, JSON.stringify({ kind: 'owner', owner: 'operator',
      nextAction: 'reconcile writer', unblockEvidence: 'exact handoff and unchanged native binding' }));
    await main(['init', '--state', file, '--queue', input]);
    await main(['record', '--state', file, '--path', row('blocked').path, '--status', 'recovery',
      '--reason', 'writer unresolved', '--evidence', evidence, '--blocker', blocker]);
    assert.equal((await main(['next', '--state', file, '--lane', 'recovery'])).length, 0);
    assert.equal((await main(['blocked', '--state', file])).length, 1);
    await assert.rejects(main(['blocked', '--state', file, '--limit', '6']), /1..5/);
    assert.equal((await main(['status', '--state', file])).removed, 0);
    await main(['invalidate', '--state', file, '--path', row('blocked').path, '--reason', 'dated owner handoff received']);
    assert.equal((await main(['blocked', '--state', file])).length, 0);
    assert.equal((await main(['next', '--state', file])).length, 2);
  } finally { fs.rmSync(dir, { recursive: true }); }
});

test('approval binds a human-confirmed exact subset and separately named ignored files', () => {
  const item = importQueue(queue([row('approved')])).items[0];
  const plan = { items: [planItem(item, audit(item), ['cache/output'])] };
  const fingerprint = 'f'.repeat(64);
  const consent = { fingerprint, paths: [item.path], confirmedBy: 'fixture operator',
    confirmedAt: '2026-11-23T00:00:00Z', noWritersToolsOrUnsavedWork: true,
    ignoredFiles: [{ path: item.path, name: 'cache/output' }] };
  assert.equal(checkConsent(plan, fingerprint, consent).length, 1);
  assert.throws(() => checkConsent(plan, fingerprint, { ...consent, ignoredFiles: [] }), /ignored/);
  assert.throws(() => checkConsent(plan, '0'.repeat(64), consent), /fingerprint/);
  assert.throws(() => checkConsent(plan, fingerprint, { ...consent, noWritersToolsOrUnsavedWork: false }), /confirmation/);
  const before = { registry: `worktree ${root}\nHEAD ${base}\n\nworktree ${item.path}\nHEAD ${head}\n\n`,
    refs: `refs/heads/${item.branch.replace(/^refs\/heads\//, '')} ${head}\nrefs/heads/main ${base}\n`, stashes: '' };
  const after = { registry: `worktree ${root}\nHEAD ${base}\n\n`, refs: `refs/heads/main ${base}\n`, stashes: '' };
  compareRemoval(before, after, item);
  assert.throws(() => compareRemoval(before, { ...after, stashes: 'new stash' }, item), /collateral/);
});

test('reviewed repository identity must match both ledger and fresh audit', () => {
  const item = importQueue(queue([row('approved')])).items[0];
  const report = audit(item);
  applyAudit({ items: [item] }, [item], report, 'fixture', 'now');
  const entry = planItem(item, report, []);
  verifyApprovedIdentity(item, entry, report);
  assert.throws(() => verifyApprovedIdentity({ ...item, root: path.join(root, 'other') }, entry, report), /fresh plan/);
  assert.throws(() => verifyApprovedIdentity(item, entry, { ...report, repo: path.join(root, 'other') }), /fresh plan/);
});

test('fresh process reconciles an interrupted removal without invoking the executor again', async () => {
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'fleet-interruption-')));
  try {
    const repo = path.join(dir, 'repo'), target = path.join(dir, 'target');
    fs.mkdirSync(repo);
    const git = args => {
      const r = spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8' });
      assert.equal(r.status, 0, r.stderr); return r.stdout;
    };
    git(['init', '-q']);
    git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'fixture']);
    const current = git(['rev-parse', 'HEAD']).trim();
    git(['worktree', 'add', '-q', '-b', 'feat/done', target]);
    const state = path.join(dir, 'state.json'), input = path.join(dir, 'queue.json');
    fs.writeFileSync(input, JSON.stringify(queue([{ ...row('target'), root: repo, path: target,
      branch: 'feat/done', recoverySha: current }])));
    await main(['init', '--state', state, '--queue', input]);
    const item = (await main(['next', '--state', state]))[0];
    const report = { ...audit(item), repo, base_tip: current };
    report.items[0].tip = current;
    const planFile = path.join(dir, 'plan.json');
    fs.writeFileSync(planFile, JSON.stringify({ items: [planItem(item, report, [])] }));
    const hash = value => createHash('sha256').update(value).digest('hex');
    const fingerprint = hash(fs.readFileSync(planFile));
    const approval = path.join(dir, 'approved.json'), consent = path.join(dir, 'human.json');
    fs.writeFileSync(consent, JSON.stringify({ fingerprint, paths: [target], ignoredFiles: [],
      noWritersToolsOrUnsavedWork: true, confirmedBy: 'fixture operator', confirmedAt: '2026-11-23T00:00:00Z' }));
    await main(['approve', '--state', state, '--plan', planFile, '--fingerprint', fingerprint, '--approval', approval, '--evidence', consent]);
    const prefix = `${approval}.${hash(pathKey(target)).slice(0, 20)}`;
    const original = fs.readFileSync(state, 'utf8');
    const blockedState = JSON.parse(original);
    blockedState.items[0].blocker = { kind: 'permission', owner: 'operator', nextAction: 'human-mediated repair', unblockEvidence: 'matched supported approval' };
    fs.writeFileSync(state, JSON.stringify(blockedState));
    await assert.rejects(main(['execute', '--state', state, '--plan', planFile, '--fingerprint', fingerprint,
      '--approval', approval, '--path', target]), /unresolved target blocker/);
    await assert.rejects(main(['verify-plan', '--state', state, '--plan', planFile, '--fingerprint', fingerprint,
      '--path', target]), /unresolved target blocker/);
    assert.equal(fs.existsSync(`${prefix}.operation.json`), false);
    fs.writeFileSync(state, original);
    const before = { registry: git(['worktree', 'list', '--porcelain']),
      refs: git(['for-each-ref', '--format=%(refname) %(objectname)']), stashes: git(['stash', 'list', '--format=%H']) };
    fs.writeFileSync(`${prefix}.operation.json`, JSON.stringify({ fingerprint, path: target, head: current, before }));
    await assert.rejects(main(['execute', '--state', state, '--plan', planFile, '--fingerprint', fingerprint,
      '--approval', approval, '--path', target]), /reconcile only/);
    fs.writeFileSync(`${prefix}.recovery.csv`, `repo,kind,name,path,tip,bucket,reason,restore\n"${repo}",worktree,"feat/done","${target}","${current}",A,"merged","restore"\n`);
    fs.writeFileSync(`${prefix}.execution.txt`, `DONE\trepo\tworktree\tfeat/done\t${current.slice(0, 12)}\tremoved\n`);
    git(['worktree', 'remove', target]); git(['branch', '-D', 'feat/done']);
    const result = spawnSync(process.execPath, [path.join(import.meta.dirname, 'fleet.mjs'), 'reconcile', '--state', state,
      '--plan', planFile, '--fingerprint', fingerprint, '--approval', approval, '--path', target], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout).mutationReplayed, false);
    assert.equal((await main(['status', '--state', state])).lanes.removed, 1);
    const again = await main(['reconcile', '--state', state, '--plan', planFile, '--fingerprint', fingerprint, '--approval', approval, '--path', target]);
    assert.equal(again.reconciled, true);
  } finally { fs.rmSync(dir, { recursive: true }); }
});

test('remote preservation requires the exact source SHA and does not claim dirty-file backup or acceptance', async () => {
  const dir = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'fleet-publication-')));
  try {
    const repo = path.join(dir, 'repo');
    fs.mkdirSync(repo);
    const git = args => {
      const r = spawnSync('git', ['-C', repo, ...args], { encoding: 'utf8' });
      assert.equal(r.status, 0, r.stderr); return r.stdout.trim();
    };
    git(['init', '-q']);
    git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'fixture']);
    git(['branch', 'feat/preserved']);
    git(['remote', 'add', 'origin', repo]);
    const state = path.join(dir, 'state.json'), input = path.join(dir, 'queue.json'), evidence = path.join(dir, 'receipt.txt');
    fs.writeFileSync(input, JSON.stringify(queue([{ ...row('source'), root: repo, branch: 'feat/preserved', recoverySha: git(['rev-parse', 'HEAD']) }])));
    fs.writeFileSync(evidence, 'fixture source publication receipt');
    await main(['init', '--state', state, '--queue', input]);
    const item = (await main(['next', '--state', state]))[0];
    const args = ['preserved', '--state', state, '--path', item.path, '--evidence', evidence];
    assert.match((await main(args)).boundary, /committed source only/);
    assert.equal((await main(['status', '--state', state])).remotelyPreserved, 1);
    assert.equal((await main(['status', '--state', state])).remaining, 1);
    git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'newer']);
    git(['branch', '-f', 'feat/preserved', 'HEAD']);
    await assert.rejects(main(['preserved', '--state', state, '--path', item.path, '--evidence', evidence]), /differs/);
  } finally { fs.rmSync(dir, { recursive: true }); }
});
