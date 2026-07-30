# Step 4.5 — Agent attribution audit (who wrote what)

Full mechanism for Step 4.5, referenced from `SKILL.md`. Read this before running Step 4.5.

Read the per-agent-instance IDs off the branch's commits so the sweep can report
which agents produced the work under audit — the Zero-Trust **Agent Identity**
control (`docs-site/governance/zero-trust-ai-agents.md`, `agents/agent-registry.md`).

Collect the `Agent-Id:` trailers from the commits on this branch (those not on the
default branch):

```bash
DEFAULT="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')"
DEFAULT="${DEFAULT:-main}"
# Per-commit: the Agent-Id trailer (or "unknown"), so commits with no attribution
# are surfaced, not silently dropped.
git log "origin/${DEFAULT}..HEAD" --format='%H%x09%(trailers:key=Agent-Id,valueonly)' \
  | awk -F'\t' '{print ($2=="" ? "unknown" : $2)}' | sort | uniq -c | sort -rn
```

Report the distinct agent IDs and their commit counts. When the per-run record in
`agents/agent-registry.md` (or an orchestrator's run log) maps an ID to its
model / skill / issue, enrich each line with that context:

```
Commits on this branch were produced by agents:
  agent-01JQ8Z7K…  12 commits  (sonnet · sgd-implement · #283)
  agent-01JQ9A2B…   3 commits  (opus · sgd-review · #283)
  unknown            1 commit   (no Agent-Id trailer — pre-#283 or human commit)
```

`unknown` is expected for human commits and any made before per-agent IDs
existed; it is reported, never treated as an error. This subsection is read-only —
it raises no drift issue, it only attributes.
