# team-pipeline — pre-flight

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

> **Target repo.** When dispatched from outside the target repo's checkout (a
> hub/control session), apply [`gh-repo`](../../gh-repo/SKILL.md): `cd` into the
> target checkout and run its startup echo (raw `git`/worktree paths resolve from
> cwd; `GH_REPO` alone is not enough).

Run `git branch` (on main/base), `git status` (clean), `gh auth status`
(authenticated — but in a Claude Code Routine sandbox the GitHub proxy injects
auth and `GH_TOKEN`/`GITHUB_TOKEN` is the placeholder `proxy-injected`, so treat
that as authenticated and skip the hard-exit; see
[docs/routines-environment.md](../../../docs/routines-environment.md)); resolve
`WORKSPACE_ROOT`, `WORKTREE_BASE` (`$WORKSPACE_ROOT/.worktrees` — the pipeline's
sanctioned exception), and `SIBLING_BASE` (canonical `../<repo>-worktrees/`).
Commands: [mechanisms](mechanisms.md).
