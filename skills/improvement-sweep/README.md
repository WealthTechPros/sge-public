# improvement-sweep — SGD-044-S3 weekly improvement sweep

The cadence layer that makes **F-EFFICACY (SGD-044)** real. Once a week,
unattended, it reads the three SGE drift **trend surfaces**, picks the single
highest-leverage gap across them, runs the matching `/sge:drift-hillclimb`
dimension for **one bounded PR**, re-measures, and appends the measured delta.

- Skill: [`SKILL.md`](./SKILL.md) — `/sge:improvement-sweep`
- Picker (deterministic): [`assets/select-gap.mjs`](./assets/select-gap.mjs) + its test
- Workflow: [`.github/workflows/improvement-sweep.yml`](../../.github/workflows/improvement-sweep.yml)
- Parent: SGD-044 (`platform/docs/sgd-build/specs/SGD-044-ab-efficacy-protocol.md`), issue #676; slices #831 (S1), #832 (S2), #833 (S3)

## The three dials

| Dial | Trend surface | Lever |
|---|---|---|
| coherence | `docs/sge/drift-trend.jsonl` (Audit Score `audit_score`; legacy `sm2_sample`) | `/sge:drift-hillclimb --max-rounds 1` |
| token-economy | `docs/sge/token-economy-trend.jsonl` (`score-token-economy.mjs` `trendRow`, #831) | `/sge:drift-hillclimb --dimension token-economy --max-rounds 1` |
| skill-quality | `docs/sge/skill-quality-trend.jsonl` (`score-skill-quality.mjs` `trendRow`, #832/#737) | `/sge:drift-hillclimb --dimension skill-quality --max-rounds 1` |

Each dial is normalised to a **leverage in [0,1]** plus a **trendDelta** (change
vs the previous trend row; positive = worsening). The picker ranks by leverage,
then trendDelta (a worsening dial wins ties), then a fixed dial priority
(coherence > token-economy > skill-quality) for full determinism. A dial whose
surface is absent/empty/malformed is `unavailable` — excluded from ranking but
always reported in `skipped[]`.

> The token-economy and skill-quality trend surfaces are produced by S1 (#831)
> and S2 (#832). Until those land on a repo, the sweep simply runs on whatever
> dials exist (typically coherence alone) and reports the other two as
> `unavailable` — it never blocks on them.

## Acceptance invariants (issue #833)

- **Runs unattended on schedule** — weekly cron (`0 7 * * 1`), plus
  `workflow_dispatch` for an on-demand cycle.
- **Never more than one PR per cycle** — the picker returns a *single* dial (or
  none) and the climb is dispatched with `--max-rounds 1`. Enforced structurally
  and asserted in `select-gap.test.mjs`.
- **Every cycle appends a measured delta** — one row per cycle is appended to
  `docs/sge/improvement-sweep.jsonl` via `buildCycleRecord()`, carrying
  `measuredDelta = after − before`.
- **A skipped/failed cycle is visible** — the appended row's `status` is
  `acted | skipped | failed`, with the `skipped[]` detail or `error` string; the
  workflow also publishes the plan to the job summary every run.

## How the workflow acts

The workflow has two jobs:

1. **`pick`** — pure Node, always runs. Unit-tests the picker, runs
   `select-gap.mjs` against the three surfaces, and publishes the plan to the job
   summary + an artifact. No model, no secret required.
2. **`act`** — runs only when a dial was selected, it is not a dry-run, **and**
   the `ANTHROPIC_API_KEY` secret is configured. It dispatches
   `/sge:improvement-sweep`, which performs the bounded climb, re-measure, and
   delta append (Steps 3–5 of the skill).

If `ANTHROPIC_API_KEY` is **not** configured, the `act` job records the guard
message in the summary and stops — the pick plan is still the visible record, and
a control session can run `/sge:improvement-sweep` to act on it. This keeps the
workflow **inert-safe**: it is committed disabled-by-default (no key), does
nothing destructive until an org opts in by adding the secret, and never opens a
PR without the runtime present.

## Running one cycle by hand

```bash
# deterministic pick only (no model, safe anywhere):
node skills/improvement-sweep/assets/select-gap.mjs \
  --coherence docs/sge/drift-trend.jsonl \
  --token docs/sge/token-economy-trend.jsonl \
  --skill-quality docs/sge/skill-quality-trend.jsonl

# full cycle (needs the Claude Code runtime):
/sge:improvement-sweep            # act on the highest-leverage dial
/sge:improvement-sweep --dry-run  # select + report only; open nothing
```

## Relationship to #740

Issue #740 (OPEN) is the fleet single-pane **dashboard** that *displays* these
trends. This sweep *acts* on them. They are complementary — link, do not
duplicate.
