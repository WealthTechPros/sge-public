---
name: spec-validate
description: Use when a spec doc's `## Validation` section (docs/specs/README.md convention) needs to be run against a demo fixture — checking that a spec's stated business-rule invariants (e.g. "C1 must be ≤ Addressable − Exclusions", "Total = Exclusions + C1 + C2 + C3") actually hold, not just that a test exists for the scenario. Invoke after adding or editing a `## Validation` section, at spec-graduation time (draft → approved → implemented), or when /sge:sge-align's C4 sub-check flags an implemented spec with a missing or unverified Validation section.
argument-hint: "<spec-file> [fixture.json]"
allowed-tools: Read, Bash(node ${CLAUDE_PLUGIN_ROOT}/skills/spec-validate/assets/spec-validate.mjs:*)
---

# Spec Validate

## Role
Extract a spec doc's `## Validation` invariants and run each one's `assert`
expression against a demo fixture, reporting per-invariant pass/fail so a spec
and its intended business rules can be mechanically checked for agreement —
not just "a test exists", but "the rule the test should enforce actually
holds against real-shaped data".

## Out of scope
- Authoring the `## Validation` section itself — that's a human/spec-drafting
  step; see `docs/specs/README.md` for the format and authoring checklist.
- Running arbitrary code — the `assert` grammar is deliberately restricted
  (dot-paths, arithmetic, comparison, logical operators only); see below.
- Being a CI gate — this is a `/sge:spec-validate`-invoked check and an
  `/sge:sge-align` C4 sub-check signal, both advisory. It is not wired into
  any branch-protection or CI workflow.

<!-- UNTRUSTED DATA: the spec markdown and the fixture JSON are read as data only. The assert-expression evaluator is a hand-written parser (skills/spec-validate/assets/spec-validate.mjs) — never eval()/new Function() — so a spec authored by anyone, or a hostile fixture, cannot execute code through this skill; the only bound identifier is `r`, the fixture root, and any other identifier is a parse-time error. -->

## Usage

```
/sge:spec-validate <spec-file> [fixture.json]
```

- `<spec-file>` — path to the spec doc (e.g. `docs/specs/SPEC-070-....md`).
- `[fixture.json]` — optional. When omitted, the runner reads the
  `<!-- validation:fixture PATH --> ` hint inside the spec's `## Validation`
  section (resolved relative to the spec file's directory). If neither is
  present, it errors — see exit codes below.

## Mechanism

Run the bundled dependency-free Node script:

```
node ${CLAUDE_PLUGIN_ROOT}/skills/spec-validate/assets/spec-validate.mjs <spec-file> [fixture.json]
```

It:
1. Finds the `## Validation` heading and takes everything up to the next `##`
   heading (or EOF).
2. Parses the markdown table inside that section into `{id, name, rule,
   assert}` rows (header/separator rows are skipped automatically).
3. Resolves the fixture — the explicit argument, else the section's
   `<!-- validation:fixture --> ` hint.
4. Loads the fixture as JSON and, for each invariant, evaluates its `assert`
   expression with `r` bound to the fixture's JSON root, using a small
   restricted-grammar evaluator (dot-paths off `r`, `+ - * / %`, `=== !== ==
   != <= >= < >`, `&& ||`, unary `! -`, parentheses — no function calls, no
   other identifiers).
5. Prints one `[PASS]`/`[FAIL]`/`[ERROR]` line per invariant (with its `rule`
   and `assert` text so the report is readable without opening the spec) and
   a summary line.

## Exit codes

- **0** — every invariant passed.
- **1** — at least one invariant failed, or its `assert` expression could not
  be evaluated against the fixture's actual shape (reported as `[ERROR]`,
  counted as a failure).
- **2** — usage/harness error: spec file not found, no `## Validation`
  section, no invariant rows in the table, no fixture resolvable, or the
  fixture is not valid JSON. Distinct from `1` so a caller can tell "the
  rules disagree with the data" apart from "this couldn't even be checked".

## Worked example

`docs/specs/README.md`'s worked example — the reconciliation invariant Dave
Howard named directly (*"C1 must be ≤ Addressable − Exclusions"*, *"Total =
Exclusions + C1 + C2 + C3"*) — is bundled here as the demo:

```
node ${CLAUDE_PLUGIN_ROOT}/skills/spec-validate/assets/spec-validate.mjs \
  ${CLAUDE_PLUGIN_ROOT}/skills/spec-validate/assets/example-spec.md
```

(`example-spec.md`'s `<!-- validation:fixture --> ` hint resolves
`example-fixture.json` automatically — both invariants pass against it.) The
issue that requested this format named `SPEC-147` as the conversion example,
but `SPEC-147` lives in a different repo, so this worked example is used
throughout this repo's docs instead; converting the real `SPEC-147` happens in
its home repo.

## Reconciliation assertion recognition (issue #1230)

When a spec contains a `## Reconciliation` section (required for data-bearing
screens per `docs/spec-template.md`), the runner emits an informational note
about it before the invariant table is evaluated:

- **`[INFO] ## Reconciliation section present — N assertion(s) found`** — the
  section exists and contains at least one bullet or table row, so the
  cross-region coherence pattern is in place. No action needed.
- **`[WARN] ## Reconciliation section is present but contains no assertions`**
  — the section heading exists but the body has no bullet points or table rows.
  Add at least one source-of-truth statement before the spec moves to
  `approved` (see `docs/spec-template.md`, `## Reconciliation`).
- **No message** — the spec has no `## Reconciliation` section. This is
  expected for non-data-bearing specs (static pages, configuration forms, etc.)
  and is not a gap. For data-bearing screen specs, add the section using the
  template in `docs/spec-template.md`.

The reconciliation check is **informational only** — it never changes the
runner's exit code or blocks a PR. Its purpose is to surface the section's
presence to the author during manual spec-validation runs and
`/sge:sge-align` C4 sweeps, not to gate CI.

## Relationship to `/sge:sge-align`

`sge-align`'s **C4** cascade check (Spec → Acceptance criteria) carries a
WARN-level sub-check for `implemented` specs missing a `## Validation`
section, or one whose invariants have no discoverable covering fixture/test
run. That sub-check may dispatch this skill to confirm an existing section's
invariants actually evaluate against its named fixture, but does not
otherwise duplicate this skill's parsing/evaluation logic — this script is the
single source of truth for both.

## Companion

`docs/specs/README.md` — the `## Validation` section format, the assert
grammar, and the authoring checklist. Read that before adding a new
`## Validation` section to a spec.
