# team-pipeline — Phase 3 wave discipline

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

> **Wave discipline:** spawn at most `waveSize` (≤ 5) impl agents per wave. A
> wave is "landed" when ≥1 lane opens a draft PR or is stale/hard-killed by the
> time-box. Only after a wave lands may the next begin — enforced **before** the
> resource gate (a secondary check within each wave dispatch).

When `count(activeAgents) >= waveSize`, the wave is full: **BLOCK until a lane
lands** (event-driven — `Monitor` on completion files, not `sleep`). While a wave
has not landed, **do not spawn additional agents** even if CPU/load gating would
permit it. Log `[Wave] wave_active=<N>/<waveSize> — waiting for landing` per
blocked check.
