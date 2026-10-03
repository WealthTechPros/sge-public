---
description: Reference template and convention guide for custom orchestrators that dispatch SGE implementation lanes. Use when building a bespoke fan-out orchestrator (not /sge:team-pipeline or /sge:issue-swarm) and you need to know the correct way to gate dispatch on the human intake record (intake-check.sh), adopt the intake record's governance verdict, and wire the governance gate into dispatched lanes.
argument-hint: ""
---

# SGE Agent Template — Custom Orchestrator Conventions

## Role

Documents the canonical conventions a **custom orchestrator** must follow when
it dispatches SGE implementation lanes — specifically the intake gate (SPEC-126,
#2793): dispatch only issues with a valid human intake record, and let each lane
adopt the governance verdict carried in that record. Use this as a checklist when
you are building a bespoke fan-out that is not `/sge:team-pipeline` or
`/sge:issue-swarm`.

> **Note:** `/sge:team-pipeline` and its Duration Mode (`/sge:issue-swarm`) already
> implement every convention in this document (Phase 1.5 + Phase 3c). Read this
> template when you are writing a *new* orchestrator and want a reference
> implementation to adapt.

---

## Intake gate convention (SPEC-126, #2793)

### Why

Nothing is built without a human yes. `/sge:issue-intake` records that yes as a
`## SGE intake` comment posted from the approver's own login, and
`scripts/intake-check.sh <N>` verifies it mechanically (newest marker, allow-listed
human, unedited, fresh, decision `build` or `rescope`). The record also carries the
human-approved governance verdict (`govtrace`), so a lane that adopts it skips its
~73k-token governance-trace fork with provenance it can check.

The retired convention — batch-classify the wave and inject the verdict into each
lane as `SGE_GOVTRACE_VERDICT` — is removed: its shape could be checked, its
provenance could not, so the env verdict is never adopted.

### Orchestrator side: dispatch only intake-passing issues

After the dependency gate and reconcile, filter the queue exactly as
team-pipeline's [intake gate](../team-pipeline/references/mechanisms.md#intake-gate)
does: run `bash "$SGE_ROOT/scripts/intake-check.sh" <N>` (`SGE_ROOT` from
`scripts/resolve-sge-root.sh`, never a cwd fallback) per issue
from the tracking repo's checkout, keep exit 0, and report the rest as awaiting
intake. Never claim, lock or spawn a lane for an issue that fails, and never pass
a verdict in the lane prompt.

---

## Lane-side guard (what the impl lane does before any code)

The impl lane (running `/sge:sge-implement`, whose Phase −1 does this, or the Lean
Agent Contract) re-runs the check — a record can go stale between queueing and
spawning — and adopts the verdict only from it:

```
GT_DIR = mktemp -d
intake-check.sh <N> --govtrace-out "$GT_DIR/govtrace.json" > "$GT_DIR/intake.json"
  non-zero → outcome "blocked", note "intake: <FAIL reason>"; terminate, no code
file-map  = jq -r '.acMap[].refs[]' "$GT_DIR/intake.json"   (rescope → build only .scope)
if $GT_DIR/govtrace.json exists:
  fork-util.mjs register --handle-id intake-<owner>-<repo>-<N> --output-file it ...; join
  join exit 0 → adopt; skip fork; log "adopted from intake record"
  else        → dispatch per-lane fork as normal
else          → dispatch per-lane fork as normal
```

Commands: [`intake-gate.md`](../sge-implement/references/intake-gate.md).

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

**Reuse is never a bypass.** An adopted verdict enters the exact same
branch-on-`verdict` logic — a blocking verdict (`MATCHES_EXISTING_MODIFIED`,
`NOT_SGE_SCOPE`, low `matchConfidence`) pauses and surfaces to the user before
writing any code; in headless dispatch it writes `outcome:"blocked"` and
terminates without building. The orchestrator's Phase 4 branch 4a parks it for
a human decision.

**Caller-owned cortex write (SPEC-108 §2.4a, #1938).** On the `join exit 0 →
adopt; skip fork` branch, `/sge:governance-trace` never runs, so its Step W write
can never fire — the adopting lane owns it. When it adopts the intake verdict,
`create_entities` the adopted verdict with `path: intake`, reinforcing the
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
[ ] Intake gate: queue only issues whose $SGE_ROOT/scripts/intake-check.sh <N> exits 0 (SPEC-126); never claim the rest
[ ] Lane re-runs intake-check.sh before any code; file-map from the intake acMap; no verdict in the lane prompt
[ ] Lane adopts the intake verdict → caller-owned cortex write, path: intake (SPEC-108 §2.4a, #1938)
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
- `/sge:issue-swarm` — router to team-pipeline's Duration Mode
- `/sge:issue-intake` — records the human approval (and governance verdict) the intake gate checks
- `/sge:governance-trace` — the per-issue classifier, dispatched by lanes whose intake record carries no verdict
- `/sge:sge-implement` — implementation lane; Phase −1 runs the intake gate, Phase 0.5 adopts its verdict
