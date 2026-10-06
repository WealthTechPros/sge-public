# team-pipeline — Phase 0.5 flush unpushed worktrees

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Before issue discovery, scan existing worktrees for commits never pushed; push
them and create draft PRs so those issues become visible to CI and reviewers and
the `agent-lock` label releases. Pass `--skip-flush` to bypass when worktrees are
known clean. Scan **both** layouts — the in-repo `$WORKTREE_BASE/issue-*`
exception **and** the canonical sibling `$SIBLING_BASE/*` (scanning only
`.worktrees/issue-*` let stray-path worktrees escape — epic #730).

**Reconcile before pushing (MANDATORY — issue #856):** never flush landed work. A
candidate is flushed only if **both** gates pass — (1) **Novelty:**
`git cherry origin/main` shows patches not already on main (robust to
single-commit squash); (2) **Open-issue:** the linked issue is still **open** (a
closed issue's branch is presumed landed — catches the multi-commit squash
false-positive gate 1 misses). Anything failing either is **a `/sge:tidy-worktrees`
candidate, never pushed**. The bundled, regression-tested `assets/reconcile-flush.sh`
(#729) applies both gates across both layouts and emits JSON (`candidates[]` with
`decision` `"flush"`/`"tidy"` + reason). **Push + draft-PR only `flush`
candidates**; hand `tidy` off. Bash: [mechanisms](mechanisms.md).
