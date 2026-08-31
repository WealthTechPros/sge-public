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

## When no engine is reachable — the manual fallback (issue #2511)

**`mutation_gate: not-run` is not a pass.** It records that nothing was checked. Treated as a
clean result it becomes the very defect this gate exists to catch, one level up: absence of
coverage rendering as absence of problems. So `not-run` obliges the reviewer to fall back to the
manual check below, and the verdict must say which of the two produced the score.

This is not a rare path. The wiring above is `sge`-internal — `scripts/mutation-diff-gate.mjs`
hardcodes `MUTATABLE_DIRS` to `platform/app/backend/` and `platform/app/frontend/`, and the
published plugin does not carry the script. **The reason is the reference form, not `.claude-plugin`
scope** (#2514 review): `publish-public.yml` harvests any sibling a *`SKILL.md`* references as
`${CLAUDE_PLUGIN_ROOT}/<path>` and fails the publish if it is missing, but it scans SKILL.md files
only and matches that form only — the invocation above is plain `node scripts/mutation-diff-gate.mjs`
inside a reference doc, which the workflow calls its own "DELIBERATE limitation … plain-form-only".
So every other WTP repo consuming `/sge:pr-review` gets the pointer and no engine, and the gate
records `mutation_gate: not-run`. **`not-run` is the default outside this repo, not the exception.**

Worth knowing if the wiring is ever fixed: that makes the "other half" smaller than a packaging
redesign — a `${CLAUDE_PLUGIN_ROOT}`-form reference from a SKILL.md plus per-repo `MUTATABLE_DIRS`
(and a Node dependency in the consumer repo). The manual fallback stays useful even then: no engine
mutates the prose assertions that motivated this, such as `#328`'s error message.

### When the manual fallback is required

The diff touches a **guard, gate, error path, or security control** — and the automated gate
recorded `not-run` or `not-applicable`. Four moves, applied to exactly what the test claims to
protect:

| Move | What it corrupts |
|---|---|
| **Gut** | replace a message/payload the consumer reads with a placeholder |
| **Invert** | flip the condition the guard turns on |
| **Drop the discriminator** | remove the field/code that distinguishes one case from another |
| **Neutralise** | make the guard a no-op for the duration of the check |

Then: **confirm the suite fails, and that the failure names the right thing.** A suite that goes
red for an unrelated reason proves nothing about the guard — read the assertion message, not just
the exit code. Restore, and confirm green.

### Why manual mutation catches what reading does not

`trust-fabric#328` added a `PermissionInsufficientError` naming the missing Graph permission, with
two tests that looked like coverage. Gutting the production message to `"something went wrong"`
left **330/330 green**. The assertions watched channels the consumer never sees: one asserted
`missingPermission`, a field `classifyError` structurally discards before publication; the other
supplied its *own* hand-written message, so it could not observe production's. The README promised
that permission was named, and the prose was the only channel carrying it to an auditor.

**Corollary — assert on the published surface.** A field a serialiser, classifier, or DTO boundary
discards is not what the consumer reads. Ask what the auditor, caller, or log line *actually
receives*, and assert there.

### Guard rails

- **Assert the anchor was found.** Anchor each mutation by content match and check the match
  succeeded (`assert old in s`) — a mutation that silently no-ops is indistinguishable from a
  killed mutant. This misfired once during the `#328` investigation and only the assertion caught it.
- **Restore via `git checkout -- <path>` and verify `git status` is clean** before moving on. Never
  leave a mutation in the tree.
- **Never commit a mutation.** It is a verification step, not an artefact.

A surviving mutant found manually carries the same finding shape and `major`/`test-fidelity`
severity as the automated path above.

Full design: [`SPEC-120`](../../../docs/specs/SPEC-120-pr-review-mutation-gate.md).
