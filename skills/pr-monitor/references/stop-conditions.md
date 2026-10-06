# Stop conditions and exit report

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Stop conditions

- All lanes empty (everything merged) → DONE.
- A PR is **structurally blocked** (see `/sge:pr-fix`, outcome `status: blocked` in its [exit report](../../exit-report/SKILL.md)) → leave it, report, keep monitoring the other lanes.
- A PR is **thrashing** (`/sge:pr-fix` outcome `status: thrashing`) → treat like `blocked`: leave the lane, report it, keep monitoring others. Do **not** re-dispatch `/sge:pr-fix` on the same PR — the human decides next.
- **No progress for `IDLE_LIMIT` cycles** → summarize per-lane blockers and stop.
- Never weaken a check or force-merge to clear a lane — escalate to the human instead.

### Exit report (machine-readable terminal artefact)

On any stop, emit **one** [exit report](../../exit-report/SKILL.md) — the shared JSON shape — as a fenced ```exit-report``` block, so a parent orchestrator can act without re-parsing prose. The per-lane summary above is *in addition to* this block. Map the terminal state onto the schema:

- `skill: "pr-monitor"`, `runId` = dispatcher-provided or self-minted `pr-monitor-<repo>-<ISO start>`.
- **One `outcomes[]` per lane** touched — `item: "pr:<N>"`, `status` from its terminal state (`success` merged · `blocked` · `thrashing` · `partial` in flight). Every non-`success` `detail` states the blocking condition **and** the next action.
- `stopReason`: all merged → `queue-empty`; idle-limit → `no-progress`; user stop → `user-stop`.

```exit-report
{
  "skill": "pr-monitor",
  "runId": "pr-monitor-WealthTechPros/sge-2026-07-08T09:00:00Z",
  "itemsProcessed": 3,
  "outcomes": [
    { "item": "pr:812", "status": "success", "pr": 812, "detail": "merged after review + CI green" },
    { "item": "pr:815", "status": "blocked", "pr": 815, "detail": "self-approval blocked — needs one human approval click" }
  ],
  "stopReason": "no-progress"
}
```

---
