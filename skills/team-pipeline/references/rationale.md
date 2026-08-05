# team-pipeline — design rationale & incident history

The *why* behind the skill's controls. None of this is load-bearing at run time
— the operational rules live in core SKILL.md. This file preserves the incident
post-mortems and reasoning that justify those rules, so they are not re-litigated.

---

## Stoppable-Only Fan-Out Rule — rationale

In a real session, 6 detached/remote agents ran 1–3 hours each with no way to
stop them. The only permitted fan-out modes are ones where a single `TaskStop`
call (or OS signal) cleanly terminates the agent. This constraint is
non-negotiable — it is what lets the orchestrator's stall detection and
hard-kill thresholds (Phase 3/4) actually work.

- `Agent(isolation:"remote")` — remote agents cannot be reached by `TaskStop`;
  there is no kill switch once launched.
- `Agent(run_in_background:true)` detached, fire-and-forget — these run outside
  the orchestrator's task graph and are invisible to `TaskStop`.

Implementation rule: Phase 3c impl agents, Phase 3d review agents, and the
Phase 2 PR monitor MUST all use the named `Task` form so they are stoppable when
`prMonitorStatus = "stop"` is set in Phase 6.

---

## Wave model — why waves exist

The orchestrator dispatches at most `WAVE_SIZE` lanes (default 5, hard ceiling)
at once and watches each wave land before the next begins. This prevents the
observed pattern of 8+ lanes dispatched simultaneously with no observability. An
unbounded fan-out also trips the Anthropic rate limit and kills in-flight agents
(observed in a live session), which is why `agentMax` is hard-clamped at 15.

### Wave-cap ceiling — why the number, and its history

The hard ceiling exists to protect against two real failure modes, **not** as an
arbitrary throughput knob: (1) **Anthropic API rate-limit exhaustion** — too many
concurrent heavy sessions trip the org's requests/min or tokens/min limit and
kill in-flight agents mid-lane; and (2) **local resource contention** — each lane
peaks at ~3 cores (type-check + tests + lint) and its own worktree, so unbounded
lanes saturate the host. The ceiling is the backstop that keeps both bounded
regardless of what `--wave-size`/`--agents` an operator passes.

**History:**

- **Cap was 3** originally — a conservative default chosen before any headroom
  measurement existed.
- **Raised to 5 on 2026-07-15**, with **explicit operator approval**, following
  the 2026-07-15 throughput audit. The audit found the flat `3` was the single
  biggest lever on new-PR arrival rate and was throttling sessions far below the
  actual API/resource constraint (a ~15-issue queue yielded only ~7 merges across
  a 3-hour session). Review agents are not wave-gated (they spawn per-PR), so the
  cap binds only on build lanes. `5` was chosen as a **conservative step — not the
  `10` originally requested** — precisely because the ceiling guards a real
  invariant.
- **Further raises are not free.** Any increase beyond 5 requires **re-validating
  Anthropic rate-limit headroom at the new level** (confirm the org plan sustains
  N concurrent heavy sessions without tripping requests/min or tokens/min) before
  the number moves again. Do not raise it on throughput desire alone.

Note: this is a different knob from `fleet-dispatch`'s `--repo-agents` (per-repo
build concurrency across a fleet) and its own `--wave-size` (repo-lanes per wave);
raising this team-pipeline cap does not touch those.

---

## Lean Agent Contract — why these rules exist

In a real session, agents ran 20–50 min each doing open-ended recon + the full
gate battery before surfacing a PR. This burned context re-reading everything
and produced no observable progress signal until the very end. The lean contract
keeps agents narrow, fast, and observable. The orchestrator's stall detection
(> 20 min no PR) only works if compliant agents open their draft PR early.

The **full review** — `/code-review` + `/security-review` + full test suite —
happens in the dedicated review agent (Phase 3d / `/sge:pr-review`). Decoupling
it from the build agent is what makes parallel pipeline progress possible. The
lean contract is deliberately **not** a full `/sge:sge-implement` dispatch (that
burned 20–50 min per agent), but it keeps sge-implement's one non-negotiable
gate: before building, every lane runs `/sge:governance-trace` headlessly and,
on a blocking verdict or low-confidence match, parks the issue with
`outcome: "blocked"` instead of building. Speed is bought by capping recon and
deferring the full quality battery — never by skipping governance.

---

## Duration Mode — the two former issue-swarm contradictions, fixed

Duration Mode was folded in from `/sge:issue-swarm` (#808, epic #730); that
skill is now a router stub to this mode. Two contradictions in the old
issue-swarm text are retired here:

- **Lanes run the Phase 3c Lean Agent Contract — never a full
  `/sge:sge-implement` dispatch.** Duration mode changes *when the pipeline
  stops*, not *what a lane does*. The old issue-swarm Phase 5 text that told
  lanes to drive an issue to a reviewed, green PR contradicted its own
  lean-contract invariant; the reviewed-green-PR outcome belongs to the
  Phase 3d review agents and pr-monitor, not the build lane.
- **Stale or over-budget lanes are NOT auto-requeued.** The *Stale-lane kill
  procedure* applies verbatim — kill, unlock, remove worktree, comment a
  re-scope recommendation, `failedIssues`, never requeue. The old issue-swarm
  ":286 requeued once" wording resurrected exactly what commit 879d5f6 removed
  from this file; it is retired with that stub.

Other invariants that hold in duration mode:

- The duration bound is the master stop; no run-forever mode exists.
- Never start a lane that cannot finish before the deadline (runway check).
- Never weaken a control to exit the loop — no skipped tests, no `--no-verify`,
  no loosened gate to drain the queue faster (per
  [loops §C](../../loops/SKILL.md#c-bounded-refinement-loop)).

---

## Running across sessions (recurring)

The orchestrator state (`/tmp/team-pipeline-*.json`) is **session-local and
ephemeral** — it does not survive container reclaim. For unattended runs that
must span sessions, drive the pipeline as a
[recurring loop](../../loops/SKILL.md#d-recurring--cross-session-loop): wrap the
invocation in `/loop <interval> /sge:team-pipeline …` or schedule a `send_later`
self-check-in to relaunch and resume. Because `/tmp` is a within-run cache only,
the **durable layer** that lets a fresh run resume safely is the pushed worktree
branches, their draft PRs, and the `agent-lock` GitHub labels. Phase 0.5 already
flushes unpushed worktrees on startup, which is what makes a relaunch idempotent.

---

## Per-agent core→agentMax mapping

Each implementation agent peaks at ~3 cores (type-check + tests + lint
simultaneously), so `agentMax = max(1, int(nproc x 0.80 / 3))`:

| Cores | agentMax |
|-------|----------|
| 4     | 1        |
| 8     | 2        |
| 12    | 3        |
| 16    | 4        |

**Model routing (lowest-safe tier per agent):** route each spawned agent to the
cheapest model that is safe for its task, per
[`agents/agent-registry.md`](../../../agents/agent-registry.md). Implementation
agents run at **sonnet**; review agents at **sonnet** (escalating to **opus** on
security-globbed diffs); the PR monitor's triage / CI-check / label work is
**haiku**-tier. The registry's CRITICAL escalation rule is absolute — anything
touching security/auth, DB migrations, or multi-tenant isolation runs at
**opus** regardless of how mechanical it looks.

---

## Architecture diagram

```
Claude Orchestrator (this session)
|
+-- State: /tmp/team-pipeline-state.json   <- local, ephemeral
+-- Issue locking: GitHub agent-lock label <- durable, cross-agent safe
|
+-- PR Monitor Agent [always-on, spawned first — named Task, stoppable]
|   +-- /sge:pr-monitor loop -> /sge:pr-fix as needed -> reports to state file
|
+-- Implementation Agents [0..N, resource-gated — named Tasks, stoppable]
|   +-- Slot 1: lean contract #ISSUE_A: /sge:governance-trace gate -> build -> PR (draft) -> signals done
|   +-- Slot 2: lean contract #ISSUE_B: /sge:governance-trace gate -> build -> PR (draft) -> signals done
|   +-- (slot opens) -> resource check -> spawn next or wait
|
+-- Review Agents [one per PR, spawned by orchestrator — named Tasks, stoppable]
    +-- review-<PR_A>: /sge:pr-review #PR_A -> approve or request changes -> undraft
    +-- review-<PR_B>: /sge:pr-review #PR_B -> approve or request changes -> undraft
```
