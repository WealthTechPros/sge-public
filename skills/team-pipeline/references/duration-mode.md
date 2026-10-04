# Duration Mode (`--duration`) — full overlay

Moved from `SKILL.md` (issue #2825) to keep the SKILL.md under the skills-ci 34 KB warn line. `SKILL.md` keeps a stub with the per-invocation defaults (deadline arithmetic, drain grace, runway); the full overlay lives here.

## The time-boxed swarm

> An **overlay** on the normal phases (same engine, waves, lean contract, kill
> thresholds) plus one master stop — the wall clock. Folded in from
> `/sge:issue-swarm` (#808, epic #730), now a router stub to this mode.

`--duration <Nm|Nh>` makes the wall-clock budget the **master terminal
condition**: every decision is checked against remaining budget, and when it runs
out the pipeline **stops spawning, drains in-flight lanes, and reports** — never
overrunning or abandoning a half-done lane. (Without `--duration`, it runs to
queue drain.)

**Deadline arithmetic (Phase 0 overlay)** — compute the deadline first
(`DURATION_SECS` = `Nm*60` or `Nh*3600`; `DEADLINE = $(date -u +%s) +
DURATION_SECS`) and add `"deadline"`, `"durationSecs"`, `"stopReason": null` to
Phase 0 state. All other Phase 0 guarantees (agentMax ≤ 15, waveSize ≤ 5,
staleKill, budgets) apply **unchanged**.

**Discover → gate → decompose front end (Phase 1 overlay).** Prefer the gated
front end over the raw list: discover via `/sge:available-issues`, reconcile
(MANDATORY, Phase 1 pre-flight), then **gate every candidate through
`/sge:build-ready-audit` before any claim** — **READY** → queue, **NOT_READY** →
drop (blocker in `failedIssues`; never lock/spawn), **TOO_LARGE** →
`/sge:decompose-issue` (re-gate children, merge READY ones, never claim the
parent). The [intake gate](mechanisms.md#intake-gate) drops every
candidate without a passing `intake-check.sh` before any claim — no fallback. **Re-fill** when the queue runs low, only if
`time_remaining >= MIN_AGENT_RUNWAY`. [Full steps + fallbacks](mechanisms.md).

**Spawn gate overlay (Phase 3).** A new impl lane spawns only if `now < DEADLINE`
**and** `time_remaining >= MIN_AGENT_RUNWAY` **and** the wave/resource/CI gates
pass **and** the queue is non-empty. `MIN_AGENT_RUNWAY` is a conservative
one-issue estimate (default **20 min**); front-load, let the tail drain. **The
clock is a first-class wake event:** every `Monitor` wait in Phases 3/4 is also
bounded by `DEADLINE`, waking there to trigger shutdown.

**Terminal conditions (`stopReason`):** `now >= DEADLINE` → **primary**, stop
spawning, drain in-flight, report (`bound-hit`); `queue-empty`;
`budget-exhausted`; `user-stop`. At the deadline: stop spawning at once (no
new claims/worktrees), but **never hard-kill a productive in-flight lane because
the clock struck** — allow a grace window (default **10 min** past `DEADLINE`) for
the tail to drain, then hard-stop any remainder per the normal kill threshold,
then Phase 6.

**Invariants:** lanes run the Phase 3c Lean Agent Contract, never a full
`/sge:sge-implement`; stale/over-budget lanes are NOT auto-requeued;
the duration bound is the master stop (no run-forever);
never start a lane that cannot finish before the deadline; never weaken a control
to exit the loop (no skipped tests/`--no-verify`). Two former issue-swarm
contradictions fixed: [rationale](rationale.md).

`--dry-run` + `--duration`: discovery + gate read-only, print the plan **and
budget arithmetic** (deadline, runway, projected waves), claim nothing. The
Pre-Dispatch Safety Gate still runs in full.
