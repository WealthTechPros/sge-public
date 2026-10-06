# Layouts the sweep spans (Phase 1)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

**Layouts the sweep spans (per the shared [`worktrees`](../../worktrees/SKILL.md) convention).** `git worktree list --porcelain` enumerates worktrees regardless of where they sit, so this audit is layout-agnostic by construction — it covers both the canonical sibling `../<repo>-worktrees/<purpose>-<id>` layout and any surviving deprecated stray layouts (`../worktrees/…`, `${REPO_ROOT}-qa-N`). Two placements need explicit acknowledgement:

- **In-repo `.worktrees/issue-N` (the sanctioned team-pipeline exception).** These are lifecycle-managed by `/sge:team-pipeline` (its Phase 0.5 flush and lane teardown are keyed on that prefix). Treat an `.worktrees/issue-N` worktree exactly like any other row — safety-audit it, keep it if its branch has an open/in-flight PR — but be aware a running pipeline owns it; when in doubt, prefer leaving live pipeline claims for the pipeline to reap. It is ignored by the target repo's gitignore, so it will not appear in that repo's `git status`.
- **Deprecated stray layouts** (`${REPO_ROOT}-qa-N` etc.) look like sibling clones, not `<repo>-worktrees` children — `git worktree list` still surfaces them, so they are swept normally; do not skip a stale worktree merely because its path predates the canonical convention.
