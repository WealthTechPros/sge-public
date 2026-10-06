# The `orchestrator-only` exclusion

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

A `dispatch-label` says an issue's build quality is confirmed. It does **not** say an autonomous worker can safely build it. Some quality-confirmed issues are structurally out of a worker's reach: changes to infrastructure-as-code, CI workflows, branch protection, Pulumi/cloud state, live-host operations, or secrets provisioning — surfaces where an unattended agent must never act, either because the change is a control the swarm depends on or because applying it is a guarded human/orchestrator step.

The **`orchestrator-only`** label encodes exactly that bit. It is orthogonal to the quality label: an issue may carry *both* `sge-ready` and `orchestrator-only` — meaning "ready, but the orchestrator (or a human), not a worker, builds it." Discovery **always** excludes `orchestrator-only` from the worker ready pool, regardless of whether a `dispatch-label` is declared, and surfaces those issues in a separate "orchestrator queue" report so they are visible, not silently dropped.

## Orchestrator queue query

```bash
# Orchestrator queue — quality-confirmed but worker-excluded work, surfaced so
# it is visible rather than silently dropped from the ready pool. When a
# dispatch label is declared, scope to it (ready AND orchestrator-only);
# otherwise report every orchestrator-only issue. The orchestrator / a human
# picks these up; a worker never does.
if [ -n "$DISPATCH_LABEL" ]; then
  ORCH_QUEUE=$("$IR" list --state open --limit 100 --label "$DISPATCH_LABEL" \
    | jq '[.[] | select(
      ([.labels[].name] | index("orchestrator-only")) and
      ([.labels[].name] | index("agent-lock") | not)
    ) | {number, title}]')
else
  ORCH_QUEUE=$("$IR" list --state open --limit 100 --label orchestrator-only \
    | jq '[.[] | select(
      ([.labels[].name] | index("agent-lock") | not)
    ) | {number, title}]')
fi
```
