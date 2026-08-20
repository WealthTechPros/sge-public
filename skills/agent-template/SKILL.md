---
description: Reference template and convention guide for custom orchestrators that dispatch SGE implementation lanes. Use when building a bespoke fan-out orchestrator (not /sge:team-pipeline or /sge:issue-swarm) and you need to know the correct way to batch-classify issues, inject SGE_GOVTRACE_VERDICT, and wire the governance gate into dispatched lanes.
argument-hint: ""
---

# SGE Agent Template — Custom Orchestrator Conventions

## Role

Documents the canonical conventions a **custom orchestrator** must follow when
it dispatches SGE implementation lanes — specifically the `SGE_GOVTRACE_VERDICT`
injection convention introduced by #1344 (batch front-loading the governance-trace
gate). Use this as a checklist when you are building a bespoke fan-out that is not
`/sge:team-pipeline` or `/sge:issue-swarm`.

> **Note:** `/sge:team-pipeline` and its Duration Mode (`/sge:issue-swarm`) already
> implement every convention in this document (Phase 1.5 + Phase 3c). Read this
> template when you are writing a *new* orchestrator and want a reference
> implementation to adapt.

---

## SGE_GOVTRACE_VERDICT injection convention (#1344)

### Why

Each implementation lane runs `/sge:sge-implement` (or the Lean Agent Contract
equivalent), which **must** classify the issue against SGE governance artefacts
before writing code — the mandatory Phase 0.5 governance-trace gate. Without
front-loading, every lane forks its own `/sge:governance-trace` subagent — a
~73k-token, 10–15 min cost repeated N times for an N-issue wave.

The **batch pre-classification** pattern collapses that to a single
`/sge:build-ready-audit` call over the whole wave **before** lanes start,
producing a verdict map the orchestrator injects at dispatch time. Each lane
detects `SGE_GOVTRACE_VERDICT` and skips its own fork, adopting the pre-computed
verdict instead — same gate, ~1/N of the cost.

### Shape of SGE_GOVTRACE_VERDICT

The env var (or prompt-injected field) carries compact JSON:

```json
{
  "issue": 256,
  "verdict": "MATCHES_EXISTING",
  "matchedSpec": "SPEC-088",
  "matchConfidence": "high",
  "layers": {
    "capability": { "status": "existing", "id": "CAP-04" },
    "feature":    { "status": "existing", "id": "F-EXPORT" },
    "spec":       { "status": "existing", "id": "SPEC-088" }
  }
}
```

**Required fields for structural validity** (the lane validates all of these):

| Field | Type | Required values |
|-------|------|-----------------|
| `issue` | integer | must equal the lane's issue number exactly |
| `verdict` | string | one of: `MATCHES_EXISTING` · `MATCHES_EXISTING_MODIFIED` · `NEEDS_NEW_SPEC` · `NO_SPEC_WARRANTED` · `NOT_SGE_SCOPE` · `NOT_ONBOARDED` |
| `matchConfidence` | string | one of: `high` · `medium` · `low` |

If any required field is missing, wrong type, or out of range → the lane falls
through to a per-lane fork. Never pass a verdict for the wrong issue number.

### Step-by-step: adding batch pre-classification to a custom orchestrator

**Step 1 — collect the issue list** (after dependency gate + reconcile):

```bash
# Assume QUEUE is a space-separated or newline-separated list of issue numbers
ISSUE_LIST=$(echo "$QUEUE" | tr '\n' ',' | sed 's/,$//')
```

**Step 2 — batch-classify only when ≥ 2 issues**:

```bash
GOVTRACE_MAP="{}"   # default: empty map — every lane falls through to per-lane fork

QUEUE_COUNT=$(echo "$QUEUE" | wc -w)
if [ "$QUEUE_COUNT" -ge 2 ]; then
  BATCH_RESULT=$(/sge:build-ready-audit "$ISSUE_LIST")

  # Extract governance verdicts keyed by issue number (string key)
  GOVTRACE_MAP=$(printf '%s' "$BATCH_RESULT" \
    | node -e '
        let s="";
        process.stdin.on("data",d=>s+=d).on("end",()=>{
          const results = JSON.parse(s).results || [];
          const map = {};
          for (const r of results) {
            if (r.governance && r.governance.verdict) {
              map[String(r.issue)] = r.governance;
            }
          }
          process.stdout.write(JSON.stringify(map));
        })')

  echo "[Phase 1.5] Batch-classified $QUEUE_COUNT issues"
fi
```

**Step 3 — look up and format the per-issue verdict at dispatch time**:

```bash
# When spawning impl lane for issue N:
GOVTRACE_VERDICT=$(node -e "
  const map = $(printf '%s' "$GOVTRACE_MAP");
  const g = map['$N'];
  if (g) process.stdout.write(JSON.stringify(Object.assign({issue: $N}, g)));
")
# Empty string means not in map — the lane will fork its own verdict.
```

**Step 4 — inject the verdict into the lane prompt**:

Include the following field in the Task prompt for `impl-<N>`:

```
SGE_GOVTRACE_VERDICT: ${GOVTRACE_VERDICT}
```

When `GOVTRACE_VERDICT` is empty, **omit the field or leave it blank** — the lane
must still fall through to a per-lane fork (never inject a placeholder or `null`).

---

## Lane-side guard (what the impl lane does with the injected verdict)

The impl lane (running `/sge:sge-implement` Phase 0.5 or the Lean Agent Contract)
applies this guard before forking:

```
if SGE_GOVTRACE_VERDICT is set AND non-empty:
  parse as JSON
  VALID if: verdict.issue == <lane's issue number>
        AND verdict.verdict is one of the six known strings
        AND verdict.matchConfidence is present and one of {high, medium, low}
  if VALID  → adopt; skip fork; log "reused: governance-trace not re-forked"
  else      → fall-through; dispatch per-lane fork as normal
```

**Reuse is never a bypass.** An adopted verdict enters the exact same
branch-on-`verdict` logic — a blocking verdict (`MATCHES_EXISTING_MODIFIED`,
`NOT_SGE_SCOPE`, low `matchConfidence`) pauses and surfaces to the user before
writing any code; in headless dispatch it writes `outcome:"blocked"` and
terminates without building. The orchestrator's Phase 4 branch 4a parks it for
a human decision.

**Caller-owned cortex write (SPEC-108 §2.4a, #1938).** On the `VALID → adopt;
skip fork` branch, `/sge:governance-trace` never runs, so its Step W write can
never fire — the adopting lane owns it. When it adopts the front-loaded verdict,
`create_entities` the adopted verdict with `path: front-loaded`, reinforcing the
stable `govtrace-<owner>-<repo>-<issue>` entity — fire-and-forget, never blocking
the lane on the write, skipped silently if sge-memory is unavailable. This is the
#1664 silent-write-loss defect one level up: an optimisation that skips the work
must not skip the memory of the work. Write shape + closed vocabulary:
[`cortex-write.md`](../governance-trace/references/cortex-write.md).

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
[ ] Phase 1.5: batch /sge:build-ready-audit when queue >= 2; store govtraceMap
[ ] Phase 3c: look up govtraceMap[N]; inject SGE_GOVTRACE_VERDICT in lane prompt
[ ] Lane adopts a front-loaded verdict → caller-owned cortex write, path: front-loaded (SPEC-108 §2.4a, #1938)
[ ] Stoppable-only: every spawned agent is a named Task (not remote/detached)
[ ] Per-Task budget ceiling stated in every Task prompt
[ ] Draft PR after first commit (lane Rule 2); stale-lane kill on no-PR timeout
```

---

## Related skills

- `/sge:team-pipeline` — the reference orchestrator that implements every convention here
- `/sge:issue-swarm` — router to team-pipeline's Duration Mode
- `/sge:build-ready-audit` — the batch audit skill whose #872 governance fold
  produces the verdict map consumed here
- `/sge:governance-trace` — the per-issue classifier; folded into build-ready-audit
  for batch use, or dispatched directly by lanes that have no pre-loaded verdict
- `/sge:sge-implement` — implementation lane; Phase 0.5 applies the fast-path guard
