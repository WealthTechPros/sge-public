# Suite-order / randomization health gate — a green default-order run does not prove order-independence

The actionable Phase 3 **suite-order gate** for `/sge:pr-review`, held here to keep the SKILL body
within its size budget — the full mechanics behind the one-line pointer (issue #2255, **SPEC-119**).
Nothing here is a new control the SKILL body cannot express; it is the detail the pointer defers.

## Why (the drift this closes)

A suite that is green in its default execution order is not proven order-independent. Shared mutable
state, a leaking fixture, or an implicit assumed execution order can pass every time in default order
and still hide a real test-isolation bug that only a differently-ordered (or parallel/sharded) CI run
would surface. The gate closes that gap by re-running the suite a second time under the runner's own
randomized-order mode and folding any order-dependent failure into the Phase 5 aggregate as a named
finding, rather than leaving it as a silent, unproven assumption.

## When the gate runs

Scoped by `DIFF_RISK` (issue #688's tier, already computed in Phase 3):

- `low` / `medium` / `high` → the gate runs.
- `prose` / `trivial` / `generated` → **skipped**, recorded `suite_order: not-run`. A randomized
  re-run on a non-semantic diff doubles suite runtime for no signal — the gate only earns its cost
  when the diff could plausibly introduce shared-state coupling.

## What the gate does

1. **Detect native randomization support first — never hand-roll a shuffler.** Check the repo's test
   runner for a built-in randomized-order mode:
   - Vitest: `test.sequence.shuffle` config option (this repo's own stack — `platform/app/backend` and
     `platform/app/frontend` are both on Vitest 4.x already; no plugin needed). Invoke: `vitest run --sequence.shuffle`.
   - Jest: `--testSequencer` / built-in randomization. Invoke: `jest --testSequencer=jest-random-sequencer` (or the repo's own configured sequencer).
   - pytest: `pytest-random-order`. Invoke: `pytest -p random_order`.
   - Go: `go test -shuffle=on`. Invoke: `go test -shuffle=on ./...`.
   - No native support in the detected runner → record `suite_order: not-run` and stop. No invented
     shuffler, no fabricated result — an absent capability is not a finding.
2. **Run the suite a second time** with the native shuffle flag enabled, as a **background task
   launched in the same Phase 3 message as the default-order run** (same `bg-wait` release-on-exit
   discipline the SKILL body already requires for every Phase 3 gate — collect or cancel before the
   verdict, on every exit path). Reuse the exact command Phase 3's default-order run already resolved
   from `CLAUDE.md`/`test-scope:`, appending only the native shuffle flag — never a second, independently
   re-derived command:
   ```bash
   # Phase 3 already ran: $SUITE_CMD  (resolved from CLAUDE.md / test-scope:)
   # Append the native shuffle flag for this runner and re-run in background:
   timeout "$SUITE_ORDER_TIMEOUT" bash -c "$SUITE_CMD --sequence.shuffle" > /tmp/suite-order-run.log 2>&1 &
   SUITE_ORDER_PID=$!
   # ... continue Phase 3/4 dispatch; before Phase 5, collect:
   wait "$SUITE_ORDER_PID"; SUITE_ORDER_EXIT=$?
   ```
   (Jest/pytest/Go substitute their own native flag from the table above for `--sequence.shuffle`.)
   The default-order run from the main Phase 3 quality-gate step is unchanged and stays the primary
   gate for `quality_gates` — this is an additional, independent run, not a replacement.
3. **Compare.** Both orders green → `suite_order: randomized`, nothing to flag. Green in default order
   but **failing under randomized order** is itself the signal: a test-isolation bug that default-order
   CI has been silently hiding.
4. **Timeout/budget, tuned against the existing per-tier budget (#688/#888 — [`dispatch-scaling.md`]
   (dispatch-scaling.md#per-tier-budget-issues-688-888)):** `SUITE_ORDER_TIMEOUT` is capped at the same
   wall-clock ceiling as that PR's tier (`low` 5min / `medium` 10min / `high` 20min) — the randomized
   re-run must not itself blow the tier's total budget. A timeout on the re-run (distinct from a test
   *failure*) is **not** a test-isolation finding — record `suite_order: not-run` and note the timeout,
   same fail-closed posture as "no native support": an inconclusive gate is never silently converted
   into a pass or a fail.

## Finding shape and severity

A default-order pass paired with a randomized-order failure folds into Phase 5 as:

```json
{"severity": "major", "category": "test-isolation", "finding": "suite passes in default order but fails under randomized order — <failing test(s)> — test-isolation bug"}
```

Same severity class as the sibling Phase 3 gates (seam-evidence, design-evidence) — not an automatic
hard blocker on its own, but a finding the verdict must carry, never silently dropped. Downgraded to
advisory under `.sge/test-map.yml`'s `mode: advisory` (same escape hatch the other Phase 3/4 gates
already honour for repos not yet ready for a hard gate).
