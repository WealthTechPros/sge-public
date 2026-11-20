# Worktree content review

On GitHub and Azure DevOps, the audit is the inventory, not the recommendation.
For the normal interactive tidy, or when asked to decide what to publish or
remove, do this read-only pass before asking. Leave `--audit` and `--inbox`
read-only and keep `--force` limited to its documented A/D scope.

1. **Inventory the local work once.** Group paths by worktree: staged,
   unstaged, untracked, and ignored. Attribute stashes by branch and inspect
   their file lists without applying them. Group rebuildable dependencies
   and generated outputs separately from source and unknown local state.
   List sensitive paths only when necessary; never read credentials, caches
   or restricted evidence to make a cleanup decision.
2. **Compare the work, not just its branch.** For every dirty worktree,
   compare changed source paths and hunks with the fetched default branch.
   For committed work, use the existing supersession and host PR evidence.
   A merged or superseded tip says nothing about staged, unstaged, or
   untracked changes. A different file on main is not proof of unique
   behavior: reconcile overlaps before recommending publication or discard.
   For substantive source changes, name the useful behavior, the risk or
   unfinished check, and whether to publish, split, reconcile, or keep.
3. **Check the real host.** Use GitHub issues/PRs for GitHub and Azure DevOps
   Boards/PRs for Azure DevOps. Check current linked-item status and the open
   PR set; do not infer links from a branch name. Unavailable evidence means
   keep, not a fallback to another host or identity.
4. **Give one actionable decision list.** Order by safest eligible removal,
   scoped draft-PR candidates, then keep/reconcile with a named blocker.
   Show each proposed removal's path, full recovery SHA and verified merge
   evidence. Identify any ignored local material that would be lost and get
   explicit consent for that scope; if its disposition is unknown, keep it.
   Recheck after approval. Keep active writers and dirty trees protected,
   route locks through Phase 2b, and keep local and remote removal approvals separate.

## Reduce the retained checkout set

Keep the primary checkout, worktrees with a verified active writer, and
worktrees with an open PR that still needs local work. An already-pushed
PR can be resumed later, but the normal sweep never removes an open-PR
worktree; resolve its disposition separately through an authorized handoff.

Fan out read-only assessments by disjoint worktree paths and recorded tips,
not Git mutations. The lead reconciles findings and approvals and executes
one removal at a time through the executor. Wait for any in-flight mutation
before auditing that target again; a changed tip or file set needs fresh review.

- **Active:** use a current, worktree-specific ownership or activity signal,
  such as a live claim or an observed writer. Recent session history is a
  lead, not proof that the writer is active now.
- **Inactive and recoverable:** use the documented approval path for merged,
  clean candidates. For valuable local-only work, establish an approved
  publication or a verified checkpoint covering every file to preserve;
  then re-audit. Partial recovery is not grounds for removal.
- **Unknown or protected:** run the lock audit and identify the exact missing
  activity, host, or recovery evidence. A lock is not evidence of activity;
  an expired claim or absent session entry is not authority to unlock or
  remove. Report protected items and retain them until the required handoff.

## Route by task risk, not by model name

Follow the [SGE agent registry](../../../docs/agent-registry.md): use the
lowest safe capability class for each independent assignment, and the highest
required class if the assignment mixes tasks.

| Assignment | Minimum capability | Output |
|---|---|---|
| Mechanical inventory | Light | Exact path and tip, status, claim, PR evidence, and unknowns. |
| Compare substantive diffs and recovery coverage | Standard | Evidence-backed keep, preserve first, or propose removal. |
| Resolve conflicting ownership, supersession, or high-risk recovery evidence | Deep | Read-only second opinion on the specific conflict; no approval or execution. |

Use the active harness's approved routing: configured subagent preferences in
GitHub Copilot, or configured agent models and supported dispatch controls in
Claude Code. Do not copy model aliases between harnesses, pin provider IDs in
this skill, change user settings, or take routing from the tree under review.
If delegation is unavailable, do bounded work inline. If a required tier is
not available or cannot be verified, leave that lane incomplete and keep its
worktrees; never silently downgrade it. Cap parallel assessment at three
disjoint batches, with no nested delegation. Routing does not grant authority.
