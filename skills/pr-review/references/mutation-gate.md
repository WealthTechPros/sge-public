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

**Invocation (issue #2343 — the live wiring, extended to `platform/app/frontend/` by issue #2375;
§5's "deferred" note in SPEC-120 is now closed for the TS/JS leg):**

```bash
node scripts/mutation-diff-gate.mjs --base origin/main --head HEAD \
  --mode "$TEST_MAP_MODE" [--override-trailer "$OVERRIDE_TRAILER"] --out mutation-gate-result.json
```

Prints (and optionally writes to `--out`) the JSON verdict: `{status, score, counted, findings[],
overrideApplied, changedFiles, mutatableFiles}`. Read `status`/`score`/`findings` directly into the
`sge-verdict` block and Phase 5 aggregate — no further parsing needed.

Mechanically, the script (`scripts/mutation-diff-gate.mjs`):

1. Computes the diff's changed/added line numbers — `git diff <base>...<head> --unified=0` (same
   mechanism the diff-coverage gate uses).
2. Groups the diff's changed files by mutatable package dir (`platform/app/backend/` and
   `platform/app/frontend/` — both TS/JS via Stryker; this repo's Python surface is tooling/services,
   not mutation-testable app logic, so no mutmut leg is wired yet — see "Engine coverage" below) and
   runs Stryker **scoped to exactly those changed files** (`mutate:` set to the diff's file list, never
   the whole package).
3. Parses the engine's report with the existing `packages/mutation-collector` `parseMutationReport`
   (Stryker JSON / mutmut text, both already supported) — never a second hand-rolled parser.
4. Scores via `evaluateDiffMutationGate` (`counted`/`score`/`findings`, SPEC-120, distinct from
   `evaluateC35`'s scheduled per-spec check). No valid in-diff mutants → `mutation_gate: not-applicable`;
   no mutatable file in the diff at all, or the engine produced no report → `mutation_gate: not-run` —
   never a fabricated fail either way.

## Engine coverage (TS/JS today, mutmut deferred)

`@stryker-mutator/core` + `@stryker-mutator/vitest-runner` are installed as devDependencies in both
`platform/app/backend/` (issue #2343) and `platform/app/frontend/` (issue #2375) — both dirs are wired
into `MUTATABLE_DIRS` and each has its own `vitest.config.ts` the script's dynamically-generated Stryker
config points at. The repo's Python files (`scripts/`, `services/*-pod/`) are tooling, not
mutation-testable app logic, so a mutmut leg is deferred until a repo maps Python `sourcePaths` with real
logic to mutate (mirrors `mutation-collector.yml`'s existing no-op-detection posture for the scheduled
C35 run) — tracked as a remaining deferral from #2375.

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
