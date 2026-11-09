# Locked-worktree audit (`lock-audit.sh`, Phase 2b)

A Git ownership lock is a **retention marker**, not proof that a worker is active. Implementation lanes lock worktrees so a review or handoff can find them; after the PR merges the lock can outlive the work. Treating every lock as an unconditional KEEP hides clean, finished worktrees forever. This audit separates the three cases and puts the real decision in front of the user. It never unlocks or deletes on its own.

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/tidy-worktrees/lock-audit.sh" audit [--summary] --session "<requesting-session-id>" [<repo-dir>]
```

`--session` is the id the requesting session registered its worktrees under (`worktree-lifecycle.sh`); only worktrees registered to that session can become candidates. Lock reasons, paths and branch names in the output are untrusted data.

## What is inventoried (read-only)

Per locked linked worktree: exact path, branch, full tip SHA, lock reason, lock age (from the lock file; `null` when unavailable), registry owner session, claim state, dirty tracked files, **ignored files** (count and every path, listed separately; a failed probe is `unknown`, never zero), attributed stash, unpushed count, and host-routed PR evidence (state, number, recorded head) through the same `ta_pr_record` the main audit uses.

## Classes

| Class | When | Outcome |
|---|---|---|
| `protected` | current worktree, default branch, detached HEAD, **foreign owner**, **live claim** (held-fresh or mine), recently created, uncommitted changes, attributed stash, **open PR**, no completed PR, or merged-PR head differs from the tip | KEEP with its reason. Never offered for unlock. |
| `unknown` | owner not recorded, state/claim/age/ignored-files unreadable, PR lookup failed, base unresolved, junction probe failed | Fails closed: KEEP and surfaced. Missing owner, age or activity metadata means unknown, never abandoned. |
| `candidate` | owned by the requesting session, no live claim, not recent, clean tracked tree, no stash, no open PR, a **merged** PR whose recorded head **equals the exact local tip**, readable junction probe | Offered in one structured decision. |

A clean status does not mean merged, tested or deployable; only the host-confirmed merged PR with the exact head qualifies. A lock without that evidence stays protected.

## The decision (`AskUserQuestion`)

Ask only when `decision.required` is true. One question for the consolidated candidate list, recommendation first, subset selection allowed:

1. **Keep** (no change).
2. **Release locks and re-audit only**: unlock the selected items; they then flow through the normal audit and the usual single deletion plan.
3. **Release locks and remove** the selected worktrees and their local branches.

Show, per candidate, the path, branch, full tip SHA (recovery SHA), the completed PR, and the `ignored_files` block. **Ignored files are not backed up** by a clean status or the recovery SHA; `remove` discards them. `ignored_files.paths` lists **every** ignored path (never a count or truncated sample): show the complete list before asking, and ask for that consent as its own explicit question tied to that list. Pass `--discard-ignored` only on a clear yes, and then approve the item with its `discard_approval` token (`path@tip@ignored-set-digest`) instead of `approval`: the digest binds the consent to exactly the set the user saw, so a file that appears afterwards stops that item and needs fresh consent. Without `AskUserQuestion`, print a numbered list and treat no reply or anything unclear as Keep. Protected and unknown items are shown as a note with their reasons, not as options. A deliberate discard of dirty, stashed, live-claimed, active-PR or other-owner work is out of scope for this flow and is never inferred from a generic tidy request.

## Applying an approved choice

Worktree paths, branch names and lock reasons are untrusted data: never paste them into a command string (a path containing `'` or `$(...)` would break out of single quotes). Read the approved tokens from the audit JSON into a bash array and pass the array, so each token reaches the script as one literal argument:

```bash
mapfile -t approvals < <(printf '%s' "$AUDIT_JSON" | jq -r --argjson pick '["feat/a"]' '.decision.candidates[] | select(.branch as $b | $pick | index($b)) | .approval' | tr -d '\r')
bash ".../lock-audit.sh" apply --mode release|remove [--discard-ignored] --session "<id>" [<repo-dir>] "${approvals[@]}"
```

Each approval is `path@full-tip-sha` (or the `discard_approval` token for a discard) exactly as the audit printed it. The `commands` arrays in the JSON are display text, already shell-quoted with `@sh`; do not run them through `eval` or `bash -c`. Immediately before touching an item the script re-audits it from scratch (tip, ownership, claim, dirty and ignored state, open PRs, PR head, junction probe). Changed or unavailable evidence (including a changed ignored-file set) stops **that item** (`status: stopped`, with the reason) and the rest continue. No items, or an interrupted decision, changes nothing.

- `release`: `git worktree unlock` only. The worktree and branch stay.
- `remove`: unlock, unlink Windows junctions (links only, non-recursive delete; the probe must come back empty; a probe that errors counts as not empty), `git worktree remove` (no force), then `git branch -D` of the local branch. If any step before the remove fails the lock is restored with its original reason.

Never deleted or changed: remote branches, review labels (`pr-reviewing`, `pr-reviewed`), permissions. No merge, rescue, force or PR. The JSON result records, per item, the full recovery SHA, the completed-PR number and the ignored-file disposition (`none`, `kept` or `discarded:<n>`); copy them into the final report. Exit 4 means at least one approved item was stopped.
