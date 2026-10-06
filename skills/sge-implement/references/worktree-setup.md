# sge-implement — Phase 3 Step 1: worktree setup

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Place the worktree per the shared [`worktrees`](../../worktrees/SKILL.md) convention (sibling `../<repo>-worktrees/issue-<N>`). **Resume before create** (#1171): run `resume-or-create.sh decide` first. Fallback:

```bash
git fetch origin
WT="$(git rev-parse --show-toplevel)/../$(basename "$(git rev-parse --show-toplevel)")-worktrees/issue-<N>"
git worktree add -b <branch> "$WT" origin/main
cd "$WT"
```

Branch name: spec lane → `feat/sge-<NNN>-<short-desc>`; no-spec lane → the 0B taxonomy (`feature/` `fix/` `chore/`).
