# The executor (`execute.sh`)

Runs an approved delete plan from `audit.sh` JSON. It is a script, so every host gets the same safe steps: Claude Code, GitHub Copilot CLI or VS Code agent mode, with or without subagents. It works the same on GitHub and Azure DevOps: deletions are plain `git`, and its only host call is a read-only open-PR lookup before remote deletion (`hpr_open_pr_heads`, which on Azure DevOps needs `SGE_AZDO_TOKEN`). On Windows, run it from Git Bash, which ships with Git for Windows (`bash` on PATH).

```bash
S="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/tidy-worktrees"
bash "$S/execute.sh" --audit audit.json --select all --dry-run      # preview: re-checks, changes nothing
bash "$S/execute.sh" --audit audit.json --select all                # local A and D items
bash "$S/execute.sh" --audit audit.json --remote \
  --select 'remote-branch:feat/x@<40-hex tip>'                      # remote, literal per branch
```

| Option | Meaning |
|---|---|
| `--audit <file>` | `audit.sh --json-out` output (repeatable, any number of repos) |
| `--select all` | every local (worktree, branch) A/D item with plan commands. **Never** a remote branch |
| `--select <token>` / `--select-file <file>` | literal `<kind>:<name>@<tip>` or `<worktree-path>@<tip>`, one per approved item; the tip must equal the audited one. Prefix `<repo>::` (the audit's `repo` field) to bind it to one repo; an unqualified token that matches in two repos is refused |
| `--buckets A` / `--buckets B` | only merged items (default `A,D`); `B` allows an approved discard of an unmerged item, by literal token only |
| `--remote` | allow `remote-branch:` tokens; without it they are ignored |
| `--recovery <csv>` | recovery file (default `./tidy-recovery-<timestamp>.csv`); never overwritten |
| `--dry-run` | run every re-check and print `WOULD`, touch nothing |

## What it guarantees

1. **Recovery CSV first.** It records repo, kind, name, path, full tip SHA, bucket, reason and a restore command that recreates the branch (local or remote) at its recorded tip, before anything changes. If the file exists or cannot be written, it stops with exit 4.
2. **Order.** It works one repo at a time: worktrees, then local branches, then remote branches.
3. **Re-check right before acting.** It checks that the tip is unchanged, the tracked tree is clean, the worktree is not git-locked, there is no `.sge-wt-claim` lease within its TTL (`roc_claim_state`; an expired lease is dropped first, an unreadable one counts as live; the drop and the removal run under the shared lease lock in `skills/worktrees/lease-lock.sh`, which every lease writer also takes, so a lease refreshed in between is never deleted, and a busy lock is `SKIP lease-lock-busy`), and the item is not the main or current checkout, the default branch or a protected name. Any failed check or failed lookup gives `SKIP <reason>`; it never deletes in that case.
4. **Link guard before every worktree removal.** On Windows, `junction-guard.ps1` walks the tree one level at a time. It never descends into a reparse point, and it removes each junction or directory symlink with a non-recursive delete, which cannot delete files, then verifies the link is gone. On POSIX it uses `find -type l` (which never follows links) and `rm` on each link. Links git tracks are left for git, which removes them as links. If the guard fails, the item is a SKIP. See [`windows-junction-guard.md`](windows-junction-guard.md) for why.
5. **No force.** Removal is `git -c core.longpaths=true worktree remove` without `--force`. If git refuses, the item is a SKIP. It then runs `git worktree prune` and `git branch -D` only on a tip it has confirmed again at that moment.
6. **Remote.** A remote branch is deleted only with `--remote` and a literal token. A fresh open-PR lookup, made for each branch, must not list it. A PR opened since the audit is a SKIP, and an unknown open-PR set skips the item. `git ls-remote origin` must still show the audited tip, and the branch is skipped (`local-copy-present`) while a same-named local branch still exists, so a local item skipped in this run or an earlier one keeps its remote copy. The delete carries a lease on the audited tip, so it is a compare-and-delete: a push that lands in between is never deleted.
7. **Never.** It never overwrites a ref, pushes code, touches labels or PR state, unlocks a worktree (use `lock-audit.sh apply`), or deletes in a repo whose audit was `refused`. The recovery CSV is created exclusively, so it never overwrites an existing file.

Output is one tab-separated line per item: `DONE|SKIP|GONE|WOULD  repo  kind  name  tip12  reason  detail`. It ends with `SUMMARY: done= skipped= gone= would=`. Show the table to the user. A SKIP is the safe outcome: re-audit and decide again; never retry with force.

## Read-only assessor (`assess.sh`)

`bash "$S/assess.sh" <repo-dir> <ref>` prints the git half of the [assessor brief](assessor-brief.md): tip, supersession, ahead, commits, net diff versus the merge base, changed test files, `#N` issue references and uncommitted file names. The session then checks the linked issue on the host (`gh issue view`, or the work item on Azure DevOps) and records the recommendation.
