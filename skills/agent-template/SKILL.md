---
description: Reference template for custom orchestrators that dispatch eligible issues and run fresh issue-bound governance classification before writes.
argument-hint: ""
disable-model-invocation: true
---

# SGE Agent Template — Custom Orchestrator Conventions

## Role

Documents the canonical conventions a **custom orchestrator** must follow when
it dispatches SGE implementation lanes: preserve repository dispatch labels,
readiness and dependency checks, and let each lane freshly classify its current
scope before writes. Use this as a checklist when
you are building a bespoke fan-out that is not `/sge:team-pipeline`.

> **Note:** `/sge:team-pipeline` and its Duration Mode (`--duration`) already
> implement every convention in this document (Phase 1.5 + Phase 3c). Read this
> template when you are writing a *new* orchestrator and want a reference
> implementation to adapt.

## Out of scope

- Running or dispatching lanes itself — this is a reference template, not an
  orchestrator; use `/sge:team-pipeline` or `/sge:fleet-dispatch`.
- Optional readiness analysis (that is `/sge:issue-intake`) or classifying an
  issue against governance (that is `/sge:governance-trace`).
- Implementing issues (that is `/sge:sge-implement`).

---

## Dispatch eligibility convention

### Why

Use existing dispatch labels and `/sge:build-ready-audit`, dependency and
in-flight PR checks. No human approval marker or readiness report is required.
`/sge:issue-intake` is optional AC mapping, usable unattended, not authorisation.
External writes, destructive/live actions and deployment retain explicit authority.

### Orchestrator side: dispatch eligible issues

After dependency checks and reconciliation, use team-pipeline's
[queue validation](../team-pipeline/references/mechanisms.md#queue-validation).
Keep numeric validation and deduplication. Never claim incomplete or blocked
issues, assume READY when evidence is unavailable, or pass a cached verdict in
the lane prompt. Eligible labelled issues without a marker are dispatchable.

---

## Lane-side guard (what the impl lane does before any code)

The impl lane (running `/sge:sge-implement` Phase 0.5 or the Lean Agent Contract)
rechecks current scope and independently classifies governance:

```
reconcile current ACs, dependencies and linked PRs
file-map = bounded current issue/source analysis, optional readiness refs
fresh trivial-tier inline classification OR per-lane governance-trace fork
fork-util.mjs register --issue <N> --repo <owner/repo> --output-file <fresh-result>; join
  invalid/missing verdict or issue/repo echo → blocked; no writes
  blocking verdict → existing decision process; headless blocked
```

Boundaries: [`readiness.md`](../sge-implement/references/readiness.md).
Never adopt `SGE_GOVTRACE_VERDICT` or comment-cached governance verdicts.

> **Dispatch tool for the per-lane fork — `Agent`, never `Skill(args=)`
> (issue #2452).** "Dispatch per-lane fork as normal" above names an
> outcome, not a tool call. `Skill(skill: "sge:governance-trace", args:
> "<issue-number> ...")` does **not** fork — it inlines governance-trace's
> own SKILL.md body into the caller's own context, so `args` is never
> received by anything and the nested run reports `NO_TARGET_ISSUE` even
> for a well-formed issue number. Use `Agent` instead, with the issue
> number and target repo spelled out directly in the prompt text (never
> relying on `args=` threading):
> ```
> Agent({description: "Governance-trace classify issue <N>",
>        subagent_type: "general-purpose",
>        prompt: "Invoke sge:governance-trace ... Issue number <N>, repo
>          <owner/repo> — read directly, don't rely on args= threading.
>          Verify mode (--spec SPEC-NNN) when the issue cites a spec,
>          classify mode otherwise. ..."})
> ```
> This is the same tool-selection rule every other governance-trace caller
> follows (`skills/tests/governance-trace-dispatch-tool.test.sh` checks it
> repo-wide, not just for the callers known when that guard was written) —
> a custom orchestrator built from this template must follow it too.

**Fork result contract (#2452).** A governance-trace fork's result is adoptable only if it is the Step-7 verdict JSON (a parseable object with a `verdict` string) whose `issue` equals the dispatched issue number and whose `repo` must equal the dispatched `owner/repo` (a missing `repo` echo is rejected when the handle is bound to a repo). Reject a result with no verdict JSON — a narrative report of findings, however specific (file:line citations, tool-call counts), is not a verdict — and reject a `NO_TARGET_ISSUE` refusal, a missing `issue` echo, or an issue/repo mismatch. Never adopt, forward or paraphrase a rejected result; treat it as a failed dispatch — re-fork once, and if that also fails park the lane `outcome:"blocked"`; never build on it.

**Fresh classification is never a bypass.** A validated current verdict enters the exact same
branch-on-`verdict` logic — a blocking verdict (`MATCHES_EXISTING_MODIFIED`,
`NOT_SGE_SCOPE`, low `matchConfidence`) pauses and surfaces to the user before
writing any code; in headless dispatch it writes `outcome:"blocked"` and
terminates without building. The orchestrator's Phase 4 branch 4a parks it for
a human decision.

**Caller-owned cortex write (SPEC-108 §2.4a, #1938).** On the fresh inline-trivial
classification branch, `/sge:governance-trace` never runs, so the lane owns Step W.
`create_entities` the current verdict with `path: tier-gate`, reinforcing the
stable `govtrace-<owner>-<repo>-<issue>` entity — fire-and-forget, never blocking
the lane on the write, skipped silently if sge-memory is unavailable. This is the
#1664 silent-write-loss defect one level up: an optimisation that skips the work
must not skip the memory of the work. Write shape + closed vocabulary:
[`cortex-write.md`](../governance-trace/references/cortex-write.md).

---

## SGE_UNATTENDED env propagation (#2487)

If your custom orchestrator runs unattended (`--unattended`, or
`SGE_UNATTENDED=1` already set in its own environment), export
`SGE_UNATTENDED=1` as an early step in **every** dispatched lane's prompt —
same convention as `SGE_AGENT_ID`. `hooks/design-gate.sh` and `hooks/ui-edit-tracker.sh` (SPEC-115) read
this var from their own process environment; those hooks are fresh
processes spawned per hook event for the *lane's own* session, so they never
see a var the orchestrator merely `export`ed in its own, separate session.
Without this, a lane that edits a UI file gets nudged and then blocked at
Stop with no human to produce the required design-reviewer verdict, and runs
to its hard-kill timeout instead of terminating cleanly. This does not
loosen the merge gate — `/sge:pr-review`'s design-evidence check still
requires a passing verdict for UI-touching PRs regardless of
`SGE_UNATTENDED`.

---

## Stoppable-only fan-out rule (reminder)

Every agent your custom orchestrator spawns **MUST be stoppable via `TaskStop`**.
Use a named `Task` (never `Agent(isolation:"remote")` or a detached background
`Agent`). This is a prerequisite for the batch pre-classification pattern to work
safely — the orchestrator must be able to kill a stale lane before the governance
gate's decision strands a worktree.

---

## Minimal custom orchestrator checklist

```
[ ] Reconcile worklist before building queue (${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/scripts/reconcile-worklist.mjs)
[ ] Dependency gate: drop issues with unresolved blockers
[ ] Preserve dispatch labels, build-ready-audit, numeric validation and deduplication; no marker prerequisite
[ ] Lane freshly classifies current issue scope; fork-util.mjs register/join validates issue/repo before writes
[ ] Fresh inline-trivial classification → caller-owned cortex write, path: tier-gate (SPEC-108 §2.4a, #1938)
[ ] Stoppable-only: every spawned agent is a named Task (not remote/detached)
[ ] Per-Task budget ceiling stated in every Task prompt
[ ] Draft PR after first commit (lane Rule 2); stale-lane kill on no-PR timeout
[ ] Unattended orchestrator: export SGE_UNATTENDED=1 in every dispatched lane's prompt (#2487)
[ ] Shared claim before a subagent touches a PR: ${CLAUDE_PLUGIN_ROOT}/scripts/pr-claim.sh check, then take --lane work --owner <id>; release on exit (${CLAUDE_PLUGIN_ROOT}/skills/lib/shared-claim-protocol.md)
```

**Shared claim protocol.** A subagent working an existing PR must not collide
with PR Warden or another agent. Before dispatch run
`"$SGE_ROOT/scripts/pr-claim.sh" check owner/repo#N --owner <id>`. Exit 3 means
the PR is held, so pick another. Otherwise run
`take owner/repo#N --lane work --owner <id>`, pass `<id>` to the subagent so it
can `heartbeat` on long runs, and `release … --lane work` when the lane ends.
The details, including the review handoff env, are in
[`../lib/shared-claim-protocol.md`](../lib/shared-claim-protocol.md).

---

## Related skills

- `/sge:team-pipeline` — the reference orchestrator that implements every convention here
- `/sge:team-pipeline --duration` — the time-boxed swarm (Duration Mode)
- `/sge:issue-intake` — optional readiness and AC mapping, including unattended
- `/sge:governance-trace` — fresh per-issue classifier
- `/sge:sge-implement` — implementation lane; Phase 0.5 owns fresh classification
