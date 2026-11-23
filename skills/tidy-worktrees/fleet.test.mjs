import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { importQueue, packet, applyAudit, counts, planItem, verifyIgnored, verifyApprovedIdentity, verifyRemoval, main } from './fleet.mjs';

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
