# team-pipeline — Phase 4 health monitor loop

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Run while `activeAgents` or `pendingReviews` is non-empty. **Event-driven, not a
fixed 60s poll** — the
[wait-for-condition loop](../../loops/SKILL.md#b-wait-for-condition-loop): `Monitor`
wakes on the next completion-file or a stall threshold, whichever first (never
busy-loop on a foreground `sleep`).

**Implementation agents:**

1. Read `/tmp/team-pipeline-agent-<N>.json` — if `completedAt` set the agent
   finished; go straight to step 4/4a by `outcome` (a completed agent is never
   stale, however long it ran). Only run steps 2–3 when `completedAt` is unset.
2. Stall / stale detection (wall-clock only — no separate token-based kill):
   - 0-15 min normal; 15–`staleKillMinutes` min, no PR → log activity `[WARN]`.
   - > `staleKillMinutes` (default 20), no draft PR → STALE (time-box kill)
   - > 45 min total → HARD KILL (same procedure; also catches a lane that overran
     its Per-Task Budget target)
3. On stale/kill: see *Stale-lane kill procedure*.
4. On clean completion (`success` + `prNumber`): `persist_lane_usage` **before**
   releasing the worktree (meter lives there — see *Durable token-usage
   persistence*), comment the finish notice on the issue, spawn the review
   agent, release worktree + lock, pull next issue — marks wave landed.
4a. On governance-blocked completion (`outcome == "blocked"`, `prNumber` null) —
    the governance-trace gate pausing for a human decision, not a stall/failure:
    `persist_lane_usage` **before** releasing the worktree; comment the
    needs-decision notice on the issue; release worktree + lock as a clean
    completion would; append to `governanceBlockedIssues[]`
    (`{"issue":<N>, "notedAt":"<ISO>", "note":"<note>"}`); log `[Blocked] Lane
    #<N> paused — <note>`; pull the next issue (marks wave landed). Do **not**
    add to `staleLanes`/`failedIssues` — the fix is a human decision on the
    issue, not a re-scope.

**Review agents:** read `/tmp/team-pipeline-review-<PR>.json`; > 10 min → stall
(leave PR draft; pr-monitor handles it); on completion → `reviewedPRs` or log
findings. **Running agents are never killed to free resources for a new spawn.**

**Per-lane last-activity line + resource log (every tick, all active lanes)** —
the **stall-detection signal**. Bash:
[mechanisms](mechanisms.md).

### Stale-lane kill procedure

When a lane is stale (no draft PR after `staleKillMinutes`) — also the path for a
lane past its *Per-Task Budget Contract* target (caught here by the wall clock),
in order: (1) `TaskStop "impl-<N>"`; (2) remove
`agent-lock` from the **tracking** issue (status stays there even for a cross-repo
lane, SPEC-057 #1024); (3) `persist_lane_usage` **before** removing the worktree,
using the recorded execution path `${AGENT_WORKTREE[<N>]}` (0 if never metered —
the record still shows the lane ran); (4)
`git -C "${AGENT_EXEC_ROOT[<N>]}" worktree remove … --force` from the **execution**
checkout; (5) append to `staleLanes[]` (issue, killedAt, ageMinutes, lastCommit,
`recommendation:"re-scope"`); (6) **comment the re-scope recommendation on the
issue itself** (state is /tmp, dies with the session); (7) log
`[Kill] Lane #<N> stale after <M>min`; (8) do NOT re-queue — add to `failedIssues`
(reason `stale-killed`); (9) mark wave landed. A human decides whether to
decompose before re-dispatch. All three templates:
[mechanisms](mechanisms.md#lane-transition-issue-comments).

### Adaptive scale-up

If load < 40% for 3 consecutive checks AND the queue has issues AND
`count(activeAgents) < waveSize` AND the wave has landed — spawn the next issue
immediately (still wave-size-capped).
