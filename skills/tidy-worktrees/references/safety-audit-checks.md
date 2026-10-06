# Phase 2 safety-audit checks

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

**Recency guard (issue #1759).** When no `.sge-wt-claim` is present (the worker died before writing one, or the worktree was created outside the claim-aware path), fall back to directory age: if the worktree directory's **mtime** is within `SGE_WT_RECENCY_GUARD_MIN` (default 10 minutes), presume it is live and classify 🟩 **KEEP (recently created)**. Check mtime portably:

```bash
# macOS
wt_mtime=$(stat -f '%m' "$wt" 2>/dev/null)
# Linux
[ -z "$wt_mtime" ] && wt_mtime=$(stat -c '%Y' "$wt" 2>/dev/null)
now=$(date +%s)
age_min=$(( (now - wt_mtime) / 60 ))
if [ "$age_min" -lt "${SGE_WT_RECENCY_GUARD_MIN:-10}" ]; then
  # KEEP (recently created) — do not add to the deletion plan
fi
```

The recency guard is a secondary net; the claim file is the real fix. A worktree that is both old (past recency) and claim-free is audited under normal rules.

**Stash attribution — `git stash list` is repo-global.** All worktrees share one stash list, so "stash list non-empty" would let a single stash block every removal in the repo. Instead, attribute each stash to a branch via its subject line (`WIP on <branch>: …` / `On <branch>: …`) and only mark *that* branch/worktree VALUABLE. Stashes that match no candidate branch (or were made on `main`) are **a note in the final summary, never a removal blocker**.

**Squash-merge cross-check — `git log origin/main..<branch>` lies after a squash merge.** The squashed commit on `main` has a different SHA, so the branch shows phantom "ahead" commits forever. Before classifying a branch VALUABLE on ahead-count alone, cross-check GitHub:

```bash
gh pr list --state merged --head "$b" --json number,mergedAt,headRefOid
# or: gh pr view "$b" --json state,headRefOid
```

On a non-GitHub host (`fpr_host_kind` ≠ `github`: Forgejo/Gitea or Azure DevOps) there is no merged-PR lookup yet, so skip this cross-check: the branch stays 🟥 VALUABLE on ahead-count (fail safe — never SAFE on an unverified merge).

If a merged PR exists for the branch **and** the branch tip equals the PR's `headRefOid` (no commits added after the merge) **and** the working tree is clean → ⬜ SAFE (squash-merged). If the tip has moved past the merged PR's head, the extra commits are 🟥 VALUABLE.

Other useful checks (per worktree `$wt` / branch `$b`):

```bash
git -C "$wt" status --porcelain                                          # empty = clean
git rev-list --left-right --count "$b@{upstream}...$b" 2>/dev/null || echo "NO-UPSTREAM"
git log --oneline origin/main.."$b"                                      # candidate unmerged work
```
