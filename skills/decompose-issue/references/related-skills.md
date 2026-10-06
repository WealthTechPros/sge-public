# decompose-issue — related skills

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

- `/sge:sge-implement <n>` — Build an SGE spec issue (or a child) end-to-end; owns the canonical complexity rubric this skill reuses
- `/sge:sge-implement <n>` — Build a child issue (spec or general) once it is unblocked
- `/sge:team-pipeline` — Fan the parallel-safe children out across multiple concurrent implementation agents
- `/sge:deep-dive <n>` — Investigate an unclear issue before deciding whether it even needs a split
- `/sge:tdd-workflow` — The Red/Green/Refactor inner loop each story child runs
- [`gh-repo`](../../gh-repo/SKILL.md) — the shared cross-repo / hub-dispatch repo-targeting convention the child-issue `gh` writes follow
- [`worktrees`](../../worktrees/SKILL.md) — the canonical worktree placement the parallel-safe children run in
- [`scripts/validate-file-map.sh`](../../../scripts/validate-file-map.sh) — the mechanical Phase 3d validator that classifies each `owns` path against `git ls-files` (existing / new / phantom) so no phantom path reaches a lane (#1271)
