# team-pipeline — related commands

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

- `/sge:issue-loop` (serial, full `/sge:sge-implement`)
- `/sge:available-issues`, `/sge:build-ready-audit`, `/sge:decompose-issue` — discover/gate/decompose
- `/sge:tidy-worktrees` — Phase 0.5 non-flush hand-off (never pushed)
- `/sge:sge-implement [N]` — single issue end-to-end (blocked-fix path)
- `/sge:governance-trace [N]` — pre-build gate; verdict adopted from the intake record when it has one
- `/sge:pr-monitor`, `/sge:pr-review [PR]`, `/sge:pr-fix [PR]` — shepherd/review/drive green
- `/sge:reap-orphans` (`--heavy` for the dev-box reset) — `/loop 30m` hygiene
