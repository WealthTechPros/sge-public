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

On **Azure DevOps** (`fpr_host_kind` = `azdo`) use the completed-PR lookup instead (issue #3027; needs `SGE_AZDO_TOKEN`, the same read-only Code PAT as the open-PR list):

```bash
source "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/lib/forgejo-pr-read.sh"
# "<number><TAB><recorded-source-head-sha><TAB><completion-time>" per status=completed PR
if COMPLETED="$(fpr_completed_pr_heads "$b")"; then
  tip="$(git rev-parse "refs/heads/$b")"
  printf '%s
' "$COMPLETED" | cut -f2 | grep -qx "$tip" && echo "completed-PR head == tip"
fi
```

A branch is ⬜ SAFE only when a **completed** PR exists, its recorded source head (`lastMergeSourceCommit`) equals the local branch tip, **and** the tree is clean. Everything else stays 🟥 VALUABLE: a tip that moved past the completed head, an abandoned or active PR (only `status=completed` counts; completion is never inferred from mergeability or a merge commit), no completed PR, a missing token or disallowed host, an API/auth error, malformed JSON, or a page-cap hit (possible truncation). `fpr_completed_pr_heads` exits non-zero on every uncertainty; an empty list with exit 0 is a confirmed zero and also leaves the branch VALUABLE. Never print or log the token.

On any other non-GitHub host (Forgejo/Gitea) there is no merged-PR lookup yet, so skip this cross-check: the branch stays 🟥 VALUABLE on ahead-count (fail safe — never SAFE on an unverified merge).

If a merged PR exists for the branch **and** the branch tip equals the PR's `headRefOid` (on Azure DevOps, the completed PR's `lastMergeSourceCommit`) (no commits added after the merge) **and** the working tree is clean → ⬜ SAFE (squash-merged). If the tip has moved past the merged PR's head, the extra commits are 🟥 VALUABLE.

Other useful checks (per worktree `$wt` / branch `$b`):

```bash
git -C "$wt" status --porcelain                                          # empty = clean
git rev-list --left-right --count "$b@{upstream}...$b" 2>/dev/null || echo "NO-UPSTREAM"
git log --oneline origin/main.."$b"                                      # candidate unmerged work
```
