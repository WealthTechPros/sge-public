# Linear procedure (when capabilities are missing or inline work is selected)

Use this when `Agent` or a structured question tool is unavailable, or inline work is selected.
Client name does not determine tool availability: GitHub Copilot can use the main phases when both capabilities are exposed.
Assess inline without `Agent`; use the exposed structured question tool when available, otherwise the numbered questions below.

Each ordered step retains its safety gates and explicit approval requirements.
Destructive operations use `execute.sh` rather than hand-written deletion commands.
On Windows, run the scripts with `bash` (Git Bash).
On Azure DevOps, the audit requires `SGE_AZDO_TOKEN` (a read-only Code PAT).
A missing token or failed audit means retain all targets; no deletion is authorised.

First resume the [scope and continuing execution ledger](sweep-layouts.md#scope-and-continuing-execution-ledger). Default to the current repo; discover known roots once only for an explicit all-local/hub request. Queue deduplicated repositories and finish one worktree at a time. The ledger never replaces selected-target freshness or approval; name an invalidation before any broader rescan.

Apply the [packet budgets and separate recovery queue](sweep-layouts.md#packet-budgets-and-separate-recovery-queue)
even inline: reuse completed assessments, time-box the next packet, retain
unknowns and advance unrelated clean candidates. If agents are exposed and
scaling is explicitly requested, use the main skill's bounded repository lanes
instead of forcing this linear fallback. Do not change permissions to scale.

```bash
S="${CLAUDE_PLUGIN_ROOT:-<path to the installed sge plugin>}/skills/tidy-worktrees"
AUDIT_FILE="<absolute audit artifact path from the selected repository's ledger>"
```

Before every executor invocation, verify that `$AUDIT_FILE` belongs to the selected repository and matches the approved plan, including full target tips and repository-qualified selectors. A missing, mismatched or unverified artifact means keep; the current directory's filename is not a fallback.

1. **Audit the selected repo, read-only.** Reuse its recorded inventory unless a named invalidation requires a refresh: `bash "$S/audit.sh" --fetch --summary --json-out "$AUDIT_FILE" <repo-dir>`. Only for an explicitly requested folder-wide audit: `bash "$S/audit.sh" --fetch --summary --json-out "$AUDIT_FILE" --multi <parent-dir>`. Do not restart the full-fleet audit on resume. Show the summary and record its source/time and absolute artifact path in the ledger. If a repo says `REFUSED`, nothing in it can be deleted. Say why (for example, no token or a failed PR lookup), record keep with its gap, and continue with queued targets.
2. **Locked worktrees (only if the audit lists `KEEP:git-locked`).** Run `bash "$S/lock-audit.sh" audit --session <id>` and follow [`lock-audit.md`](lock-audit.md). Otherwise skip this step.
3. **Assess B and C inline, one item at a time.** For each B item, and each C item that is not simply protected (open PR, main checkout, protected name, recent), run `bash "$S/assess.sh" <repo-dir> <branch-or-origin/branch>`. Then check the linked issue on the host, and write one line per item: recommendation (`open-draft-pr`, `continue`, `keep` or `discard`), the reason and the confidence. The checklist is in [`assessor-brief.md`](assessor-brief.md). If the evidence is missing or contradictory, the item is `keep`.
   Complete the [file-level review](worktree-content-review.md) before presenting choices. The first removal batch should be the smallest clearly recoverable subset, not every item in A/D by default.
4. **Ask about A and D in one numbered list.** List every A and D item from the audit with its kind, name, full tip SHA and reason, then ask:
   `1. Remove all eligible local items  2. Choose a subset (show the recommended subset)  3. Keep everything`.
   Wait for the reply. If there is no reply or it is unclear, keep everything.
   **If the outcome is keep everything (option 3, no reply or an unclear reply), skip steps 5 and 6** and go to step 7. Nothing local is removed, and the executor is not run.
5. **Preview.** First inspect `git -C <repo-dir> worktree prune --dry-run --verbose`; the executor also prunes registrations. If an unapproved unavailable registration would be removed, stop for an exact protective decision. Use `--select all` only when the user chose option 1 (every local A/D item): `bash "$S/execute.sh" --audit "$AUDIT_FILE" --select all --dry-run`. For a subset (option 2), never pass `all`; pass `--select '<kind>:<name>@<tip>'` once per chosen item, written out literally. In a multi-repo audit, prefix the token with its repo as `'<repo>::<kind>:<name>@<tip>'` (the `repo` field of the audit). The executor refuses an unqualified token that matches in two repos. Show the `WOULD`/`SKIP` lines.
6. **Run local removal.** Run the same command without `--dry-run`. It writes the recovery CSV first; give the user its path. Show the result table and the `SUMMARY` line. If an item is `SKIP`, leave it alone and report its reason; never retry with force.
7. **Ask about remote branches separately.** List the remote A/D branches with their literal tokens (`remote-branch:<name>@<tip>`) and ask `1. Delete these N remote branches  2. Choose a subset  3. Keep all`. Approving local removal does not cover remote branches.
8. **Run remote removal (only if approved).** Run `bash "$S/execute.sh" --audit "$AUDIT_FILE" --remote --select 'remote-branch:<name>@<tip>' ...`, with one `--select` per approved branch, written out literally. Show the result table.
9. **B: one numbered multi-select for draft PRs.** Offer only items whose `assess.sh` supersession is `live` and whose linked issue is open, capped at `SGE_TIDY_MAX_DRAFT_PRS` (10). Ask with a numbered list (reply `1,3` or `none`). For each chosen item, run the supersession preflight and the [rescued-worktree guard](rescued-worktree-guard.md), push the branch and open a **draft** PR. Never merge, auto-merge, force-push or change labels. Ask about the rest of B one item at a time: keep, or discard with the tip SHA recorded. Before every approved B discard, apply step 5's prune preview and protective-decision gate even when steps 5 and 6 were skipped for A/D; the executor dry run does not preview repository-wide pruning. Then preview the exact B selection with `--dry-run` and run the approved discard through the executor: `bash "$S/execute.sh" --audit "$AUDIT_FILE" --buckets B --select '<kind>:<name>@<tip>'`. It records the SHA in the recovery CSV and skips the item if its tip has moved. `--select all` never selects a B item.
10. **C: one numbered question per item.** Ask continue (name the gap), keep (name the blocker), or for uncommitted work or stashes, checkpoint locally or discard (name the files that will be lost). If unsure, keep.
11. **Report.** Every item ends as already in main, PR opened, kept with a named blocker, or discarded with its SHA ([format](final-report.md)). Include the recovery CSV path. Do not say "done" while any decision is still outstanding.

Question wording: [`decision-prompts.md`](decision-prompts.md). Executor contract: [`executor.md`](executor.md).
