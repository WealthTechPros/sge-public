# Agent Registry — Lowest-Safe Model Routing

The map from **SGD agent role / task type → the lowest-safe Anthropic model
tier**. Claude Code has **no native auto-routing**: an agent runs on whatever
model its definition (or its spawn) pins. Routing is therefore achieved by
*defining each agent at the right tier* — this registry is the single source of
truth for which tier that is, so orchestration (`/sgd:team-pipeline`,
`/sgd:pr-review` specialists, `/sgd:sgd-implement`, …) sends every agent to the
cheapest model that is still safe for its task.

> **Stack-agnostic.** Routing is by *task type*, not by language or framework.
> A repo MAY pin a specific agent to a higher tier in its own
> `.claude/agents/<name>.md` (project agents override plugin agents) — that is
> the intended escalation path; this registry is the portable floor.

## Model tiers

| Tier | Model ID | Use for |
|---|---|---|
| **opus** | `claude-opus-4-8` | Planning, architecture, non-trivial refactor design, and **all** CRITICAL paths (see escalation rule). Highest reasoning, highest cost — reserve it. |
| **sonnet** | `claude-sonnet-4-6` | Implementation (Edit/Write/Bash), test authoring, security/infra review, and most non-critical multi-step work. The safe default when a task is more than mechanical but not critical. |
| **haiku** | `claude-haiku-4-5-20251001` | Trivial / mechanical tasks: lint fixes, label ops, doc typo fixes, CI status checks, issue discovery/triage, simple file lookups. Cheapest — the default floor for work with no real reasoning. |
| **fable** | *(speed-tier alias)* | Speed-sensitive tasks where latency matters more than depth (interactive status pings, fast classification). Use only when responsiveness dominates; otherwise prefer haiku for cost or sonnet for safety. |

> Model IDs are the current generation (Opus 4.8 / Sonnet 4.6 / Haiku 4.5).
> When the org bumps a generation, update the IDs in this one table — every
> consumer reads the tier name, not the raw ID.

## Routing table

Match the task to its **lowest-safe** row. When a task spans rows, route to the
**highest** tier any part of it touches.

| Task type / agent role | Tier | Why |
|---|---|---|
| Plan / architecture / system design | **opus** | Deep reasoning over trade-offs and blast radius. |
| Non-trivial refactor design (SOLID restructure, dependency untangling) | **opus** | Correctness-critical structural reasoning. |
| Feature implementation (Edit / Write / Bash code changes) | **sonnet** | Multi-step but bounded; sonnet is the safe build tier. |
| Test authoring / TDD inner loop | **sonnet** | Needs to reason about behaviour and edge cases. |
| Security / auth review (`@security-auditor`) | **opus** | CRITICAL — never below opus (see escalation). |
| Infrastructure / deployment changes | **sonnet** | Operational reasoning; escalate to opus if it touches secrets or prod data paths. |
| Code review quality pass (`@code-reviewer`) | **sonnet** | Diff-scoped reasoning; escalate to opus for security-globbed diffs. |
| Lint / formatting fixes | **haiku** | Mechanical, deterministic. |
| Label ops / issue triage / discovery | **haiku** | No code reasoning. |
| Doc typo / wording fixes | **haiku** | Trivial text edits. |
| CI status checks / watch / report | **haiku** | Read-and-report; no synthesis. |
| Speed-sensitive interactive pings | **fable** | Latency-dominated, low-depth. |

### CRITICAL escalation rule (overrides the table)

Any task that touches **security/auth, database migrations, or multi-tenant /
data-isolation boundaries** is CRITICAL and **always escalates to `opus`**,
regardless of how mechanical it looks. A "trivial" label op on an auth config,
or a "small" tweak to a migration, is still CRITICAL. Security paths **never**
run below opus.

## Target mix

Across a typical pipeline run, the registry is calibrated to land roughly:

- **≈ 80% haiku** — the bulk of orchestration work is mechanical (discovery,
  triage, CI checks, label ops).
- **≈ 15% sonnet** — the implementation and review tier.
- **≈ 5% opus** — planning and CRITICAL paths only.

This is a *cost calibration target*, not a quota: never down-route a CRITICAL or
genuinely complex task to hit the percentages. Safety and the escalation rule
always win over the mix.

## How orchestration consumes this

- **Bundled specialist agents** (`agents/code-reviewer.md`,
  `agents/security-auditor.md`) carry a `model:` in their front-matter matching
  their row above. `@code-reviewer` → `sonnet` (escalating to `opus` on
  security-globbed diffs); `@security-auditor` → `opus`, because every security
  review is a CRITICAL path under the escalation rule.
- **`/sgd:pr-review`** dispatches its Layer-2 specialists at the tier their
  agent file pins; for the native `/code-review` engine it scales *effort*
  (low → ultra) to risk, which is the same lowest-safe principle applied to a
  non-agent engine.
- **`/sgd:team-pipeline`** spawns implementation agents (sonnet) and review
  agents (sonnet/opus per escalation); its monitor/triage/discovery work is
  haiku-tier.
- **A spawn may pin a tier explicitly** when it knows the task is cheaper than
  the agent's default — e.g. dispatching a discovery-only pass on the
  `@code-reviewer` agent at haiku. The registry tells the orchestrator which
  tier is safe; the escalation rule tells it which floor it may never cross.

## Per-agent-instance identity (`instanceId`)

The tier tells you *which model* an agent runs on; the **instance ID** tells you
*which agent instance* produced a given artefact. Two concurrent agents running
the same skill at the same tier are otherwise indistinguishable in audit logs —
the instance ID is what makes any commit, telemetry event, or log line traceable
back to the exact agent that emitted it. This is the Zero-Trust **Agent Identity**
control (`docs-site/governance/zero-trust-ai-agents.md`).

### ID format

Each agent instance gets one unique ID for its whole lifetime:

```
agent-<ulid>
```

- A **ULID** (or **UUID v7**) — both are lexicographically sortable by creation
  time, so a sort of IDs is a sort by spawn order, which makes audit roll-ups
  cheap. Prefer ULID for compactness; UUID v7 is an acceptable substitute where a
  ULID library isn't available.
- The `agent-` prefix is literal and always present, so the ID is greppable in
  commit trailers, telemetry, and logs without ambiguity.

Example: `agent-01JQ8Z7K9X4M2N6P0R3T5V7W9B`.

### Generating the ID at spawn time

The ID is generated **once per agent lifetime**, at spawn, and exported into the
agent's environment as `SGD_AGENT_ID`. Every downstream consumer (the
`/sgd:commit` trailer, the SGD hooks' telemetry, log lines) reads that one
variable — they never mint their own, so a single agent always presents one
stable identity.

```bash
# At agent spawn — set once, never overwrite if already set (a sub-step that
# re-runs this must inherit the parent agent's ID, not start a new identity).
if [ -z "${SGD_AGENT_ID:-}" ]; then
  # Prefer a ULID generator if available; fall back to UUID v7, then a
  # timestamp+random ULID-shaped token so the field is never empty.
  if command -v ulid >/dev/null 2>&1; then
    export SGD_AGENT_ID="agent-$(ulid)"
  elif command -v uuidgen >/dev/null 2>&1; then
    export SGD_AGENT_ID="agent-$(uuidgen | tr 'A-Z' 'a-z')"
  else
    export SGD_AGENT_ID="agent-$(date -u +%Y%m%dT%H%M%SZ)-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
fi
```

Orchestrators (`/sgd:team-pipeline`, `/sgd:issue-swarm`, `/sgd:sgd-implement`
when it forks sub-agents) set `SGD_AGENT_ID` in the environment of each agent
they spawn. A manually-launched session inherits whatever is already exported, or
generates one on first use; if it is unset, consumers degrade gracefully (the
trailer/field is simply omitted) rather than failing.

### Per-run record

The registry keeps a per-run record linking each instance ID to what it was and
what it did, so a later auditor can answer "which agent wrote this commit, on what
model, running which skill version, against which issue?":

| Field | Source | Example |
|---|---|---|
| `instanceId` | `SGD_AGENT_ID` at spawn | `agent-01JQ8Z7K9X4M2N6P0R3T5V7W9B` |
| `tier` / `model` | the routing table above | `sonnet` / `claude-sonnet-4-6` |
| `skill` | the skill the agent is executing | `sgd-implement` |
| `pluginVersion` | `.claude-plugin/plugin.json` `version` | `4.9.0` |
| `issue` | the GitHub issue being worked | `283` |
| `spawnedAt` | ISO-8601 UTC at spawn | `2026-06-16T09:30:00Z` |

The `instanceId` is the join key: it appears in the `Agent-Id:` commit trailer
(see `/sgd:commit`), in the `agentId` field of governance telemetry emitted by
the SGD hooks, and in this record — so any one of them can be followed back to the
others. `/sgd:sgd-align` reads the `Agent-Id:` trailers on a branch's commits and
reports the set of agents that produced them.
