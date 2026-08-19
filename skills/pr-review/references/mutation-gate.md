# Mutation gate — diff-scoped, risk-scaled surviving-mutant check

The actionable Phase 3 **mutation gate** for `/sge:pr-review`, held here to keep the SKILL body
within its size budget — the full mechanics behind the one-line pointer (issue #2252, **SPEC-120**).
Nothing here is a new control the SKILL body cannot express; it is the detail the pointer defers.

## Why (the drift this closes)

Coverage and test-existence both prove a line *executed*; neither proves a test *asserts* anything
about it. A line can be fully covered by a test that never checks its output — the gate closes that
gap by intentionally corrupting the code (mutants) and confirming a test actually fails when it should.

## When the gate runs

- `DIFF_RISK` `low` / `medium` / `high` → the gate runs. `prose` / `trivial` / `generated` → **skipped**,
  recorded `mutation_gate: not-run` — running a mutation engine on non-semantic diffs wastes the budget
  those tiers exist to save.
- **or** the diff touches a `.sge/test-map.yml` `driver_boundary_paths` file (SPEC-070's boundary glob) —
  always run there regardless of the `DIFF_RISK` tier, the same "boundary always wins" posture SPEC-070
  itself uses.

## What the gate does

1. Run the repo's mutation engine (Stryker for TS/JS, mutmut for Python) **scoped to the diff's changed
   files only**.
2. Intersect the resulting mutants against the diff's changed/added line numbers (same
   `git diff origin/main...HEAD --unified=0` mechanism the diff-coverage gate uses) — a mutant outside
   the changed-line set does not count.
3. Parse the engine's report with the existing `packages/mutation-collector` `parseMutationReport`
   (Stryker JSON / mutmut text, both already supported) — never a second hand-rolled parser.
4. Score via `evaluateDiffMutationGate` (`counted`/`score`/`findings`, SPEC-120, distinct from
   `evaluateC35`'s scheduled per-spec check). No valid in-diff mutants → `mutation_gate: not-applicable`,
   never a fabricated fail.

## Finding shape and severity

A **surviving mutant on a changed line** folds into Phase 5 as:

```json
{"severity": "major", "category": "test-fidelity", "finding": "surviving mutant on changed line <file>:<line> — test executes but does not assert"}
```

Same severity class as an unimplemented requirement — not an automatic hard blocker on its own, but a
finding the verdict must carry. Downgraded to advisory under `.sge/test-map.yml`'s `mode: advisory`.

## Escape hatch

A commit carrying `SGE-Override: MUTATION; <≥10-char reason>` (mirrors SPEC-070's `FIDELITY;` trailer)
passes-with-audit-log for a provably-equivalent mutant.

Full design: [`SPEC-120`](../../../docs/specs/SPEC-120-pr-review-mutation-gate.md).
