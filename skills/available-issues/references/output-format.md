# Output — report sample and field semantics

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Human-readable report sample

A human-readable report **and** a machine-readable block (so a caller can parse it):

```
Ready (parallel-safe): #218 #224 #231        (3 of 7 ready issues, conflict-free)
Serial groups:
  group-1: #207, #219      (both touch app/auth/** — pick one, run the other after)
  group-2: #240, #241, #245 (shared migration: orders table)
Blocked:
  #233  ← depends on #210 (open)
Orchestrator queue (sge-ready + orchestrator-only):
  #252 "governance posture: 1 control drifted"  (infra/branch-protection — not worker-safe)
Awaiting quality label (sge-ready):
  #250 "feat: add export endpoint"    (not yet quality-labelled — not dispatchable)
```

## Field semantics

`awaitingQualityLabel` is present only when the repo declares a `dispatch-label:` in `CLAUDE.md`; it is omitted (not `[]`) when no label gate is active, preserving the existing single-repo shape for consumers that do not need it. The array is informational — these issues are **not** in `parallelSafe` and are never claimed.

`orchestratorOnly` lists quality-confirmed issues excluded from the worker ready pool by the `orchestrator-only` label (always applied, label-gate or not). Like `awaitingQualityLabel` it is informational and never in `parallelSafe` — but the distinction matters: an `awaitingQualityLabel` issue is *not yet ready*, whereas an `orchestratorOnly` issue *is* ready and simply must be built by the orchestrator or a human, not an autonomous worker.

`parallelSafe` is what `/sge:team-pipeline` consumes as its work queue; it holds at most `--count` issues and is guaranteed pairwise conflict-free. The bare-number shape is **unchanged** (single-repo back-compat). `executionRepos` (Phase 2R, additive) maps issue number → its `executionRepo` **only for candidates that execute in a different repo than this run's tracking repo** — the signal `/sge:team-pipeline` / `/sge:fleet-dispatch` use to create the worktree / `agent-lock` / PR in the execution repo. An issue absent from the map executes in the tracking repo (the common case).
