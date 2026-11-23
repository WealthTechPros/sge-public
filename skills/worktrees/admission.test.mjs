import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { admission } from './admission.mjs';

function fixture(t) {
  const directory = fs.realpathSync.native(fs.mkdtempSync(path.join(os.tmpdir(), 'sge-admission-')));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const repository = path.join(directory, 'repo'), worktree = path.join(directory, 'existing');
  fs.mkdirSync(repository);
  const git = args => {
    const r = spawnSync('git', ['-C', repository, ...args], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr); return r.stdout.trim();
  };
  git(['init', '-q']);
  git(['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'fixture']);
  git(['remote', 'add', 'origin', 'https://github.com/example/fixture.git']);
  git(['worktree', 'add', '-q', '-b', 'feat/existing', worktree]);
  const gh = path.join(directory, 'host.sh');
  fs.writeFileSync(gh, '#!/usr/bin/env bash\nprintf \'%s\\n\' \'{"headRefName":"feat/existing","isCrossRepository":false}\'\n');
  fs.chmodSync(gh, 0o700);
  const request = { schemaVersion: 1, requestId: 'request-one', operation: 'init', repository,
    store: path.join(directory, 'admission.sqlite'), task: 'github:pr/1', session: 'session-one' };
  const invoke = (value, extra = {}) => new Promise(resolve => {
    const child = spawn(process.execPath, [path.join(import.meta.dirname, 'admission.mjs'), '--request-stdin'],
      { env: { ...process.env, SGE_ROC_GH: gh, ...extra }, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', data => stdout += data);
    child.stderr.on('data', data => stderr += data);
    child.on('close', status => resolve({ status, stdout, stderr, result: stdout ? JSON.parse(stdout) : null }));
    child.stdin.end(JSON.stringify(value));
  });
  return { request, invoke, worktree, git };
}

test('two fresh processes bind only one owner; a new session cannot create a duplicate or take over expired claims', async t => {
  const f = fixture(t);
  assert.equal((await admission(f.request)).outcome, 'initialized');
  const [a, b] = await Promise.all([
    f.invoke({ ...f.request, operation: 'admit' }),
    f.invoke({ ...f.request, operation: 'admit', session: 'session-two', requestId: 'request-two' }),
  ]);
  assert.deepEqual([a.result.outcome, b.result.outcome].sort(), ['backoff', 'resume']);
  const owner = a.result.outcome === 'resume' ? f.request.session : 'session-two';
  const resumed = await f.invoke({ ...f.request, operation: 'admit', session: owner, requestId: 'fresh-request', generation: 1 });
  assert.equal(resumed.result.outcome, 'resume');
  assert.equal(resumed.result.worktree, fs.realpathSync.native(f.worktree));
  const badPause = await admission({ ...f.request, operation: 'pause', session: owner, generation: 99 });
  assert.equal(badPause.outcome, 'backoff');
  f.git(['-C', f.worktree, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
    'commit', '-q', '--allow-empty', '-m', 'useful work']);
  const paused = await admission({ ...f.request, operation: 'pause', session: owner, generation: 1 });
  assert.equal(paused.outcome, 'paused');
  assert.notEqual(paused.head, resumed.result.head);
  const handoff = await admission({ ...f.request, operation: 'handoff', session: owner, generation: 1,
    successorSession: 'successor', expectedHead: paused.head });
  assert.equal(handoff.outcome, 'handed-off');
  assert.equal(handoff.generation, 2);
  assert.equal((await f.invoke({ ...f.request, operation: 'admit', session: 'successor', requestId: 'next-session', generation: 2 })).result.outcome, 'resume');
  assert.equal((await admission({ ...f.request, operation: 'pause', session: owner, generation: 1 })).outcome, 'backoff');
  const registry = path.join(f.request.repository, '.git', 'sge-worktrees');
  fs.mkdirSync(registry);
  const entry = path.join(registry, 'legacy.entry');
  fs.writeFileSync(entry, `session=legacy-owner\npath=${f.worktree}\nbranch=feat/existing\n`);
  assert.equal((await f.invoke({ ...f.request, operation: 'admit', session: 'successor', generation: 2 })).result.reasonCode, 'foreign-legacy-registration');
  fs.unlinkSync(entry);
  fs.writeFileSync(path.join(f.worktree, '.sge-wt-claim'), 'foreign-owner 1\n');
  assert.equal((await f.invoke({ ...f.request, operation: 'admit', session: owner, generation: 1 })).result.outcome, 'needs-review');
  assert.equal(f.git(['worktree', 'list', '--porcelain']).split('\n').filter(line => line.startsWith('worktree ')).length, 2);
});

test('missing stores and unavailable host evidence fail closed, without creating or changing worktrees', async t => {
  const f = fixture(t);
  assert.equal((await admission({ ...f.request, operation: 'admit' })).outcome, 'blocked');
  assert.equal(fs.existsSync(f.request.store), false);
  await admission(f.request);
  const blocked = await f.invoke({ ...f.request, operation: 'admit' }, { SGE_ROC_GH: path.join(f.worktree, 'missing-tool') });
  assert.equal(blocked.result.outcome, 'needs-review');
  await assert.rejects(admission(f.request), /EEXIST/);
  await assert.rejects(admission({ ...f.request, operation: 'admit', task: 'azdo:wi/1' }), /host/);
});

test('a GitHub repository named dev.azure.com is still a GitHub host', async t => {
  const f = fixture(t);
  f.git(['remote', 'set-url', 'origin', 'https://github.com/example/dev.azure.com/']);
  await admission(f.request);
  await assert.rejects(admission({ ...f.request, operation: 'admit', task: 'azdo:wi/1' }), /host/);
});
