# Monitor loop

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Monitor loop

**Wait mechanism — event-driven, not sleep-polling** (the [wait-for-condition loop](../../loops/SKILL.md#b-wait-for-condition-loop)). For each occupied lane, start a **background task** running `gh pr checks "$pr" --watch` (blocks until that PR's checks settle). Any lane's watch completing triggers a cycle — classify that lane, act, restart its watch. Never busy-loop on chained sleeps; the watches *are* the clock.

```
LANES = $1 (default 3); IDLE_LIMIT = 5

CYCLE (on any lane's `gh pr checks --watch` returning, or a lane action completing):
  heartbeat log line: cycle number + lane→PR map + per-lane state
  # Disarm sweep (#1668): disable auto-merge on any PR armed but no longer
  # carrying the gate label — the compensating reversal for an irreversible arm.
  disarm_stale_automerge
  # Fourth leg — stale-draft sweep (#1248): green stale drafts readied, red ones
  # get an abandonment comment. Self-guards; active drafts are no-ops.
  for each open draft PR: stale_draft_lane "$pr"
  # Stale-review sweep (#2644): verdict predates head -> re-dispatch /sge:pr-review.
  for each open PR: stale_review_check "$pr" && dispatch /sge:pr-review "$pr"
  for lane in 1..LANES (oldest first):
    if lane has a PR: classify → act; if merged, backfill next oldest eligible PR
    else: backfill next oldest eligible PR (or mark empty)
  # Backfill draws from the eligible set: fetch_candidate_prs (unclaimed) PLUS any
  # claimed PR reclaim_if_stale returns 0 for (stale → reclaimed). Fresh claims skipped.
  restart the background watch for every occupied lane
  if no lane changed state this cycle: idle_cycles++ else idle_cycles = 0
  if all lanes empty: DONE
  if idle_cycles >= IDLE_LIMIT: STOP (no-progress — see below)
```

### Heartbeat logging

Emit one heartbeat line per cycle so an unattended run is observable after the fact — cycle number, lane→PR map, each lane's state:

```bash
printf '[%s] cycle %s | %s\n' "$(date -u +%H:%M:%S)" "$CYCLE_NUM" \
  "$(for l in "${!LANE_PR[@]}"; do printf 'L%s:#%s(%s) ' "$l" "${LANE_PR[$l]}" "${LANE_STATE[$l]:-?}"; done)" \
  >> "${PR_MONITOR_LOG:-/tmp/pr-monitor-heartbeat.log}"
```

### Cadence — event-driven first, adaptive sleep as fallback

The `gh pr checks --watch` background tasks *are* the clock — **top-level sessions only** (a dispatched subagent polls synchronously; #1681, loops §B). Where watches can't fan out, fall back to an **adaptive poll**: **~30s** while any lane is active (fix/check/rebase in flight), **~90s** when every lane is merely queued. Optionally, if local load average reads high (≥ 1.5× core count), wait one extra interval before dispatching another fix agent — a courtesy throttle, not a correctness gate.

### No-progress stop condition

The no-progress terminal of the [bounded refinement loop](../../loops/SKILL.md#c-bounded-refinement-loop) — bound **`IDLE_LIMIT` cycles** (default 5). If that many consecutive cycles pass with no lane changing state (no merge, commit, check transition, or classification change), the monitor is watching paint dry. **Summarize and stop**: report each lane's PR, its blocking condition, and the next action, then exit.

### Running across sessions (recurring)

A single run shepherds the current batch and exits — but a PR can go green hours later, and **webhooks don't cover CI-success or merge-state transitions**. For duty outlasting one session, run as a [recurring loop](../../loops/SKILL.md#d-recurring--cross-session-loop): `/loop <interval> /sge:pr-monitor`. Idempotent — each run re-derives lanes from the live oldest-eligible query and the claim mutex.

---
