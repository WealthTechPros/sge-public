import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  extractValidationSection,
  extractFixtureHint,
  parseInvariantTable,
  evaluateAssert,
  runCli,
  extractReconciliationSection,
  countReconciliationAssertions,
} from '../assets/spec-validate.mjs';

const EXAMPLE_SPEC = path.join(import.meta.dirname, '..', 'assets', 'example-spec.md');
const EXAMPLE_FIXTURE = path.join(import.meta.dirname, '..', 'assets', 'example-fixture.json');

// --- extractValidationSection ---

describe('extractValidationSection', () => {
  it('extracts the body between ## Validation and the next ## heading', () => {
    const md = '# Title\n\n## Validation\n\nsome body\n\n## Out of scope\n\nmore text';
    const section = extractValidationSection(md);
    assert.match(section, /some body/);
    assert.doesNotMatch(section, /more text/);
  });

  it('extracts to EOF when Validation is the last section', () => {
    const md = '# Title\n\n## Validation\n\ntrailing body';
    const section = extractValidationSection(md);
    assert.match(section, /trailing body/);
  });

  it('returns null when there is no Validation heading', () => {
    assert.equal(extractValidationSection('# Title\n\n## Out of scope\n'), null);
  });

  it('stops at a next heading with incidental leading whitespace (regression)', () => {
    const md = '# T\n\n## Validation\n\nbody\n\n ## Out of scope\n\nleaked';
    const section = extractValidationSection(md);
    assert.match(section, /body/);
    assert.doesNotMatch(section, /leaked/);
  });
});

// --- extractFixtureHint ---

describe('extractFixtureHint', () => {
  it('reads the validation:fixture comment', () => {
    assert.equal(extractFixtureHint('<!-- validation:fixture foo.json -->'), 'foo.json');
  });

  it('returns null when absent', () => {
    assert.equal(extractFixtureHint('no comment here'), null);
  });
});

// --- parseInvariantTable ---

describe('parseInvariantTable', () => {
  it('parses invariant rows, skipping header and separator', () => {
    const section = [
      '| id | name | rule | assert |',
      '|----|------|------|--------|',
      '| V1 | Foo | Foo must hold | `r.a === 1` |',
    ].join('\n');
    const rows = parseInvariantTable(section);
    assert.deepEqual(rows, [{ id: 'V1', name: 'Foo', rule: 'Foo must hold', assert: 'r.a === 1' }]);
  });

  it('returns [] when there are no rows', () => {
    assert.deepEqual(parseInvariantTable('no table here'), []);
  });

  it('preserves an escaped \\| pipe in the assert cell (the || operator, regression)', () => {
    const section = '| V1 | Or | a or b | `r.a === 1 \\|\\| r.b === 2` |';
    const rows = parseInvariantTable(section);
    assert.deepEqual(rows, [{ id: 'V1', name: 'Or', rule: 'a or b', assert: 'r.a === 1 || r.b === 2' }]);
  });

  it('reports a row with an UNESCAPED pipe as malformed instead of silently truncating (regression)', () => {
    const section = '| V1 | Or | a or b | `r.a === 1 || r.b === 2` |';
    const rows = parseInvariantTable(section);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].malformed, true);
  });
});

// --- evaluateAssert ---

describe('evaluateAssert', () => {
  it('evaluates arithmetic and comparison over dot-paths', () => {
    const fixture = { totals: { clients: 10 }, a: { clients: 4 }, b: { clients: 6 } };
    assert.equal(evaluateAssert('r.totals.clients === r.a.clients + r.b.clients', fixture), true);
  });

  it('evaluates a <= boundary rule', () => {
    const fixture = { c1: { clients: 400 }, addressable: { clients: 900 }, exclusions: { clients: 100 } };
    assert.equal(evaluateAssert('r.c1.clients <= r.addressable.clients - r.exclusions.clients', fixture), true);
    assert.equal(evaluateAssert('r.c1.clients <= r.addressable.clients - r.addressable.clients', fixture), false);
  });

  it('evaluates || and && including short-circuit sides (regression: RHS must still be parsed)', () => {
    const fixture = { a: 1, b: 2 };
    assert.equal(evaluateAssert('r.a === 1 || r.b === 2', fixture), true); // LHS true — || short-circuit side
    assert.equal(evaluateAssert('r.a === 9 || r.b === 2', fixture), true);
    assert.equal(evaluateAssert('r.a === 9 || r.b === 9', fixture), false);
    assert.equal(evaluateAssert('r.a === 1 && r.b === 2', fixture), true);
    assert.equal(evaluateAssert('r.a === 9 && r.b === 2', fixture), false); // LHS false — && short-circuit side
    assert.equal(evaluateAssert('(r.a === 1 || r.b === 9) && r.b === 2', fixture), true);
  });

  it('rejects any identifier other than r', () => {
    assert.throws(() => evaluateAssert('process.exit(0)', {}), /may only reference the fixture root as "r"/);
  });

  it('rejects unrecognised characters', () => {
    assert.throws(() => evaluateAssert('r.a; console.log(1)', { a: 1 }));
  });

  it('tolerates trailing whitespace (regression — evaluateAssert is a standalone export)', () => {
    assert.equal(evaluateAssert('r.a ', { a: 1 }), 1);
  });
});

// --- extractReconciliationSection ---

describe('extractReconciliationSection', () => {
  it('extracts body between ## Reconciliation and the next ## heading', () => {
    const md = '# Title\n\n## Reconciliation\n\nsome body\n\n## Validation\n\nmore';
    const section = extractReconciliationSection(md);
    assert.match(section, /some body/);
    assert.doesNotMatch(section, /more/);
  });

  it('extracts to EOF when Reconciliation is the last section', () => {
    const md = '# Title\n\n## Reconciliation\n\ntrailing body';
    assert.match(extractReconciliationSection(md), /trailing body/);
  });

  it('returns null when there is no Reconciliation heading', () => {
    assert.equal(extractReconciliationSection('# Title\n\n## Validation\n'), null);
  });
});

// --- countReconciliationAssertions ---

describe('countReconciliationAssertions', () => {
  it('counts bare bullet lines', () => {
    const body = '- First assertion\n- Second assertion\n';
    assert.equal(countReconciliationAssertions(body), 2);
  });

  it('counts task-list bullets', () => {
    const body = '- [ ] First\n- [x] Second\n';
    assert.equal(countReconciliationAssertions(body), 2);
  });

  it('does not count table rows (only bullet lines are assertions)', () => {
    const body = '| region | source | behaviour |\n|--------|--------|----------|\n| main | API | authoritative |\n';
    assert.equal(countReconciliationAssertions(body), 0);
  });

  it('counts mixed bullets and non-bullet lines correctly', () => {
    const body = '**Authoritative source:** API\n\n- First assertion\n- Second assertion\n\nSome prose.\n';
    assert.equal(countReconciliationAssertions(body), 2);
  });

  it('returns 0 for an empty or comment-only section', () => {
    const body = '\n<!-- reconciliation:not-applicable -->\n\n';
    assert.equal(countReconciliationAssertions(body), 0);
  });
});

// --- runCli (end-to-end against the bundled worked example) ---

describe('runCli — worked example', () => {
  it('passes both invariants against the bundled example fixture', () => {
    const code = runCli([EXAMPLE_SPEC, EXAMPLE_FIXTURE]);
    assert.equal(code, 0);
  });

  it('resolves the fixture from the <!-- validation:fixture --> hint when omitted', () => {
    const code = runCli([EXAMPLE_SPEC]);
    assert.equal(code, 0);
  });

  it('fails (exit 1) against a broken fixture', () => {
    const dir = mkdtempSync(path.join(tmpdir(), 'spec-validate-test-'));
    const brokenFixture = path.join(dir, 'broken.json');
    writeFileSync(
      brokenFixture,
      JSON.stringify({
        totals: { clients: 999 },
        addressable: { clients: 900 },
        exclusions: { clients: 100 },
        c1: { clients: 400 },
        c2: { clients: 300 },
        c3: { clients: 200 },
      })
    );
    const code = runCli([EXAMPLE_SPEC, brokenFixture]);
    assert.equal(code, 1);
  });

  it('exits 2 when the spec has no ## Validation section', () => {
    const dir = mkdtempSync(path.join(tmpdir(), 'spec-validate-test-'));
    const specPath = path.join(dir, 'no-section.md');
    writeFileSync(specPath, '# No Validation here\n');
    const code = runCli([specPath, EXAMPLE_FIXTURE]);
    assert.equal(code, 2);
  });

  it('exits 2 when the spec file does not exist', () => {
    const code = runCli(['/does/not/exist.md', EXAMPLE_FIXTURE]);
    assert.equal(code, 2);
  });

  it('evaluates an escaped \\|\\| (logical-OR) invariant end to end', () => {
    const dir = mkdtempSync(path.join(tmpdir(), 'spec-validate-test-'));
    const specPath = path.join(dir, 'or-spec.md');
    const fixturePath = path.join(dir, 'or-fixture.json');
    writeFileSync(fixturePath, JSON.stringify({ a: 1, b: 2 }));
    writeFileSync(
      specPath,
      [
        '## Validation',
        '',
        '| id | name | rule | assert |',
        '|----|------|------|--------|',
        '| V1 | Or | a is 1 or b is 9 | `r.a === 1 \\|\\| r.b === 9` |',
        '',
      ].join('\n')
    );
    assert.equal(runCli([specPath, fixturePath]), 0);
  });

  it('exits 1 loudly on a row with an unescaped pipe (never silently truncates)', () => {
    const dir = mkdtempSync(path.join(tmpdir(), 'spec-validate-test-'));
    const specPath = path.join(dir, 'bad-pipe-spec.md');
    writeFileSync(
      specPath,
      [
        '## Validation',
        '',
        '| id | name | rule | assert |',
        '|----|------|------|--------|',
        '| V1 | Or | a is 1 or b is 9 | `r.a === 1 || r.b === 9` |',
        '',
      ].join('\n')
    );
    assert.equal(runCli([specPath, EXAMPLE_FIXTURE]), 1);
  });
});
