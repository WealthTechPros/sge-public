# sge-implement — Phase 4 verify: foreground execution, full-suite default (reference, #2433)

**Run the quality suite synchronously in the foreground.** Reserve a scoped
run for the fallback case below — the default is the full suite, unchanged
from prior behavior.

## Why

Observed on `WealthTechPros/data-remediation` (2026-08-23): two independent
`sge-implement` agents each backgrounded a slow full `pytest -q` run after it
exceeded a ~10-minute inline limit, then waited on a completion signal that
never reliably woke their own turn loop. Both produced five-plus consecutive
task-notifications over up to ~40 minutes — "still waiting for the pytest
monitor," "no state change since the last event" — with **zero forward
progress**, burning tokens and wall-clock on nothing. Both resolved
immediately once told to stop waiting and run the suite as a normal
synchronous foreground command.

The fix for that stall is going synchronous — it is not a reason to also
narrow what gets tested. An earlier draft of this reference made
scoped-to-touched-files the unconditional default without a mechanical
definition of "scoped" or any fallback guard, which risked silently
under-testing a change (Phase 4 reports green while a regression the full
suite would have caught ships). That is corrected below.

## Rule

- **Default: run the full quality suite synchronously in the foreground**,
  as one ordinary command — the same suite Phase 4 has always run, just no
  longer backgrounded.
- **Scoped fallback — only when the full suite would exceed a stated time
  budget.** A repo may declare a Phase-4 time budget in its `CLAUDE.md` (a
  `phase4-budget-minutes` config value, or an explicit prose statement
  of the same). If the full suite's expected or observed run time exceeds
  that budget (or, absent a declared budget, a default of **10 minutes** —
  the threshold this issue's own incident was measured against), fall back
  to a scoped run instead of backgrounding it.
- **The scoped fallback reuses the repo's existing `test-scope:` marker
  convention** ([`dispatch-scaling.md`](../../pr-review/references/dispatch-scaling.md#test-scope-convention))
  — the same fail-closed mechanism `/sge:pr-review` Phase 3 already uses, so
  Phase 4 does not invent a second, looser scoping heuristic:
  1. Grep the repo's `CLAUDE.md` for `test-scope:` marker lines.
  2. **No markers declared** → the fallback is unavailable; run the full
     suite regardless of the time budget (a long full run is preferable to
     an undefined "scoped" run with no fail-closed guard). Use the
     **bounded synchronous poll** ([loops §B](../../loops/SKILL.md#b-wait-for-condition-loop))
     — one tool call, a sleep interval, and an iteration cap — so a long
     wait resolves inside a single turn instead of an unbounded
     background/re-poll loop.
  3. **Markers present** — apply the identical matching rule
     `dispatch-scaling.md` §"How Phase 3 uses it, mechanically" already
     defines: every changed file must match a declared prefix, the unioned
     glob expansion must be non-empty, and no changed file may fall under a
     matched prefix while sitting outside that prefix's declared globs. Any
     ambiguity — unmatched file, empty expansion, incomplete row — falls
     through to the full suite, never to a narrower guess.
- A background task does not hold this phase's turn open; relying on a
  later notification to resume is the anti-pattern this issue describes,
  not a supported wait mechanism, regardless of whether the run is full or
  scoped.
