# team-pipeline — per-task budget contract

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Every spawned Task states an explicit token-budget target in its prompt. There is
**no SDK enforcement** — the `Task` tool has no `budget` parameter and throws
nothing on overrun. What stops a runaway lane is the **time-box kill** (stale-kill
`staleKillMinutes` default 20m, no draft PR; hard-kill 45m total — Phase 4
*Stale-lane kill procedure*), which works because every agent is a named `Task`
(Stoppable-Only rule). There is **no separate "budget-exceeded" kill** — an
overrunning lane is caught by that same time-box.

State these ceilings in every Task prompt (*near the ceiling: stop
scope-expansion — commit, push, update the draft PR, terminate*).

| Task | Target ceiling (output tokens) |
|------|---------------------------------|
| `impl-<N>` (implementation) | **250 000** |
| `review-<PR>` (review) | **60 000** |
| `pr-monitor` (monitor) | **40 000** |

**Session budget** (`--session-budget`, default **2 000 000**): caps
**cumulative** output across the run, from **harness-MEASURED** token-meter usage
(`measured_session_tokens` over `memory/token-usage.jsonl` — #857), **not**
self-reported `tokensUsed` (under-reports 2–4×). On exhaustion: finish in-flight
lanes, stop spawning, enter Phase 6. Never raise a budget to "fix" a stall —
decompose instead. Full rationale + session-budget bash:
[budget-model](budget-model.md).

**GitHub API budget** — a second shared ceiling: all lanes share ONE org REST
bucket (5000/hr); fan-out that ignores it stalls every lane in lockstep (#1153).
Dispatch prompts carry the GraphQL-first / floor-check / switch-on-403 rules:
[dispatch-prompts](dispatch-prompts.md).
