#!/usr/bin/env node
/**
 * spec-validate.mjs — runs a spec doc's `## Validation` invariants against a
 * demo fixture and reports per-invariant pass/fail (issue #761 — the enabler
 * for sgd#762's coherence-gate ratchet).
 *
 * Format convention: docs/specs/README.md. A spec's `## Validation` section
 * holds a markdown table of invariants (id | name | rule | assert). `assert`
 * is a small restricted expression — dot-paths off the single bound name `r`
 * (the fixture's JSON root), arithmetic, comparison, logical operators —
 * evaluated with a hand-written tokenizer + recursive-descent parser, never
 * eval()/new Function(). A spec file or a hostile fixture can only ever
 * select and compare *data*; there is no way to execute code through it.
 *
 * No external dependencies (matches this repo's scripts/*.mjs convention —
 * see scripts/build-sgd-dag.mjs's header, dependency-free by the same
 * rule: there is no root package.json/node_modules for a bundled script to
 * resolve against once this plugin is installed into a consumer repo).
 *
 * Usage:
 *   node spec-validate.mjs <spec.md> [fixture.json]
 *
 * Fixture resolution when the second argument is omitted: a
 * `<!-- validation:fixture <path> -->` comment inside the Validation section,
 * resolved relative to the spec file's own directory.
 *
 * Exit codes:
 *   0 = all invariants pass.
 *   1 = at least one invariant fails (or errors while evaluating).
 *   2 = usage/harness error — missing file, no "## Validation" section, no
 *       invariant rows, no fixture resolvable, or a fixture that isn't valid
 *       JSON. Distinct from 1 so callers can tell "the rules disagree with
 *       the data" apart from "this couldn't even be checked".
 */
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

// ─── Validation-section extraction ──────────────────────────────────────────

/** Returns the raw text between a `## Validation` heading and the next `##`
 * heading (or EOF), or null if no such heading exists. */
export function extractValidationSection(markdown) {
  const lines = markdown.split(/\r?\n/);
  const startIdx = lines.findIndex((l) => /^##\s+Validation\s*$/i.test(l.trim()));
  if (startIdx === -1) return null;
  const rest = lines.slice(startIdx + 1);
  // Trim for the end boundary too (same tolerance as the start heading above) —
  // otherwise a next heading with incidental leading whitespace is missed and
  // the section silently absorbs everything after it.
  const endOffset = rest.findIndex((l) => /^##\s+\S/.test(l.trim()));
  const body = endOffset === -1 ? rest : rest.slice(0, endOffset);
  return body.join('\n');
}

/** Reads the optional `<!-- validation:fixture PATH -->` hint. */
export function extractFixtureHint(sectionText) {
  const m = sectionText.match(/<!--\s*validation:fixture\s+(\S+)\s*-->/);
  return m ? m[1] : null;
}

/**
 * Returns the raw text of the `## Reconciliation` section (between its heading
 * and the next `##` heading or EOF), or null if no such heading is present.
 *
 * Used by the CLI runner to emit an informational note when the section is
 * present — recognition only, not enforcement; the section's presence or
 * absence does not change the runner's exit code (docs/specs/README.md,
 * issue #1230).
 */
export function extractReconciliationSection(markdown) {
  const lines = markdown.split(/\r?\n/);
  const startIdx = lines.findIndex((l) => /^##\s+Reconciliation\s*$/i.test(l.trim()));
  if (startIdx === -1) return null;
  const rest = lines.slice(startIdx + 1);
  const endOffset = rest.findIndex((l) => /^##\s+\S/.test(l.trim()));
  const body = endOffset === -1 ? rest : rest.slice(0, endOffset);
  return body.join('\n');
}

/**
 * Returns the count of reconciliation assertions found in the Reconciliation
 * section — lines starting with `- ` (bullet or task list item). Returns 0
 * when the section is present but has no bullet assertion lines.
 *
 * Bullets are used rather than table rows because the Reconciliation section's
 * table format (if any) is not standardised across specs, whereas bullet-form
 * assertions are the convention established by docs/spec-template.md.
 */
export function countReconciliationAssertions(sectionText) {
  const lines = sectionText.split(/\r?\n/);
  return lines.filter((l) => l.trim().startsWith('- ')).length;
}

/** Splits one table row's inner text into cells on unescaped `|` only.
 * GFM's rule for a literal pipe inside a cell is to escape it as `\|` —
 * an assert expression using the grammar's `||` operator must therefore be
 * written `\|\|` in the table (docs/specs/README.md). The escape is undone
 * here, so the stored assert text carries the real `||`. */
function splitRowCells(inner) {
  const cells = [];
  let cur = '';
  for (let i = 0; i < inner.length; i++) {
    const ch = inner[i];
    if (ch === '\\' && inner[i + 1] === '|') {
      cur += '|';
      i++;
    } else if (ch === '|') {
      cells.push(cur.trim());
      cur = '';
    } else {
      cur += ch;
    }
  }
  cells.push(cur.trim());
  return cells;
}

/** Parses the invariant table rows into {id, name, rule, assert}, skipping
 * the header row and the `|---|---|` separator row. Rows with FEWER than 4
 * cells, or an empty id/assert cell, are silently skipped — malformed
 * decoration, not a real invariant. Rows with MORE than 4 cells are returned
 * as `{malformed: true, raw}` records — the classic cause is an unescaped
 * `||` in the assert cell (must be `\|\|` per GFM), and silently truncating
 * or dropping such a row would hand back a wrong verdict, so the runner
 * reports it loudly instead. */
export function parseInvariantTable(sectionText) {
  const rows = sectionText
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.startsWith('|') && l.endsWith('|'));

  const invariants = [];
  for (const row of rows) {
    const cells = splitRowCells(row.slice(1, -1));
    if (cells.length < 4) continue;
    const [id, name, rule, assertRaw] = cells;
    if (/^id$/i.test(id)) continue; // header row
    if (/^:?-+:?$/.test(id)) continue; // separator row (---, :---, ---:, :---:)
    if (cells.length > 4) {
      invariants.push({ malformed: true, raw: row });
      continue;
    }
    const assertExpr = assertRaw.replace(/^`+|`+$/g, '').trim();
    if (!id || !assertExpr) continue;
    invariants.push({ id, name, rule, assert: assertExpr });
  }
  return invariants;
}

// ─── Safe restricted-expression evaluator ──────────────────────────────────
//
// Grammar (lowest to highest precedence):
//   logicalOr      := logicalAnd ('||' logicalAnd)*
//   logicalAnd     := equality ('&&' equality)*
//   equality       := relational (('===' | '!==' | '==' | '!=') relational)*
//   relational     := additive (('<=' | '>=' | '<' | '>') additive)*
//   additive       := multiplicative (('+' | '-') multiplicative)*
//   multiplicative := unary (('*' | '/' | '%') unary)*
//   unary          := ('!' | '-') unary | primary
//   primary        := number | string | path | '(' logicalOr ')'
//   path           := 'r' ('.' IDENT)*
//
// No function calls, no assignment, no identifier other than `r` — a spec's
// assert expression can only read fixture data and compare/combine it.

const TOKEN_RE =
  /\s*(===|!==|==|!=|<=|>=|&&|\|\||[()+\-*/%<>!.]|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[0-9]+(?:\.[0-9]+)?|[A-Za-z_$][A-Za-z0-9_$]*)/g;

function tokenize(expr) {
  const tokens = [];
  let idx = 0;
  TOKEN_RE.lastIndex = 0;
  let m;
  while ((m = TOKEN_RE.exec(expr))) {
    if (m.index !== idx) {
      throw new Error(`unrecognised input near "${expr.slice(idx, m.index + 1)}"`);
    }
    tokens.push(m[1]);
    idx = TOKEN_RE.lastIndex;
  }
  // Pure trailing whitespace is fine — TOKEN_RE only consumes whitespace as a
  // prefix to a token, so `r.a ` would otherwise leave " " unconsumed.
  if (idx !== expr.length && expr.slice(idx).trim() !== '') {
    throw new Error(`unrecognised trailing input: "${expr.slice(idx)}"`);
  }
  return tokens;
}

class Parser {
  constructor(tokens, scope) {
    this.tokens = tokens;
    this.pos = 0;
    this.scope = scope;
  }
  peek() {
    return this.tokens[this.pos];
  }
  next() {
    return this.tokens[this.pos++];
  }
  expect(tok) {
    const got = this.next();
    if (got !== tok) throw new Error(`expected "${tok}", saw "${got}"`);
  }

  parse() {
    const v = this.logicalOr();
    if (this.pos !== this.tokens.length) throw new Error('unexpected trailing tokens');
    return v;
  }

  // NOTE: the right operand is always PARSED (never short-circuited past) —
  // `v || this.logicalAnd()` would skip the RHS parse when v is truthy,
  // leaving unconsumed tokens and a spurious "unexpected trailing tokens"
  // error. Eager RHS evaluation is value-identical here: the grammar has no
  // side effects and dot-path reads never throw on missing fields.
  logicalOr() {
    let v = this.logicalAnd();
    while (this.peek() === '||') {
      this.next();
      const r = this.logicalAnd();
      v = v || r;
    }
    return v;
  }
  logicalAnd() {
    let v = this.equality();
    while (this.peek() === '&&') {
      this.next();
      const r = this.equality();
      v = v && r;
    }
    return v;
  }
  equality() {
    let v = this.relational();
    while (['===', '!==', '==', '!='].includes(this.peek())) {
      const op = this.next();
      const r = this.relational();
      if (op === '===') v = v === r;
      else if (op === '!==') v = v !== r;
      else if (op === '==') v = v == r; // eslint-disable-line eqeqeq
      else v = v != r; // eslint-disable-line eqeqeq
    }
    return v;
  }
  relational() {
    let v = this.additive();
    while (['<=', '>=', '<', '>'].includes(this.peek())) {
      const op = this.next();
      const r = this.additive();
      if (op === '<=') v = v <= r;
      else if (op === '>=') v = v >= r;
      else if (op === '<') v = v < r;
      else v = v > r;
    }
    return v;
  }
  additive() {
    let v = this.multiplicative();
    while (this.peek() === '+' || this.peek() === '-') {
      const op = this.next();
      const r = this.multiplicative();
      v = op === '+' ? v + r : v - r;
    }
    return v;
  }
  multiplicative() {
    let v = this.unary();
    while (this.peek() === '*' || this.peek() === '/' || this.peek() === '%') {
      const op = this.next();
      const r = this.unary();
      v = op === '*' ? v * r : op === '/' ? v / r : v % r;
    }
    return v;
  }
  unary() {
    if (this.peek() === '!') {
      this.next();
      return !this.unary();
    }
    if (this.peek() === '-') {
      this.next();
      return -this.unary();
    }
    return this.primary();
  }
  primary() {
    const tok = this.peek();
    if (tok === undefined) throw new Error('unexpected end of expression');
    if (tok === '(') {
      this.next();
      const v = this.logicalOr();
      this.expect(')');
      return v;
    }
    if (/^[0-9]/.test(tok)) {
      this.next();
      return Number(tok);
    }
    if (/^["']/.test(tok)) {
      this.next();
      return tok.slice(1, -1).replace(/\\(.)/g, '$1');
    }
    if (/^[A-Za-z_$]/.test(tok)) {
      return this.path();
    }
    throw new Error(`unexpected token "${tok}"`);
  }
  path() {
    const name = this.next();
    if (name !== 'r') {
      throw new Error(
        `assert expressions may only reference the fixture root as "r" (saw "${name}") — see docs/specs/README.md`
      );
    }
    let value = this.scope.r;
    while (this.peek() === '.') {
      this.next();
      const field = this.next();
      if (field === undefined || !/^[A-Za-z_$][A-Za-z0-9_$]*$/.test(field)) {
        throw new Error(`invalid field access after "."`);
      }
      value = value == null ? undefined : value[field];
    }
    return value;
  }
}

/** Evaluates a restricted assert expression against `fixture`, bound as `r`. */
export function evaluateAssert(expr, fixture) {
  const tokens = tokenize(expr);
  const parser = new Parser(tokens, { r: fixture });
  return parser.parse();
}

// ─── CLI ────────────────────────────────────────────────────────────────────

// Logs and returns 2 — does NOT touch `process.exitCode`. That mutation is
// left to the `invokedDirectly` CLI wrapper below (`process.exit(runCli(...))`);
// setting it here as a side effect would leak into any host process that
// imports `runCli` as a library (e.g. this script's own test suite), making
// every subsequent call look like it failed even after a passing one.
function usageError(msg) {
  console.error(`spec-validate: ${msg}`);
}

export function runCli(argv) {
  const [specPath, fixtureArgPath] = argv;
  if (!specPath) {
    usageError('usage: node spec-validate.mjs <spec.md> [fixture.json]');
    return 2;
  }
  if (!existsSync(specPath)) {
    usageError(`spec file not found: ${specPath}`);
    return 2;
  }

  const markdown = readFileSync(specPath, 'utf8');

  // Reconciliation section — informational recognition only (issue #1230).
  // Presence/absence does not change exit code; it informs the author whether
  // the cross-region coherence pattern is in place.
  const reconciliationSection = extractReconciliationSection(markdown);
  if (reconciliationSection !== null) {
    const assertionCount = countReconciliationAssertions(reconciliationSection);
    if (assertionCount === 0) {
      console.log(
        `[WARN] ## Reconciliation section is present but contains no assertions — ` +
        `add at least one source-of-truth statement (docs/spec-template.md)\n`
      );
    } else {
      console.log(`[INFO] ## Reconciliation section present — ${assertionCount} assertion(s) found\n`);
    }
  }

  const section = extractValidationSection(markdown);
  if (section === null) {
    usageError(`no "## Validation" section found in ${specPath} — see docs/specs/README.md`);
    return 2;
  }

  const invariants = parseInvariantTable(section);
  if (invariants.length === 0) {
    usageError(`"## Validation" section in ${specPath} has no invariant rows`);
    return 2;
  }

  let fixturePath = fixtureArgPath;
  if (!fixturePath) {
    const hint = extractFixtureHint(section);
    if (hint) fixturePath = path.resolve(path.dirname(specPath), hint);
  }
  if (!fixturePath) {
    usageError('no fixture given and no <!-- validation:fixture --> hint found in the spec');
    return 2;
  }
  if (!existsSync(fixturePath)) {
    usageError(`fixture file not found: ${fixturePath}`);
    return 2;
  }

  let fixture;
  try {
    fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
  } catch (e) {
    usageError(`fixture is not valid JSON: ${e.message}`);
    return 2;
  }

  console.log(`spec-validate: ${specPath} against ${fixturePath}\n`);
  let failures = 0;
  for (const inv of invariants) {
    if (inv.malformed) {
      failures++;
      console.log(`[ERROR] malformed invariant row (more than 4 cells — an unescaped "|"?)`);
      console.log(`        row:    ${inv.raw}`);
      console.log(`        hint:   a literal "|" inside a table cell must be escaped as "\\|" (so the || operator is written \\|\\|) — see docs/specs/README.md`);
      console.log('');
      continue;
    }
    let result;
    let error = null;
    try {
      result = evaluateAssert(inv.assert, fixture);
    } catch (e) {
      error = e.message;
      result = false;
    }
    const status = error ? 'ERROR' : result ? 'PASS' : 'FAIL';
    if (status !== 'PASS') failures++;
    console.log(`[${status}] ${inv.id} — ${inv.name}`);
    console.log(`        rule:   ${inv.rule}`);
    console.log(`        assert: ${inv.assert}`);
    if (error) console.log(`        error:  ${error}`);
    console.log('');
  }

  console.log(
    failures === 0
      ? `${invariants.length}/${invariants.length} invariants passed.`
      : `${invariants.length - failures}/${invariants.length} invariants passed, ${failures} failed.`
  );
  return failures === 0 ? 0 : 1;
}

const invokedDirectly =
  process.argv[1] !== undefined && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));

if (invokedDirectly) {
  process.exit(runCli(process.argv.slice(2)));
}
