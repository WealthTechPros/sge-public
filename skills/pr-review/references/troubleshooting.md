# pr-review — troubleshooting

---

## "Still waiting on CI" repeated across many turns (silent re-wake stall, issue #1681)

**Symptom.** A dispatched `/sgd:pr-review` (or `/sgd:pr-fix`) subagent reaches the CI-wait
step, reports something like "waiting for the CI monitor to report all checks settled" or
"holding here until the background watch completes", and ends its turn. It is then silently
re-invoked over and over — 10–20+ wake cycles per PR — each time re-reading full context and
re-reporting the same "still waiting" status with no new information. Token cost measured at
~300–520k per PR before the review finally completed. The PR meanwhile looks "in progress"
(`pr-reviewing` held) with no visible activity.

**Root cause.** The skill's CI wait was launched as a **backgrounded** `gh pr checks --watch`.
A background task genuinely blocks a top-level orchestrating session, but it does **not hold a
dispatched subagent's turn open**: the harness treats "no pending tool calls this turn" as
turn-end, so the subagent's process ends and is externally resumed on notifications instead of
the watch's completion continuing the same turn.

**Fix.**

1. Wait with the **bounded synchronous poll** as **ONE tool call** — see the canonical loop in
   [loops §B](../../loops/SKILL.md#b-wait-for-condition-loop) and the Phase 7/9 contract in
   [`gate-and-termination.md`](gate-and-termination.md): `until ! gh pr checks "$PR" | grep -qE
   'pending|in_progress'` with a sleep interval and an iteration cap (~60 × 20s), so it returns
   exactly once — settled or capped — and can never hang forever.
2. **On resume** while still holding `pr-reviewing` with no terminal CI state: recognise this
   stall, immediately re-run the synchronous poll, and finish the label state machine in-run —
   never re-report "waiting" and end the turn again.
3. If a dispatch prompt is involved, it may also state: "block synchronously on CI — never
   schedule a background wait and return control."
