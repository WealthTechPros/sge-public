# Diff-scoped coverage gate — changed-line coverage, not just aggregate

The actionable Phase 3 **diff-coverage convention** for `/sge:pr-review`, held here to keep the
SKILL body within its size budget — the full mechanics behind the one-line pointer (issue #2254,
**SPEC-117**). Nothing here is a new control the SKILL body cannot express; it is the detail the
pointer defers.

## Why (the drift this closes)

The aggregate coverage number proves the *repo* is reasonably tested; it cannot prove *this diff*
is — an already-high-coverage repo can hide 40 brand-new, entirely untested lines behind a
barely-moving aggregate. Diff-scoped coverage gates on the lines this PR actually touched, the same
"prove the change, not just the codebase" posture SPEC-070's test-fidelity gate already applies to
test presence.

## Mechanics

When `.sge/test-map.yml` declares an optional `coverage_floor:` percentage:

1. `git diff origin/main...HEAD --unified=0` to get each changed file's **added/changed** line
   numbers. Deleted lines carry no coverage obligation — nothing remains to execute.
2. Intersect against the coverage report the suite's own run just produced — whatever line-level
   format the repo emits (e.g. this repo's `platform/app/backend` vitest run emits v8-provider
   `lcov`/`json` coverage). No per-tool parser is hard-coded centrally; read what the repo already
   produces, matching SPEC-070 §8's "no per-stack catalogue centrally" posture.
3. `diff_coverage = covered_changed_lines / total_changed_lines`.

## Edge cases (fail-closed, never fabricated)

- A changed file **absent** from the coverage report (a new file the suite never touched, or a file
  type it doesn't instrument) counts every one of its added lines as **uncovered**, never excluded —
  excluding it would let a wholly-untested new file pass silently.
- A diff with no added/changed lines anywhere (deletions only) → `diff_coverage: not-applicable`.
- No `coverage_floor` declared → the check is inert, `diff_coverage: not-applicable` — same
  "absence is not a gap" posture as SPEC-070's `driver_boundary_paths`.
- The suite produces no parseable coverage report at all → `diff_coverage: not-run` — never a
  fabricated percentage.

## Below the floor

A `{severity: "major", category: "test-coverage", finding: "diff coverage <pct>% below floor
<floor>%"}` finding, folded into Phase 5's aggregate (same severity class as an unimplemented
requirement, not an automatic hard blocker) — downgraded to advisory-only when `.sge/test-map.yml`'s
`mode:` is `advisory` (the same scalar `require-test-evidence.yml`/SPEC-070 already reads).

Full design: [`SPEC-117`](../../../docs/specs/SPEC-117-diff-scoped-coverage-gate.md).
