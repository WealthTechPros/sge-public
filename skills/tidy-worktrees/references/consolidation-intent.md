# Cleanup and consolidation are different outcomes

Read this before acting on "commit/push all valuable work", "consolidate into
main", or "delete the rest". Existing Phase 3 approvals and rescue guards
still apply; these phrases do not waive them.

| User request | Required interpretation |
|---|---|
| "Tidy worktrees" | Audit everything in scope; confirm clean merged cleanup together, then recommend and decide remaining work per item under the [two-stage flow](#default-decisions-merged-cleanup-then-unfinished-work). Preserve protected work; do not silently commit, push or merge. |
| "Preserve the owning-repository workflow" / "retain worktrees" | Distinguish the workflow from blanket retention. If explicit retention conflicts with cleanup, show read-only candidates and clarify the protected scope; keep affected items meanwhile. Scope clarification is not deletion approval. |
| "Commit and push all valuable work" | First show each candidate's net changes versus current main, validation state and recommendation. Offer the single capped draft-PR multi-select (below) for items individually verified `live` with an open linked issue; everything else is a per-item choice. Never an unverified bulk push. |
| "Consolidate valuable changes into main, delete the rest" | Treat integration and deletion as separate gated tasks. Identify useful, non-superseded changes and their owning PRs first; follow the repository's normal implementation, testing, review and merge requirements for approved candidates. Then refresh the audit and confirm the exact cleanup plan. |
| `--force` | Confirm one audited deletion plan. No commits, pushes, PR creation or merges are implied. |
| `--inbox` | Read-only suggestions, not completed rescue, integration or cleanup. |

NEEDS-DECISION (the retired VALUABLE verdict) means potentially unrecoverable
work that needs a decision, not reviewed, correct or ready to merge. A stale branch is not necessarily
worthless; a pushed branch is not necessarily integrated. Unknown value or
uncertain supersession means **keep**, not delete.

For consolidation requests, keep a per-item disposition: **already in main,
rescue proposed, awaiting review/merge, keep, or explicit discard**. Include
the owning PR where one exists. Do not create a duplicate rescue PR.

Do not cherry-pick everything onto main, bypass review/branch protection,
enable auto-merge, or discard work because it is unmerged. A commit preserves
local history; a push adds a remote copy; a draft PR requests review; only a
verified merge establishes integration. A failed gate leaves the candidate
kept with a concrete blocker; it does not justify discarding the work.

After integration, refresh remote and PR state and re-check live ownership
claims before proposing removal. Confirm the exact deletion plan separately.
Report rescued work as committed, pushed, PR opened or verified merged; never
describe those stages as interchangeable. List every candidate not yet
integrated or explicitly discarded, including anything awaiting a decision.
Do not call consolidation complete just because cleanup finished.

## Default decisions: merged cleanup, then unfinished work

Complete Phases 0-2 for every item before proposing any deletion. These two
stages change the interaction, not the safety audit, rescue guards or Phase 4
removal order. `--inbox` stays read-only; `--force` keeps its own single-plan
confirmation and never authorises rescue or integration.

### Resolve retention scope before proposing removal

Preserving the owning-repository workflow is not the same as preserving every
existing worktree. Audit and show the read-only candidates rather than
silently assigning blanket KEEP because branches are attached to worktrees.

If an explicit instruction to retain worktrees conflicts with cleanup, ask
which named scope it protects before proposing removal. Do not override that
instruction. Pending clarification, retain the affected items and report
"retained by instruction; removal eligibility not established", not "nothing
stale" or "all worktrees are needed". A scope clarification is not deletion
approval or a directory/tool permission grant.

### 3a: One confirmation for proven merged cleanup

Include only items whose fresh audit establishes all of the following:

- The host's complete open-PR set is known, and the branch has no open PR.
- A live host lookup confirms a PR merged into the intended base, with its
  recorded source head equal to the current local tip. Closed/abandoned alone,
  fully pushed alone, or a tip advanced after merge does not qualify.
- The worktree is clean and no stash is attributed to the branch. A clean
  status alone does not establish that ignored or unreadable files are
  disposable; retain when preservation coverage is unknown.
- Current/default worktrees and branches, live claims, Git ownership locks,
  the recency guard and KEEP/VALUABLE/uncertain lifecycle audits are excluded.
  An expired lease does not release a Git lock.

Show one row per worktree/local branch: path, branch, kind, merged PR link,
reason and full tip SHA. A branch without a worktree still gets its own row
and stash/PR/protection checks; no associated worktree is not proof of safety.
List excluded items and their reasons separately.

Ask: **"Remove all listed merged worktrees and local branches, choose a
subset, or keep everything?"** No response or a declined confirmation means
keep. Remote branches require separate, explicit approval identifying each
remote ref and tip; local-cleanup approval does not cover them.

Execute only the confirmed subset through Phase 4. Immediately before each
removal, refresh the required PR evidence and recheck tip, working files,
stashes, claims, locks, recency and applicable lifecycle audit. If anything
changed or is unknown, stop that item's removal and re-audit; do not
silently expand or force the plan. Apply the Windows junction guard and keep
the order worktrees, local branches, then separately approved remote branches.

### 3b: An informed choice for every remaining item

Report protected items as KEEP with their reasons; do not offer to discard
them. For each remaining unprotected worktree/branch and unresolved group of
uncommitted files, inspect its actual commits, staged/unstaged changes and
permitted untracked-file metadata, compare against the current base, and
check related live PRs and available acceptance evidence. Do not expose
secrets or include unrelated files in a rescue.

Show a concise assessment before asking:

| Item | Work remaining / equivalent work in base | Value and completion | Evidence / uncertainty | Recommendation |
|---|---|---|---|---|
| Named path/branch or file group, with tip SHA | Actual net changes, not just age or ahead count | Useful, partially complete, superseded or unknown | Source/PR/test/criterion; distinguish observed, inferred or unknown | One disposition and why |

Use "partially complete" only when evidence identifies both delivered work
and a concrete gap. Passing tests alone do not prove all requirements;
missing acceptance evidence means completion is unknown. A merged branch
with later commits or uncommitted files still needs this assessment. Unknown
value means keep, not a recommendation to discard.

Ask one question per item (batched 4 per `AskUserQuestion` call, or as a
numbered list on hosts without it) with the applicable choices:

1. **Checkpoint locally** - run the existing checkpoint tool without changing
   the branch, index or files. Report coverage; exit 10/partial keeps the
   original. A checkpoint never authorises deletion or a commit.
2. **Resume / rescue for review** - obtain the bounded continuation scope.
   **Push + draft PR** is offered only through the capped multi-select
   ([below](#draft-pr-multi-select-2026-11-07-relaxes-2866)), after live
   supersession and an open linked issue are verified item by item, then apply
   the existing rescued-worktree guards before pushing. No unverified bulk
   rescue PRs, automatic merge or automatic integration.
3. **Keep** - leave the item untouched. Default here when evidence or a
   decision is missing; a declined merged-cleanup batch is not a discard.
4. **Discard** - an explicit per-item decision followed by an exact Phase 4
   plan/confirmation. Record branch and attributed-stash recovery SHAs first.
   Name any uncommitted files being lost: a commit SHA cannot recover them.

Do not silently group different worktrees into one rescue decision outside the
capped multi-select below. Report
kept items, partial checkpoints, proposed continuations, confirmed removals
and outstanding decisions separately; neither a PR nor a checkpoint is proof
that unfinished work was integrated or is safe to remove.

### Draft-PR multi-select (2026-11-07, relaxes #2866)

#2866 required one question per branch after a cleanup session opened 8 PRs
that all duplicated work already on main. The lesson is
**verify each branch against main before it can become a PR**, not "ask many
times". The maintainer approved replacing the per-branch question with a single
multi-select, "open draft PRs for these N", under these conditions:

- Each listed item individually passes `rescue-guard.sh supersession` = `live`
  (a fresh check this run) **and** its linked issue is still open. Superseded,
  unknown, closed-issue or issue-less items never appear in the list.
- **Draft PRs only**, at most `SGE_TIDY_MAX_DRAFT_PRS` (default 10) per run.
  The rest wait for the next run.
- Never auto-merge, never arm auto-merge, never `--force` or force-push, never
  label changes. The rescued-worktree guard (`assess` then `verify`) still
  runs before each push.
- `--force` still never pushes or opens a PR.
- Selection authorises opening the draft only; integration still needs the
  repository's normal review and merge gates.
