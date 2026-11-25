# Reconciling a locked dirty worktree (`reconcile.sh`)

The lock audit ([`lock-audit.md`](lock-audit.md)) never offers a dirty worktree, and a tip that differs from the merged PR head stays protected. Both rules stay. When the dirty work was recovered through **another branch** (often squash-merged, sometimes with small corrections), the original keeps its lock forever. `reconcile.sh` is the separate, evidence-led way out. It proves what is already recovered, preserves whatever is not, and only then offers release or removal, each as its own decision.

```bash
RC="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/tidy-worktrees/reconcile.sh"
git fetch origin &&                  # the comparison uses the CURRENT target ref: stop if the fetch fails
  bash "$RC" plan --session "<id>" --recovery "<merge-or-squash commit on the target>" "<worktree>"
```

`plan` is read-only. `--target` defaults to `origin/<default branch>`.

## What the plan reports

- **Inventory.** Every staged, unstaged and untracked version, every ignored file (each leaf path, never a collapsed directory, with a digest), attributed stashes (they live in the repository and are never touched), unpublished commits, junction links and the claim and open-PR state. Content that cannot be read or that `git status` cannot see (unmerged, submodule, nested repository, special file or staged symlink, assume-unchanged or skip-worktree, a path containing a tab or newline, or any scan that failed) is listed as `unknown-not-preserved` and blocks every mutation.
- **Comparison.** Each version (including what the branch committed since its merge base with the target, because a remote-tracking ref can be stale) is compared by Git mode and blob, so an exec-bit change counts. It is classed `in-target` (the same mode and blob as the current target, and for a working file the same raw bytes a checkout would write), `in-recovery` (identical to the recovery commit) or `not-recovered`. A not-recovered version is marked `corrected-in-recovery` when the recovery changed that file differently (an intentional correction), or `missing-from-recovery`, or `line-endings-or-filter-differ` when only a clean filter or line-ending normalisation made the blobs match. Only blob ids, line counts and a whitespace-only flag are shown, never content.
- **Recovery verification.** The recovery commit counts only when it is reachable from the current target. That is checked in Git, independently of host PR metadata, so a squash commit verifies and the recovery branch's own head (which a squash leaves off the target) does not.
- **Blockers.** These are a live claim, an open PR on the branch, recent writes (a possible active writer, `SGE_WT_RECENCY_GUARD_MIN`), a failed PR, claim or junction probe, unreadable state, unknown content, and the current, default-branch, detached or main checkout. Any blocker makes every decision unavailable.
- **`evidence_digest`.** A hash of everything above except clocks. Every approval token is derived from it.

**What the tokens do and do not prove.** A token is an unkeyed hash of evidence that `plan` prints. It is refused for a different decision or once the evidence has changed. While the evidence is unchanged the same token can be resubmitted; tokens are not consumed. It does not prove that a human approved anything: any caller that can run `plan` can read the tokens. Consent lives at the tool and permission layer, the same model as `lock-audit.sh`. Ask each decision through `AskUserQuestion`, and the operator approves the `apply` command at the CLI permission prompt. Pass a token to `apply` only after that decision was given.

A head SHA preserves commits only. Uncommitted work is preserved only by the target, the verified recovery, or a verified checkpoint.

## The three decisions (ask separately, never infer; the ask is the consent, not the token)

Ask through `AskUserQuestion`, one decision per question, recommendation first. Show the summary counts, each not-recovered and unknown path, the ignored list and the junction links.

1. **Reconcile** (`decisions.reconcile`). Release and remove always need this decision first. If nothing is outstanding, it only records the state. Otherwise it captures the work with `skills/worktrees/checkpoint.sh` and then verifies the capture by restoring it into a private temp directory and comparing every version. The reconciliation is recorded only if that check passes. A partial capture is retained, except when the only gap is ignored files. So is a capture that `checkpoint.sh` refuses (uncertain ownership, for example a worktree registered to another session), an interrupted or unverifiable one, and one during which the evidence changed. Unpublished commits always need the checkpoint, because its recovery ref keeps them.
2. **Release** (`decisions.release`). Runs `git worktree unlock` and nothing else, and only once reconciled.
3. **Remove** (`decisions.remove`). Only once reconciled. When ignored files exist it also needs the separate `discard_ignored.approval` token, which is bound to exactly the listed set. The steps are: unlock, unlink junction links (the targets are kept), `git worktree remove`, then delete the local branch. `--force` is used only when the tree is dirty, and the plan says so (`decisions.remove.force`). Remote branches, labels and permissions are never touched. If removal fails after it starts, the lock is restored with its reason when Git allows it, and the result says whether it was.

Release and remove are alternatives. Releasing changes the evidence (the lock), which voids the reconcile record. To remove after a release: plan again, apply a fresh reconcile decision, then apply the remove decision from that new plan.

```bash
bash "$RC" apply --session "<id>" --decision reconcile --approval "<decisions.reconcile.approval>" --recovery "<sha>" "<worktree>"
# no ignored files (decisions.remove.discard_ignored.required is false)
bash "$RC" apply --session "<id>" --decision remove --approval "<decisions.remove.approval>" --recovery "<sha>" "<worktree>"
# ignored files, and the user separately approved discarding exactly the listed set
bash "$RC" apply --session "<id>" --decision remove --approval "<decisions.remove.approval>" \
  --discard-ignored "<decisions.remove.discard_ignored.approval>" --recovery "<sha>" "<worktree>"
```

Pass the same `--recovery` and `--target` as the plan. Every `apply` recomputes the whole evidence set first. If the digest differs from the approved one (a stale approval), `apply` stops with `evidence-changed-since-approval`. A new blocker stops it with `revalidation-<class>:<reason>`. Exit 4 means stopped or retained, and the JSON `reason` says why. A stop before removal starts (a stale approval, a blocker, a missing reconcile record or discard approval) changes nothing. A stop after removal started has the form `remove-failed:<why>:<lock-restored|lock-restore-failed-relock-manually|not-locked-before>:junction-links-unlinked=<n>:worktree-dir=<present|absent>:registration=<present|absent|unknown>`. `not-locked-before` means the worktree was already unlocked (for example after a release), so no lock restore was attempted. `retain_worktree` is true when the directory or registration remains, or when Git could not confirm the registration state. Some junction links may already be unlinked, and the lock may need restoring by hand. Inspect the worktree, its junction links and its lock before retrying. Copy the checkpoint id and status into the final report.

Immediately before `git worktree remove`, the content and the checkpoint it depends on are checked once more; a change stops the removal. That narrows but cannot close the window for an unmanaged writer or a manual `checkpoint.sh prune`, so confirm that no editor, agent or build is writing to the worktree, and do not prune its checkpoint, while a removal runs. Removal never prunes other worktrees' registrations.

Until `#3697` lets `checkpoint.sh` capture an explicitly named unregistered worktree, outstanding work in a worktree that is not registered to the requesting session is retained rather than captured.
