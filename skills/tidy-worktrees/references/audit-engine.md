# The audit engine (`audit.sh`)

Read-only and deterministic. It never deletes, pushes, commits, stashes, labels or opens anything. The delete commands it prints are a plan for the main session to put in front of the user.

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/tidy-worktrees/audit.sh" [--summary] [--json-out <file>] [--fetch] [repo dirs…]
```

`--fetch` runs `git fetch --prune origin` first (Phase 0; it only moves remote-tracking refs). Needs `bash`, `git`, `jq`, `timeout`. Output is a JSON array with one report per repo (`--summary` prints counts and the items that need a decision).

## Report fields

| Field | Meaning |
|---|---|
| `refused` / `open_pr_set_known` | `true` / `false` when `hpr_open_pr_heads` failed: every item is C and `delete_plan` is `null` |
| `counts`, `counts_by_kind` | A/B/C/D totals, overall and per kind (`worktree`, `branch`, `stash`, `remote-branch`) |
| `items[]` | `kind`, `name`, `path`, `tip`, `bucket`, `sub_verdict`, `reason`, `pr_state` (`merged`/`closed`/`open`/`none`), `pr_number`, `ahead`, `behind` (vs `origin/<default>`), `age_days`, `last_author`, `supersession`, `dirty`, `unpushed`, `owner`, `commands`, `needs_junction_guard` |
| `delete_plan` | `merged_A` and `discard_D`, each with `local` (worktrees, then branches) and `remote` lists of `{item, tip, pr_state, commands}` |

## Classification (first match wins; any failure is C keep)

1. Protected name (`SGE_AUDIT_PROTECTED_REGEX`, default main/master/develop/trunk/gh-pages/release/*/hotfix/*), unsafe branch name, tip committed within `SGE_WT_RECENCY_GUARD_MIN`, Git lock, live claim, current worktree, detached HEAD, dirty tree, attributed stash: **C**.
2. PR lookup failed, base unresolved: **C** (`KEEP:pr-lookup-failed` / `KEEP:base-unresolved`).
3. Open PR: **C** `KEEP:open-pr`.
4. Tip reachable from the base: **A** (`git branch -d` is safe).
5. Merged PR whose recorded head equals the tip (squash): **A** (`git branch -D`, tip SHA recorded in the plan).
6. Supersession: no surviving commits by patch-id, or an empty tree diff vs base: **D**. Net work: **B**, with sub-verdict `LIVE-UNMERGED`, `POST-MERGE-COMMITS` (merged PR, tip moved on) or `CLOSED-PR-UNMERGED`. Unanswerable: **C**.
7. A remote branch whose same-named local branch is not A or D stays **C** (`KEEP:local-copy-unresolved`).

Stashes are always C `NEEDS-DECISION:STASH` and never carry commands. The branch checked out in the main checkout is listed as C `KEEP:main-checkout`.

## Host routing

GitHub: one bulk `gh pr list --state all` (cap `SGE_AUDIT_PR_LIMIT`, default 2000). Records found in a truncated list are used; absence from a truncated list is a lookup failure (keep). Azure DevOps: `hpr_completed_pr_heads <branch>` per branch (needs `SGE_AZDO_TOKEN`). Forgejo/Gitea: only the open set exists, so a branch reaches A or D only on git evidence. Unknown host: everything is C.

## Commands are literal

Every command quotes the branch or path with `@sh` and is emitted only for names matching `^[A-Za-z0-9._/@+-]+$`. Run them verbatim, one per branch; do not wrap them in a loop over a variable (the sge git-policy-guard blocks variable-driven `git push origin --delete`). Before each remote delete, re-check the tip: `git ls-remote origin refs/heads/<branch>` must still equal the recorded tip.
