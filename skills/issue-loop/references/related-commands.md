# issue-loop — related commands

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

- [`loops/SKILL.md`](../../loops/SKILL.md) — the anatomy gate and loop patterns this skill declares against
- `/sge:available-issues` — the pick step (`--mode autonomous-next` is this loop's queue)
- `scripts/reconcile-worklist.mjs`, `/sge:build-ready-audit`, `/sge:decompose-issue` — the pre-dispatch filters
- `/sge:sge-implement` — the full per-issue pipeline this loop dispatches
- `/sge:pr-review` — the independent merge gate (confirmed by the driver, owned by the pipeline)
- `/sge:pr-monitor`, `/sge:pr-fix` — PR shepherding for `--no-merge-wait` and recovery paths
- `/sge:env-health` — the preflight Governor gate before every dispatch
- `/sge:team-pipeline --duration` — the duration-bounded **parallel** sibling; use it for time-boxed fan-out, this loop for a serial drain to empty
