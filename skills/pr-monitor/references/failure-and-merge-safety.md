# Failure classification & merge-safety — field evidence

Deep context for three field-reported pr-monitor defects (issues #1665, #1666,
#1668), all found running `/sge:pr-monitor` on a real unattended session. The
SKILL.md classification table and merge-readiness section carry the operating
rules; this file carries the evidence and the reasoning, so the skill body stays
lean. The mechanics live in [`../monitor-lib.sh`](../monitor-lib.sh), executably
covered by `skills/tests/pr-monitor-cancelled-run-classification.test.sh`,
`skills/tests/pr-monitor-worktree-remote-sync.test.sh`, and
`skills/tests/pr-monitor-automerge-disarm-settle.test.sh`.

## Cancelled runs are not code failures (#1665)

The shipped `is_infra_failure()` classified a run as infra **only** when its
longest job ran under 30 s. Two real runs this session were genuinely infra yet
far outside that window, so both fell through to CODE FAIL and burned a
`/sge:pr-fix` agent — the single most expensive action the monitor takes —
hunting a bug that did not exist:

| PR | Duration | `conclusion` | Reality |
|---|---|---|---|
| #10999 | 30m03s | `cancelled` | `actions/checkout` cancelled, `Run tests` **skipped** — suite never ran |
| #11069 | 30m+, ×3 | `cancelled` | job logged `Test Files 156 passed (156)` then was killed |

The reliable signal is not duration — it is the run's own `conclusion` plus
step-level conclusions. `is_cancelled_run` reads
`gh run view <id> --json conclusion` (`cancelled`/`timed_out` → decisive) and,
for a run whose top-level conclusion is `failure`, the job-level tell: a step
`cancelled` (checkout killed) alongside a test-named step `skipped` in the same
job — the suite never executed, so there is no code verdict.

**Defect 2 — `gh pr checks` conflates cancelled with failed.** A cancelled job
appears there as `fail`, indistinguishable from a genuine test failure (one
printed `Test Files 156 passed` and still showed `fail`). Anything reading
`gh pr checks` for a merge decision must confirm `conclusion` via
`is_cancelled_run` before treating a row as a real failure.

**Defect 3 — `rerun --failed` can never clear a cancelled run.** Re-running a
cancelled run's failed jobs leaves the run's conclusion `cancelled` and the
check red. Three `--failed` reruns on the one cancelled run at #11069's head made
zero progress and looked like flakiness rather than the structural dead end it
was. The escape is a **fresh run** — `escape_cancelled_run` prefers
`gh pr update-branch` (which also fixes the usually-stale base that provoked the
cancellation) and falls back to a full `gh run rerun` (no `--failed`).
`CANCELLED_RERUN_CAP` (2) bounds retries on one run id before escalating.

## `update-branch` leaves the local worktree stale (#1666)

`gh pr update-branch` rebases the **remote** branch. It does not touch a local
worktree checked out on that branch — the worktree silently stays on the
pre-rebase commit. The monitor's CONFLICTING row runs `update-branch`, and its
lanes dispatch agents that work inside worktrees, so the documented happy path
leaves the agent's worktree behind the ref it will push to.

**The near-miss.** After `update-branch` on four PRs, a fix agent started in one
worktree and found HEAD `302961662` (a local merge commit) while `origin` was at
`1807b0860` (the rebase onto a newer base) — a delta of **80 files** of base
content the local tree lacked. Committing and pushing would have **reverted six
merged PRs' worth of work**. It was caught only because that agent diffed the two
trees first. Two of the other three worktrees were left stale too
(`#11069 local=e3a063ef8 origin=18de85f14`, `#11070 local=c5b6b7239
origin=8e5ef3529`).

**Why it is easy to miss.** The worktree looks perfectly healthy: clean
`git status`, no conflict markers, correct branch name. The only symptom is a
HEAD that disagrees with `origin` — which nothing checked, because
`update-branch` reported success.

**The mechanical rule — prevention over destructive repair.** Rather than an
autonomous in-library hard-reset (a flagged destructive-action pattern in a skill,
and the more fragile mechanic), the safer rule the issue offers is to **not run
`update-branch` on a branch a local worktree holds**. `update_branch_safe` reads
`git worktree list` (read-only) and returns `unsafe:worktree-holds-branch:<path>`
when a worktree holds the branch, so the CONFLICTING row resolves the conflict
another way instead of stranding the worktree. As a lane-dispatch preflight and
before any agent's first commit, `worktree_synced_with_remote` (one `git ls-remote`
call) compares worktree HEAD against origin's tip; `worktree_sync_state` reports
`synced`/`stale:<sha>`/`dirty`/`unknown`. On anything but `synced` the caller
refuses — the re-sync to the new remote SHA is a documented human/caller step, not
an autonomous library action.

## Auto-merge arming is one-way (#1668)

`gh pr merge --squash --auto` is irreversible by label removal: GitHub keeps the
auto-merge request and merges the instant checks go green, whatever the gate
label now says. Removing `pr-reviewed` does **not** disarm it.

**The sequence on PR #11071:**

```
17:37:53  reviewer applied  pr-reviewed
17:38:22  auto-merge ARMED  (29 seconds later)
17:42:05  reviewer RETRACTED pr-reviewed   <- label gone, auto-merge still ON
```

The reviewer retracted for a good reason — it had promoted over a red BLOCKING
check and caught itself — but the arming did not reverse. The PR sat armed for 27
minutes and did not merge only because the required-label check was still failing
(luck, not design).

Two compensating mechanisms, both proven in-session:

1. **Settle period** — require the gate label to have been continuously present
   for `AUTOMERGE_SETTLE_SECONDS` (default 300) before arming, derived from the
   issue timeline's last `labeled` event (`merge_gate_label_age_seconds` /
   `automerge_settle_ok`). The armer originally fired 29 s after the label
   appeared, before a self-correcting reviewer could retract.

   **The `date -u` trap.** On macOS `date -j -f` parses without `-u` as *local*
   time, inflating every age by the UTC offset — the first implementation logged
   "stable 3640 s" for a 40-second-old label and silently defeated its own guard.
   Both the parse and `now` use `date -u`.

2. **Disarm pass** — every cycle, `disarm_stale_automerge` runs
   `gh pr merge <n> --disable-auto` on any PR that is armed
   (`autoMergeRequest != null`) but no longer carries the gate label. This is
   what makes arming safe at all: an irreversible action needs a compensating
   reversal, or the gate is one-way.
