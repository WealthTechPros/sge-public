# Worktree lifecycle: recovery, restore and limits

Operator guide for the worktree-work preservation lifecycle (SPEC-139, epic
#3216). The lifecycle is **best-effort preservation plus an audit with a human
confirmation gate**. It is not a backup product and not a guarantee against
disk failure.

## The four pieces

| Piece | What it does | What it never does |
|---|---|---|
| Registry and audit (`skills/lib/worktree-lifecycle.sh`) | Records which session owns which linked worktree; classifies each as KEEP, VALUABLE or `candidate`. | Delete anything. `candidate` only means "may be offered in a plan". |
| Checkpoint store (`skills/worktrees/checkpoint.sh`) | Copies uncommitted work to a per-user store outside the checkout and writes a recovery ref. | Change the branch, index or working files. Describe a partial capture as complete. |
| Hooks (`hooks/copilot/worktree-lifecycle.sh`) | Register, checkpoint at turn end, save a handoff at session end. | Delete, stash, reset, commit, push or open a PR. |
| Tidy and inbox (`/sge:tidy-worktrees`, `skills/tidy-worktrees/inbox.sh`) | Fetch fresh remote state, audit, show the inbox, build one deletion plan. | Delete without you confirming the exact plan. |

## Full audit: `audit.sh`

`bash skills/tidy-worktrees/audit.sh [--summary] [--json-out f] [repo dirs]` is the
read-only engine behind `/sge:tidy-worktrees`. It covers local worktrees, branches,
stashes **and** `origin/*` branches, sorts each into A merged / B unmerged and
valuable / C part-complete or kept / D superseded or empty, and prints the delete
plan as literal per-branch commands (see
[the engine reference](../skills/tidy-worktrees/references/audit-engine.md)).
Any lookup failure keeps the item. It deletes nothing.

## What is open? The inbox

```bash
bash skills/tidy-worktrees/inbox.sh                       # this repo
bash skills/tidy-worktrees/inbox.sh ../repoA ../repoB     # several repos
SGE_INBOX_REPOS=/work/a:/work/b bash skills/tidy-worktrees/inbox.sh
bash skills/tidy-worktrees/inbox.sh --json [--json-out inbox.json] ...
```

It reads each repo's linked worktrees (including the sibling `<repo>-worktrees/`
dirs outside the repo) and its local branches, and prints one suggested action
per item with the reason, tip SHA, dirty state, unpushed count, PR state, age
and registry owner. It is read-only. `/sge:tidy-worktrees --inbox` runs it.

| Action | Meaning | What you do next |
|---|---|---|
| `continue` | Live claim, recently created, current session or an open PR. | Nothing. |
| `open-a-pr` | The branch has net work not in main (`rescue-guard.sh supersession` says `live`). | Confirm the linked issue is still open, then tidy offers it in one capped multi-select of draft PRs (never auto-merged). |
| `delete` | Clean and superseded by main. | Appears in the tidy deletion plan with its tip SHA; you confirm the plan. |
| `checkpoint-then-decide` | Uncommitted work. | Run `checkpoint.sh checkpoint`, then decide per item. |
| `keep` | Audit uncertain (open-PR lookup failed, base unresolvable, attributed stash, default branch...). | Read the reason. Fix the cause and re-run. |

An unreadable or incomplete open-PR set never produces `delete` or `open-a-pr`.

## Recovery

List what exists, newest first:

```bash
bash skills/worktrees/checkpoint.sh list <path-in-repo>
```

The output names completed checkpoints and any `interrupted:` leftovers (a run
that died before its manifest was renamed into place; never advertised as
complete). Recovery refs live under `refs/sge/checkpoints/<id>` in the repo's
common git dir and keep the committed objects alive through `git gc`.

## Restore

Restore always goes to an **isolated, empty destination**, never over a
worktree:

```bash
bash skills/worktrees/checkpoint.sh restore <path-in-repo> <id> <dest>
```

A checkpoint marked partial is refused unless you pass `--allow-partial`
(exit 9). The restore reproduces the captured commit plus the staged and
unstaged patches and the permitted untracked files. Review the result before
copying anything back by hand.

## Limits (stated plainly)

- **Partial coverage is normal.** Ignored files, secret-pattern files,
  symlinks, nested repos, submodules and unreadable paths are not copied.
  Such a checkpoint exits 10 and carries `retain-worktree:yes` and
  `safe-to-remove:no`. Treat the worktree as the only copy of those files.
- **Stashes are not checkpointed.** An attributed stash makes the inbox say
  `keep`; the stash stays where git keeps it.
- **No at-rest crypto.** The store is owner-only and outside synchronised
  folders. Disk encryption (for example BitLocker) is the at-rest control.
- **Retention is manual.** Recovery data is never purged because a session
  ended or a checkpoint is old. `prune --yes` is a manual command.
- **Forced termination fires no hook.** The next session start reports the
  session as interrupted from its stale heartbeat. Nothing is deleted
  automatically in that case or any other.
- **Heuristics.** Liveness is a heartbeat; recency is directory mtime;
  supersession compares patch-ids and trees against `origin/main`. Each errs
  towards keeping.
- **Copilot CLI first.** Observed behaviour for startup, resume, normal exit,
  timeout and forced termination is in `docs/copilot-cli-install.md`.
  Interactive exit and `/clear` were not observed.
- **Needs `jq`, `git` and network.** The open-PR lookup needs `gh` auth (or the
  Forgejo or Azure DevOps adapter). Offline runs produce `keep`, not `delete`.

## The confirmation gate

Cleanup keeps the order **worktrees, then local branches, then separately
authorised remote branches**. On Windows the junction guard
(`skills/tidy-worktrees/references/windows-junction-guard.md`) runs before every
`git worktree remove`, so a junction target is never deleted. Default mode
first shows one consolidated plan of clean, exact merged-PR worktrees and
local branches, with PR links and tip SHAs: remove all listed, choose a subset,
or keep everything. It then assesses remaining unprotected work item by item,
recommending checkpoint locally, resume/rescue for review, keep or explicit
discard from actual changes and completion evidence. Unknown value means
keep; protected work, including ownership locks, is never offered for discard.

Nothing is removed without confirming the exact plan. Revalidate each item
immediately before removal; remote branches require separate, explicit
approval. `--force` retains its single audited-plan confirmation and never
authorises rescue. Recovery refs and checkpoint data are never part of a
deletion plan. See the skill's
[two-stage decision flow](../skills/tidy-worktrees/references/consolidation-intent.md#default-decisions-merged-cleanup-then-unfinished-work)
for eligibility, scope conflicts and per-item choices.

## Cleanup is not integration

Tidy does not automatically commit, push or merge everything marked NEEDS-DECISION
(the registry lib still says VALUABLE). That verdict means work needs a
preservation decision, not that it is ready for main. Rescue is a single capped
multi-select of draft PRs, each item individually verified as not already in
main with its issue still open (maintainer decision, 2026-11-07, relaxing #2866's one question
per branch); a commit, remote copy or draft PR is not a merge.
For "consolidate useful changes into main, then clean up", first review the net
changes and take approved candidates through the repository's normal tests,
review and merge gates. Re-audit afterwards, then confirm the deletion plan.
Keep uncertain work and report anything still awaiting review or merge.
