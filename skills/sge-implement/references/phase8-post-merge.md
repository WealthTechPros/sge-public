# sge-implement — Phase 8.1–8.4 post-merge steps

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

### 8.1 L6 UPDATE — close the audit chain (spec lane)

After merge, mark the spec implemented (PR + merge SHA), update its capability entry and the DAG node (never hand-edit a generator-owned `docs/sge-dag.json`), and — on `MATCHES_EXISTING_MODIFIED` — rewrite each `requirementChanges[]` clause to its `proposed` text verbatim. Commit via `/sge:commit` with `Spec: SPEC-NNN`. No-spec lane: skip. Steps: [`l6-update.md`](l6-update.md).

### 8.2 Cleanup

```bash
cd <main-repo-dir>
git pull origin main
git worktree remove "$WT"   # the ../<repo>-worktrees/issue-<N> from Step 1
```

### 8.3 Emit SkillRunRecord (mandatory — every exit path, not just success)

Append a `SkillRunRecord` JSONL line to `memory/skill-runs.jsonl` — `verdict "merged"`, `phaseReached "Phase 8"`. Fields and jq: [`skill-run-record.md`](skill-run-record.md). The governance-pause exit already emits its own record (`verdict "blocked"` from Phase 0.5) — don't double-emit.

### 8.4 Cortex distillation on exit (#731)

At the success exit, trigger distillation while lessons are fresh — don't wait for a `/sge:sge-align` sweep. Skip silently if sge-memory is unavailable.

If durable lesson surfaced (cross-issue gotcha / convention / pattern — not issue-specific cache), `create_entities` with `entityType: "pattern"|"convention"|"gotcha"` and observations naming the lesson + issue (taxonomy per `/sge:sge-align` Step 6, #731). One-off notes stay episodic; nothing durable → skip.

If this was a child issue and the next child is now unblocked, ask: "Merged. Next unblocked child is #NNN: [title]. Start it?"

> **Skipped when `SGE_GATE_OWNER=pod`.** See Phase 6.5. This phase runs only in **self-drive mode** (gate owner unset or not `pod`). In pod-gate mode, the Autopilot pod manages merge and the L6 UPDATE is deferred to the pod's own post-merge flow.
