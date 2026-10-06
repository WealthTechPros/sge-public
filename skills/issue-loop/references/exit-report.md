# issue-loop — machine-readable exit report

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Alongside that human-readable summary, emit **one** shared [exit report](../../exit-report/SKILL.md) as a fenced ```exit-report``` block so a parent orchestrator (or a `/loop` re-invocation) can act on the run without re-parsing the ledger prose — one `outcomes[]` entry per issue this run acted on (`item: "issue:<N>"`, `status`: `success` merged · `skipped` `loop-skip`/not-ready/reconciled-away · `thrashing` retried-twice · `failed` otherwise; carry the PR number in `pr`), and decomposed parents recorded as `skipped` with the split noted in `detail`. Map issue-loop's stop vocabulary onto the schema's `stopReason` enum:

| issue-loop stop | schema `stopReason` |
|---|---|
| `queue-exhausted` | `queue-empty` |
| `max-issues` | `bound-hit` |
| `duration` | `bound-hit` |
| `systemic` (3 different-issue failures) | `error` |
| `user` | `user-stop` |

```exit-report
{
  "skill": "issue-loop",
  "runId": "issue-loop-<repo>-<ISO start>",
  "itemsProcessed": 4,
  "outcomes": [
    { "item": "issue:806", "status": "success", "issue": 806, "pr": 812, "detail": "merged, reviewed" },
    { "item": "issue:830", "status": "skipped", "issue": 830, "detail": "loop-skip after 2 failures" }
  ],
  "stopReason": "queue-empty"
}
```
