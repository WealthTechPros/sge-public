# Tidy Worktrees: detailed procedure

The full phase-by-phase procedure for [`/sge:tidy-worktrees`](../SKILL.md). SKILL.md keeps the contract, guard rails and phase summaries; this file keeps the detail. It was moved here unchanged when SKILL.md was cut to 8 KB (sge#3697). The one exception is the retired ownership-registry step in Phase 2.

## Verdicts

`VALUABLE` is retired (it conflated unfinished, unpushed and good). Use `NEEDS-DECISION:` plus `LIVE-UNMERGED`, `POST-MERGE-COMMITS`, `CLOSED-PR-UNMERGED`, `UNCOMMITTED`, `STASH`, or `PART-COMPLETE` (assessor-assigned). Other verdicts: `MERGED`, `SUPERSEDED`, `KEEP:<reason>`. The registry lib (`worktree-lifecycle.sh`) still says VALUABLE internally; read it as `NEEDS-DECISION`.

## Out of scope

- Unlocking or removing a locked worktree without the Phase 2b user choice (never under `--force`); touching dirty, stashed, live-claimed or active-PR worktrees.
- Deleting anything without one user-confirmed plan (`--force` still confirms), or deleting remote branches before the local audit is done.
- Merging, auto-merging, force-pushing or bypassing review gates; PRs only via the capped, verified draft multi-select.
- Non-git clutter (use `/sge:clean-root`) and processes (use `/sge:reap-orphans`).

## Usage detail

Use assessors only when delegation is authorized. If no agent tool is available, assess inline. If the structured question tool is unavailable, ask numbered questions.

At the start, use `search_nodes` for the repository. At each terminal path, use `create_entities` for a qualifying pattern, convention or gotcha. Skip this step when sge-memory is unavailable. [Cortex review guidance](../../lib/cortex-review-lane.md)

For a bulk reclaim, close all agent sessions and run the script from a plain terminal. It audits each repository, writes a recovery CSV, and asks for `RECLAIM <n>` before proceeding. Worktrees with staged changes or ignored files require manual preservation. [Bulk reclaim runbook](../../../docs/worktree-reclaim-runbook.md)

For an explicitly requested fleet resume, use the
[resumable runner](resumable-runner.md) with the existing queue:
import once, then `next` / `audit` / `record` / `plan`. Prefer this durable
execution ledger to rebuilding conversational packets. Azure DevOps history
is bulk-paginated once per selected repository. Valuable work stays in the
recovery lane for completion and owning checks; open PRs enter the merge lane
and return to audit only after verified merge or another named invalidation.
Find the existing ledger first, as the runner reference says (a bounded Cortex lookup is a pointer, never the ledger,
backup, safety evidence or approval); if it is missing, recover it rather than re-import or rescan the fleet.
The coordinator records exact approval and uses `execute` (one target) or `reconcile` after interruption; no
background service, automatic merge/deletion or plugin installation is implied. With `--resume`, read `status`
and the current contract first. Prioritise already selected valuable recovery slices; do not let another cleanup packet displace their completion. Use `record --priority` for an explicitly
chosen exact target. Then take at most five unfinished targets per repository; an explicitly requested batch may
combine repository packets for up to ten targets. Before each approved removal run `verify-plan` against the
reviewed fingerprint and live ignored-filename set; a failed verification stops the executor handoff.


## Phase 0 — Sync

For the selected repo, `git fetch --no-prune origin`, then note `git rev-parse --show-toplevel` (the current-worktree guard). Without a fresh fetch, merged PRs look unmerged. Keep remote-tracking ref pruning separate from the audit. Resume the ledger at its next target; refresh selected-target evidence before mutation, not the entire fleet. Name an invalidation and its scope before any broader rescan.

## Phase 1 — Inventory and open-PR set (read-only)

```bash
source "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/lib/host-pr-read.sh"
if ! OPEN_PRS="$(hpr_open_pr_heads)"; then   # "<number><TAB><head-branch>" per open PR
  echo "REFUSE: cannot determine the open-PR set for $(git remote get-url origin) (host: $(hpr_host_kind)) — nothing will be deleted" >&2
  exit 1
fi
```

`hpr_open_pr_heads` routes by host: `gh` on GitHub, the Forgejo adapter, or `azdo-adapter.sh list-prs` on Azure DevOps (needs `SGE_AZDO_TOKEN`, a read-only Code PAT). It fails closed on an unknown host, a failed call, a malformed payload or possible truncation; an empty result with exit 0 is a confirmed zero. On Azure DevOps squash-merges use `hpr_completed_pr_heads <branch>` (fail-closed too).

Then run the **engine**: `bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/tidy-worktrees/audit.sh" --summary [repo dirs…]` (drop `--summary` for the JSON, or add `--json-out <file>`; `--multi <parent-dir>` audits every repo under a folder and adds combined totals). It classifies local worktrees, branches, stashes **and** `origin/*` branches into A-D with PR state, ahead/behind, age, last author and supersession, and prints the delete plan as literal per-branch commands. Fields and rules: [`references/audit-engine.md`](audit-engine.md). Host without bash or jq: follow [`references/safety-audit-checks.md`](safety-audit-checks.md) by hand.

## Phase 2 — Protections (the engine applies these; re-check by hand if you override it)

| Signal | Verdict |
|---|---|
| Fresh `.sge-wt-claim` (`roc_claim_state` = `held-fresh`/`mine`, TTL `SGE_WT_CLAIM_TTL_MIN`) | **KEEP (live claim)** |
| `locked` in `git worktree list --porcelain` | **KEEP (locked)** — audited in Phase 2b; unlocked only on an explicit user choice, never by the sweep |
| Directory mtime within `SGE_WT_RECENCY_GUARD_MIN` (default 10) and no claim | **KEEP (recently created)** |
| Uncommitted changes / attributed stash | C `NEEDS-DECISION:UNCOMMITTED` / `:STASH` — no SHA recovers it |
| Open PR, current worktree, default branch | C KEEP |
| Any lookup failed or the base is unresolved | C KEEP |

An expired claim self-heals into the normal audit. Claim, recency, stash and squash-merge checks: [`references/safety-audit-checks.md`](safety-audit-checks.md). The engine requires the [shared lifecycle library](../../lib/worktree-lifecycle.sh); shipping that dependency does not enable lifecycle hooks. The ownership registry is retired (sge#3697): registration never decides KEEP, and `worktree-lifecycle.sh retire-registry <repo>` archives any legacy entries. Offer `bash "$CLAUDE_PLUGIN_ROOT/skills/worktrees/checkpoint.sh" checkpoint <wt> <session>` for uncommitted work (exit 10 = partial = keep); a checkpoint never authorises deletion.

## Phase 2b — Locked worktrees (read-only audit, then a user choice)

A Git lock is a retention marker, not evidence of an active worker, so locked worktrees are audited rather than silently kept. Run `bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/tidy-worktrees/lock-audit.sh" audit --session "<this session's id>"` (read-only). It splits them into `protected` (live claim, active PR, dirty, stash, tip differs from the merged PR head: KEEP with its reason), `unknown` (unavailable evidence, such as a failed PR or junction probe: kept and surfaced) and `candidate` (clean, no live claim, host-confirmed merged PR whose head equals the exact tip, other checks passed). Missing or different registry ownership alone does not disqualify a candidate. Before approval, confirm no writer is using the selected worktrees. Only when `decision.required` is true, ask one structured question via `AskUserQuestion`: **keep** / **release locks and re-audit only** / **release locks and remove** the listed worktrees and local branches, subset allowed, plus a separate explicit consent naming the ignored files that `remove` would discard (a clean status and a recovery SHA do not back them up). Apply only the approved `path@tip` items with `lock-audit.sh apply`, which re-audits each item immediately before acting and stops any whose eligibility or approved evidence changed. Remote branches, labels and permissions are never touched. Details: [`references/lock-audit.md`](lock-audit.md).

## Phase 3 — Fan out, then decide

Before asking for a disposition, follow the [file-level review](worktree-content-review.md) on GitHub and Azure DevOps.
Use its recommendations to distinguish publication-ready work, work that needs reconciliation, and cleanup candidates.
An audit bucket alone is not consent to discard local files.

1. **Assess B and C (read-only).** When requested or instructed and `Agent` is exposed, use three disjoint collectors by default, up to five repository lanes only for explicitly requested scaling ([scope and packet budgets](sweep-layouts.md#bounded-read-only-fanout)). Reuse assessments; return packets of at most five worktrees within ten minutes, with partial gaps on timeout. Keep recovery targets separate so they do not hold up unrelated cleanup. Otherwise run `assess.sh <repo-dir> <ref>` inline. Within a repo, process worktrees serially. Each returns the [bounded evidence packet](assessor-brief.md). Only this session asks questions, edits, pushes or deletes, behind the confirmations below.
2. **A and D: one plan.** Show every A item (path, branch, PR link, full tip SHA) and every D item (tip SHA, why superseded) in one plan: *remove all merged, choose a subset, or keep everything?* Revalidate each item immediately before removal (tip, files, stashes, claims, locks, recency); anything changed means re-audit. Remote branches need their own explicit confirmation of the literal commands.
3. **B: one capped multi-select.** Offer **one** multi-select, "open draft PRs for these N", containing only items that individually pass: `rescue-guard.sh` supersession `live` **and** the linked issue still open. Draft PRs only, at most `SGE_TIDY_MAX_DRAFT_PRS` (default 10) per run, never auto-merge, never force-push. The rest of B: keep, or discard with SHA, asked per item. Policy: [`references/consolidation-intent.md`](consolidation-intent.md).
4. **C: one named decision each** (continue, keep, or discard with files named). Unknown means keep.

Supersession preflight (run before any push):

```bash
git -C "<worktree-path>" fetch origin main
bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/worktrees/rescue-guard.sh" supersession "<worktree-path>" origin/main
# exit 0 live -> candidate | 30 superseded -> D, never push | 40 unknown -> keep
```

A rescued worktree must then pass `assess` and `verify` ([`references/rescued-worktree-guard.md`](rescued-worktree-guard.md)): `verify:pass` is the only gate for a ready PR, anything else opens a draft.

**Asking.** Use the exposed structured question tool (such as `AskUserQuestion`), at most 4 questions per call, recommendation first. Without it, print a numbered list, e.g. `1. Remove all merged  2. Choose subset  3. Keep all`, and wait for the reply; absent or unclear approval means keep. Templates: [`references/decision-prompts.md`](decision-prompts.md). `--force` presents one consolidated deletion plan (A and D only) and runs it on a single confirmation; it skips the per-item questions, never the audit.

## Phase 4 — Execute (sequential: worktrees, local branches, remote branches)

> **Label-mutation prohibition.** Never add or remove labels on PRs or issues (`pr-reviewing`, `pr-reviewed` belong to the review plane).

Run the approved plan with the **executor**, never with hand-written loops ([contract](executor.md)):

```bash
S="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/tidy-worktrees"
# `--select all` ONLY when the user approved the whole local A/D plan. For a subset, never
# pass `all`: one literal --select '<kind>:<name>@<tip>' per approved item instead.
bash "$S/execute.sh" --audit audit.json --select all --dry-run   # preview
bash "$S/execute.sh" --audit audit.json --select all             # local A/D: recovery CSV first, then worktrees, then branches
bash "$S/execute.sh" --audit audit.json --remote --select 'remote-branch:<name>@<tip>'   # remote: separate approval, literal per branch
```

It writes the recovery CSV (tip SHAs and restore commands) before touching anything. It re-checks each item immediately before acting (tip, tracked tree, lock, claim, current checkout, protected name) and runs the [junction guard](windows-junction-guard.md) before every `git worktree remove`. It never passes `--force`, and it runs `branch -D` only on a re-confirmed tip. Remote branches need `--remote` and a literal token. `git ls-remote` must still show the audited tip, and a fresh open-PR lookup must not list the branch. Every failed check is a `SKIP`: re-audit, do not force. The plan's literal commands (`git worktree remove '<path>'`, `git branch -d '<branch>'`, `git push origin --delete '<branch>'`) remain the manual fallback for a host without bash.

## Phase 5 — Report

Every item ends **already in main / PR opened / kept with a named blocker / discarded with SHA**; list decisions still outstanding and do not say "done" while any remain. Format: [`references/final-report.md`](final-report.md). Distinguish committed, pushed, PR opened and verified merged.

## Multi-repo

Use the [continuing ledger](sweep-layouts.md#scope-and-continuing-execution-ledger), not a new full-fleet audit at each invocation or phase boundary. `audit.sh --multi <parent-dir> --summary --json-out audit.json` remains an explicitly requested folder-wide audit, not the default discovery or resume step. Audit queued repos once as selected; preserve the combined plan and unresolved targets. For explicitly scaled fleets, use the [fleet batch execution plan](sweep-layouts.md#fleet-batch-execution-plan); otherwise follow the [packet budgets and separate recovery queue](sweep-layouts.md#packet-budgets-and-separate-recovery-queue). One coordinator executes confirmed plans serially while other repo lanes prepare; pause collection in the repo being mutated. Review collateral pruning before execution. This is procedure, not an installed atomic queue, cache or admission service.

## Key principles

1. **Local audit before remote deletion;** a branch with no upstream is a single copy: record its SHA.
2. **Squash merges hide behind phantom "ahead" commits:** trust the host's merged-PR record (`gh`, or `hpr_completed_pr_heads` on Azure DevOps) plus tip == recorded head; Forgejo has no such lookup, so there it stays on git evidence. Any lookup failure keeps.
3. **Stashes are repo-global:** attribute them by subject; unattributed ones are a note, not a blocker.
4. **Cleanup never opens PRs one-by-one or in unverified bulk** (#2866). On 2026-10-03 a cleanup session opened 8 PRs and all 8 duplicated work already on main. The maintainer relaxed the one-question-per-branch rule on 2026-11-07 to a single multi-select where each item is individually verified `live` with its issue open, draft-only, capped, never auto-merged, never force-pushed. `--force` never pushes or opens a PR.
5. **Live claims, locks and the recency guard are sacrosanct** (#1759), including under `--force`. A lock is never cleared by the sweep: only the Phase 2b user-confirmed choice (never under `--force`) can release it.
6. **Windows junction guard is mandatory** before any worktree removal.
7. **When in doubt keep and report.** A slightly untidy repo is cheap; lost work is not.
