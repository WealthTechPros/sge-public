import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { extractSpecRefs, classifyPR, buildTraceabilityData } from '../build-traceability.mjs';

// --- extractSpecRefs ---

describe('extractSpecRefs', () => {
  it('extracts a SPEC-NNN ref from a plain string', () => {
    const refs = extractSpecRefs('feat/spec-054-traceability');
    assert.deepEqual(refs, ['SPEC-054']);
  });

  it('extracts a CAP-NNN ref', () => {
    const refs = extractSpecRefs('Implements CAP-007');
    assert.deepEqual(refs, ['CAP-007']);
  });

  it('extracts a CAP-NNN-FNNN ref', () => {
    const refs = extractSpecRefs('feat/cap-012-f003-something');
    assert.deepEqual(refs, ['CAP-012-F003']);
  });

  it('extracts multiple refs from a PR body', () => {
    const body = 'This PR implements SPEC-001 and SPEC-002. See also CAP-005-F001.';
    const refs = extractSpecRefs(body);
    assert.deepEqual(refs.sort(), ['CAP-005-F001', 'SPEC-001', 'SPEC-002']);
  });

  it('deduplicates refs', () => {
    const refs = extractSpecRefs('SPEC-001 and SPEC-001 again');
    assert.deepEqual(refs, ['SPEC-001']);
  });

  it('returns [] for a string with no spec refs', () => {
    const refs = extractSpecRefs('chore: update readme');
    assert.deepEqual(refs, []);
  });

  it('is case-insensitive for the prefix but normalises to upper-case', () => {
    const refs = extractSpecRefs('feat/spec-054-s0 implements spec-054');
    assert.deepEqual(refs, ['SPEC-054']);
  });
});

// --- classifyPR ---

describe('classifyPR', () => {
  it('classifies a PR with a SPEC ref in branch name as traceable', () => {
    const pr = { title: 'something', headRefName: 'feat/spec-054-traceability', body: '' };
    assert.equal(classifyPR(pr), 'traceable');
  });

  it('classifies a PR with a SPEC ref in body as traceable', () => {
    const pr = { title: 'something', headRefName: 'feature/issue-42', body: 'Spec: SPEC-007' };
    assert.equal(classifyPR(pr), 'traceable');
  });

  it('classifies a PR with a SPEC ref in title as traceable', () => {
    const pr = { title: 'feat(thing): SPEC-007 implement foo', headRefName: 'main', body: '' };
    assert.equal(classifyPR(pr), 'traceable');
  });

  it('classifies a PR with no spec refs as untraceable', () => {
    const pr = { title: 'chore: update readme', headRefName: 'chore/docs', body: 'Minor update' };
    assert.equal(classifyPR(pr), 'untraceable');
  });

  it('handles null/undefined body gracefully', () => {
    const pr = { title: 'chore', headRefName: 'feat/spec-001', body: null };
    assert.equal(classifyPR(pr), 'traceable');
  });
});

// --- buildTraceabilityData ---

const SAMPLE_PRS = [
  { number: 1, title: 'feat: add SPEC-001 thing', state: 'closed', merged: true, headRefName: 'feat/spec-001-foo', body: 'Spec: SPEC-001', author: 'alice', createdAt: '2024-01-01T00:00:00Z', mergedAt: '2024-01-02T00:00:00Z', url: 'https://github.com/org/repo/pull/1' },
  { number: 2, title: 'feat: SPEC-002 other', state: 'closed', merged: true, headRefName: 'feat/spec-002-bar', body: '', author: 'bob', createdAt: '2024-01-03T00:00:00Z', mergedAt: '2024-01-04T00:00:00Z', url: 'https://github.com/org/repo/pull/2' },
  { number: 3, title: 'chore: update deps', state: 'closed', merged: true, headRefName: 'chore/deps', body: 'No spec', author: 'carol', createdAt: '2024-01-05T00:00:00Z', mergedAt: '2024-01-06T00:00:00Z', url: 'https://github.com/org/repo/pull/3' },
  { number: 4, title: 'feat: another SPEC-001 change', state: 'open', merged: false, headRefName: 'feat/spec-001-baz', body: 'SPEC-001', author: 'dave', createdAt: '2024-01-07T00:00:00Z', mergedAt: null, url: 'https://github.com/org/repo/pull/4' },
];

describe('buildTraceabilityData', () => {
  const data = buildTraceabilityData(SAMPLE_PRS);

  it('counts totals correctly', () => {
    assert.equal(data.stats.total, 4);
    assert.equal(data.stats.traceable, 3);
    assert.equal(data.stats.untraceable, 1);
    assert.ok(data.stats.tracePercent >= 74 && data.stats.tracePercent <= 76, `Expected ~75%, got ${data.stats.tracePercent}`);
  });

  it('groups PRs under their spec ref', () => {
    const spec001 = data.specs['SPEC-001'];
    assert.ok(spec001, 'SPEC-001 node should exist');
    assert.equal(spec001.prs.length, 2, 'SPEC-001 should have 2 PRs');
    const prNumbers = spec001.prs.map((p) => p.number).sort();
    assert.deepEqual(prNumbers, [1, 4]);
  });

  it('puts untracked PRs in governanceGaps', () => {
    assert.equal(data.governanceGaps.length, 1);
    assert.equal(data.governanceGaps[0]?.number, 3);
  });

  it('includes spec ref in each PR record', () => {
    const pr1 = data.specs['SPEC-001']?.prs.find((p) => p.number === 1);
    assert.ok(pr1?.specRefs.includes('SPEC-001'));
  });

  it('emits a schemaVersion field', () => {
    assert.equal(data.schemaVersion, '1');
  });

  it('includes generatedAt timestamp', () => {
    assert.ok(typeof data.generatedAt === 'string' && data.generatedAt.length > 0);
  });
});
