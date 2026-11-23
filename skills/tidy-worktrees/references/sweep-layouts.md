# Layouts the sweep spans (Phase 1)

Layout detail extracted from `SKILL.md` (issue #2917, 24 KB size budget).

**Layouts the sweep spans (per the shared [`worktrees`](../../worktrees/SKILL.md) convention).** `git worktree list --porcelain` enumerates worktrees regardless of where they sit, so this audit is layout-agnostic by construction — it covers both the canonical sibling `../<repo>-worktrees/<purpose>-<id>` layout and any surviving deprecated stray layouts (`../worktrees/…`, `${REPO_ROOT}-qa-N`). Two placements need explicit acknowledgement:

- **In-repo `.worktrees/issue-N` (the sanctioned team-pipeline exception).** These are lifecycle-managed by `/sge:team-pipeline` (its Phase 0.5 flush and lane teardown are keyed on that prefix). Treat an `.worktrees/issue-N` worktree exactly like any other row — safety-audit it, keep it if its branch has an open/in-flight PR — but be aware a running pipeline owns it; when in doubt, prefer leaving live pipeline claims for the pipeline to reap. It is ignored by the target repo's gitignore, so it will not appear in that repo's `git status`.
- **Deprecated stray layouts** (`${REPO_ROOT}-qa-N` etc.) look like sibling clones, not `<repo>-worktrees` children — `git worktree list` still surfaces them, so they are swept normally; do not skip a stale worktree merely because its path predates the canonical convention.

## Scope and continuing execution ledger

The default invocation covers only the current repo; named directories cover
only those targets. A hub checkout is navigation, not consent to scan a machine.
For an explicit all-local/hub request, discover the supplied or already-known
roots once from the existing inventory and native Git registries. Do not crawl
unknown directories or silently widen the root set. Record unavailable roots as
unknown, not empty.

Resolve each checkout's absolute Git common directory with
`git rev-parse --path-format=absolute --git-common-dir` and deduplicate linked
checkouts by that identity, retaining their individual paths and current-checkout
protections. Separate clones are not linked worktrees: keep distinct common
directories even when the remote URL matches. Resolve `git remote get-url origin`
and the real host through [`host-pr-read.sh`](../../lib/host-pr-read.sh), never
through a folder name or client brand. GitHub and Azure DevOps both use fresh
native PR evidence; failed, unknown or truncated lookups mean keep.

Keep **one continuing execution ledger** in the existing task/session record,
outside versioned source and synchronised deliverable folders. Link it in the
handoff so the next invocation can resume without the prior conversation.
Record metadata, not file bodies, credentials or customer data:

- Scope, known roots, discovery source and timestamp; resolved common directories,
  checkout paths, actual remotes/hosts and unavailable evidence.
- Ordered repository/target queue; selected repo's audit source/time and artifact
  location; full base and target tip SHAs, bucket, disposition and named gap.
- File/stash/ignored-file coverage, ownership/claim/lock evidence and freshness;
  exact approval scope and approved `path@tip` or executor tokens.
- Checkpoint/recovery records and their complete/partial coverage, retained
  originals, executor results, outstanding decisions and **next target**.

Discover the root set once, then inventory each queued repo when selected.
Finish each selected worktree's outcome (including keep with a named gap) and
advance the ledger before moving to the next. Do not re-audit completed repos
just because a question, phase or invocation ended. If interrupted, resume the
next target and carry outstanding approvals forward only when their exact scope
and evidence are unchanged. Never call a deferred or unknown target completed.

**Freshness is not cached approval.** Immediately before any mutation, refresh
the selected repo's fetch/base and live open-PR set, then the selected target's
full tip, files, stashes, claims, locks, recency, merged-head/supersession and
applicable issue evidence. Keep executor revalidation and all existing guards.
If anything changed, invalidate that target's disposition/approval and re-audit
the smallest affected scope; keep unrelated ledger entries:

| Invalidation | Scope to refresh |
|---|---|
| Target tip, files, stash, claim, lock, writer or PR state changed | Selected target and any linked branch/worktree disposition |
| Base tip or host/auth/open-PR evidence changed or failed | Affected repo's dependent classifications; failed evidence means keep |
| Roots, common-directory identity, remote routing or requested scope changed | Affected queue entries; broader discovery only for the named root/scope change |
| Ledger provenance is missing/unreadable, or user explicitly requests a new full audit | Explain the evidence gap or request, then rebuild that named scope |

Name the invalidation and affected scope **before a broad rescan**. Advancing to
the next target, returning from a collector, or restarting the client is not an
invalidation by itself. If an installed helper only supports a repo-wide audit,
say so and limit the rerun to the affected repo; do not invent a target cache.
The ledger is a manual procedure, **not an installed atomic queue, cache or
admission service**, and it never establishes exclusive ownership.

## Bounded read-only fanout

Use exposed capabilities, independently of GitHub, Azure DevOps or client name.
Do not delegate automatically or launch extra CLI processes to manufacture
missing tools. When explicitly requested or instructed, one coordinator may
dispatch **at most three disjoint read-only collectors**, normally one per
independent repo, by default. When the user explicitly requests scaled fleet
preparation, allow **at most five disjoint repository lanes**. This is a
procedure limit, not a new CLI flag or a settings change. Use fewer lanes when
the exposed tools, rate limits or independent work cannot support five.
Give each lane explicit targets, evidence questions, budgets and stops.
Within a repository, process worktrees serially; do not assign overlapping
worktree/branch/stash evidence to concurrent collectors. If work is one
continuous trace, or `Agent` is unavailable, inspect inline.

Collectors return cited metadata and advisory dispositions to the same ledger.
They never ask users, edit files, claim/unlock worktrees, stage, push, open PRs
or delete. The coordinator reconciles once into **one confirmed executor plan**
and is the only writer, using the existing [`execute.sh`](../execute.sh)
contract. No simultaneous writers or interleaved destructive steps across
repositories; no follow-on batch outside the explicitly authorised queue.

Unknown, dirty, open-PR, claimed or locked work stays untouched by collection
and ordinary cleanup. The existing explicit checkpoint/content decisions and
Phase 2b lock choices remain separate gates, not permission to take another
writer's claim. Fanout and ledger reuse never weaken secret scanning,
supersession, the linked-open-issue check, capped draft PRs, ignored-file consent
or the Windows junction guard. Missing approval means keep and report the next
action, not another full-fleet scan.

### Fleet batch execution plan

For an explicitly scaled all-local or age-bounded fleet request, make batching
the execution route, not a tooling project or a sequence of single-tree chats:

1. **Fix the scope once.** Record the requested cutoff and known common-directory
   identities. Separate present in-scope worktrees, today's/out-of-scope trees
   and unavailable registrations. A fresh count is metadata, not another source
   audit. Reconcile that count with the existing queue; do not re-import over
   completed decisions or infer that an unavailable path can be pruned.
2. **Separate unfinished review from held work.** First-review targets need the
   file-level content check. Previously assessed targets need only their named
   protection, ownership, preservation or changed-evidence gap reconciled.
   Keep recovery and open-PR work separate from ready cleanup; an old KEEP is
   neither permanent inactivity nor permission to discard useful work.
3. **Prepare disjoint packets.** Use up to five exposed read-only repository
   lanes, with one repository per lane at a time. Balance queues by remaining
   work while keeping each repository exclusive. Five trees per lane means at
   most 25 targets per round, not a promised completion or deletion rate.
   Retain the ten-minute cap, no nested delegation and partial-result rules.
   Reuse valid source assessments and the selected repository's captured host
   index; do not repeat the full audit when the next packet uses unchanged
   evidence. A helper without supported reuse keeps its documented limitation.
4. **Batch decisions, not authority.** Reconcile a round once into one exact
   ready-candidate plan and a grouped exception list. Ask once for that bounded
   plan with full recovery SHAs, paths and separately named ignored-file consent.
   Preserve individual Phase 2b lock choices, writer confirmations and publication
   scope. Reuse unchanged answered approvals; never request them again simply
   because a round ended, or extend them to a new path or changed file set.
5. **Keep one execution lane.** The coordinator alone runs the existing executor
   serially after fresh per-target revalidation, junction and collateral-prune
   checks. Pause collection in the repository being mutated. A changed or refused
   target stays put; unrelated approved targets can continue. No age-only unlock,
   claim deletion, force removal, remote deletion or automatic merge.
6. **Finish valuable work separately.** Prioritise unpreserved/local-only work,
   reuse the owned worktree and continuing task PR, reconcile newer main safeguards
   and complete the owning checks. Partial recovery keeps the original.
   Source activity or synthetic-only tests do not replace required runtime proof.
   Publication and merge retain their own exact approval and acceptance gates.

For an authorised multi-round queue, record the result and next targets before
continuing within that same scope. Do not launch overlapping rounds, silently
expand scope, rerun completed investigations or add unrelated tooling/cleanup
detours. A blocked target does not stop unrelated review or approved cleanup.
At each round report **actually removed / remotely preserved / blocked /
remaining**, with elapsed time and evidence scope. Metadata-reviewed, fully
assessed, pushed and removed are distinct counts. Close only when every in-scope
target has an evidenced disposition; unresolved work remains named, not hidden
inside a smaller worktree total. This is an agent procedure, not a new unattended
service, installed cache or permission grant.

### Packet budgets and separate recovery queue

Assign at most five worktrees per packet and a ten-minute wall-clock budget.
Start from the recorded next targets and existing assessments, not a fresh
instruction tour or full-fleet audit. No nested delegation. At the deadline,
return partial cited results and exact gaps; the coordinator stops further
collection rather than waiting indefinitely or relaunching the same objective.
A timeout is **unknown - retain**, never permission to omit a safety check.

Keep two queues in the same ledger:

- **Cleanup:** clean merged/superseded candidates with complete evidence.
  Prepare their exact paths, full tips, local branches and ignored-file choices.
- **Recovery:** dirty, stashed, claimed, secret-bearing, incomplete or unavailable
  work. Record the retained original, supported preservation coverage, owner
  and next bounded action. Metadata, a checkpoint or a pushed commit does not
  establish full recovery of ignored files, stashes or editor buffers.

A recovery gate blocks its target, not unrelated cleanup candidates. Finish a
cohesive recovery slice through the existing task PR and required checks; never
blanket-stage, stash, copy secrets or turn each dirty tree into an unverified PR.
Time-box a checkpoint attempt as well: preserve the original on timeout or
partial coverage, record the helper gap and do not repeat unchanged attempts.

Reconcile each returned packet once. Batch genuinely outstanding approvals with
exact per-item scope; reuse unchanged approvals and no-writer confirmations.
Only the coordinator executes approved removals, serially, through the existing
executor. Other repository lanes may prepare their next packets concurrently,
but pause the lane for a repository while the coordinator mutates that repo.
No automatic deletion of the next packet and no collector ownership transfer.

Before execution, include collateral operations in the scope review: inspect
`git worktree prune --dry-run --verbose` because the executor also prunes the
repository registry. An unavailable foreign-platform registration remains
protected. If pruning would remove it outside the approved scope, stop and
obtain an exact protective decision; do not force prune or silently add locks.

At packet completion report **removed / remotely preserved / blocked / remaining**
with evidence times and exact recovery/PR links. Distinguish a frozen queue count
from a fresh native count; assessed is not removed or remotely preserved. Record
elapsed time and completed targets, not a promised speedup. Keep one writer and
all permission, ownership, lock, supersession, issue and link-guard boundaries.
