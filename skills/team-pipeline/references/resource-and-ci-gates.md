# team-pipeline — Phase 3a/3b resource and CI capacity gates

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

### 3a. Resource gate

Before EVERY new spawn within a wave: sample cores + load; if
`LOAD_INT >= LOAD_LIMIT` (80% of cores) **wait on the condition, not the clock** —
the [wait-for-condition loop](../../loops/SKILL.md#b-wait-for-condition-loop):
`Monitor` re-sampling load, waking when it drops (never a foreground `sleep`).
After the gate passes, stagger by a **Monitor-managed minimum delay** (10s/30s/60s
at <30% / 30-60% / >60% load). Commands + stagger table:
[mechanisms](mechanisms.md).

### 3b. CI capacity gate

Count open PRs; if `OPEN_PRS >= CI_LIMIT`, **wait until a slot frees** (a merge)
via `Monitor` re-counting open PRs — not a fixed interval. Command:
[mechanisms](mechanisms.md).
