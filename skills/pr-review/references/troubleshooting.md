# pr-review — troubleshooting

---

## "Still waiting on CI" repeated across many turns (silent re-wake stall, issue #1681)

**Symptom.** A dispatched `/sge:pr-review` (or `/sge:pr-fix`) subagent reaches the CI-wait
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

---

## Dispatched lanes redundantly re-running the full project test suite (issue #2456)

**Symptom.** Reviewing a large but low-risk PR (`data-remediation#780`, 1071 weighted lines,
behaviour-preserving refactor, fully self-documented with a per-commit pytest baseline in the PR
body) classified `high` risk on line count alone (no security-glob match). The full ~4800-test
project suite (~8-10 min wall-clock per run) was independently run **at least 5 times** across
the review, by 4 uncoordinated dispatched actors:

- Phase 3 (orchestrator, correct): 1 full run — the one authoritative gate.
- `@code-reviewer`: 2 full-ish runs — its first run silently resolved `data_remediation` from a
  **different worktree's** global Python interpreter, producing spurious failures; it noticed
  and redid the entire verification from scratch. ~140k + ~124k tokens combined.
- Native `/code-review max`: at least one of its three finder passes ran something close to the
  full suite. ~150k tokens, ~23 min wall-clock for one lane.
- `@security-auditor`: ran 4 *targeted* invocations scoped to touched modules — correctly
  followed the "scope to the diff" guardrail, proving the instruction works when a lane actually
  applies it.

Total: ~500k+ subagent tokens and 40+ minutes of wall-clock re-deriving the same "does the full
suite still pass" answer Phase 3's own gate had already established once.

**Root cause.** Two distinct gaps, both silence rather than an active bug:

1. [`dispatch-scaling.md`](dispatch-scaling.md)'s "trust the PR's own tests first" guardrail
   unconditionally applied its discount at `low`/`medium` tier, but was silent on full-suite
   re-runs specifically at `high` tier — where investigation depth legitimately increases, a
   lane read that as licence to re-establish the suite-wide baseline itself, rather than trusting
   Phase 3's already-authoritative run.
2. No instruction told a dispatched lane to check the target repo's own documented
   dev-environment setup (a per-worktree virtualenv, in `data-remediation`'s case) before
   invoking a bare `pytest`/`npm test` on PATH — one lane fell into exactly the hazard that
   convention exists to prevent, paying for an entire redundant verification cycle to discover
   and recover from it.

The sibling principle — [`reviewer-lanes.md`](reviewer-lanes.md)'s "hand off dispatched checks,
do not shadow-verify" (#951) — covers the *orchestrator* not re-deriving what it delegated to a
lane. It does not cover this, the reverse case: *lanes* re-deriving what the orchestrator already
ran and delegated to Phase 3.

**Fix.**

1. [`dispatch-scaling.md`](dispatch-scaling.md#investigation-depth--pragmatism-guardrails-issue-888)
   now explicitly names the full-suite re-run as the guardrail's most common redundant-cost
   pattern, at **every** tier including `high` — a lane runs only targeted tests scoped to what
   it is personally verifying, or trusts Phase 3's already-passed result.
2. [`reviewer-lanes.md`](reviewer-lanes.md#structured-findings-contract--schema) adds a
   verbatim-required dispatch-prompt instruction, matching the existing #855 silence-instruction
   convention: never re-run the full suite, and check the repo's documented environment setup
   before running any test command.
