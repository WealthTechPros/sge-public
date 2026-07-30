# team-pipeline — budget model & durable token-usage persistence

Extended rationale and full mechanism behind the core SKILL.md's *Per-Task
Budget Contract* and *Durable token-usage persistence* sections. The core keeps
the operational rule and the call sites; this file keeps the *why* and the
exact helper.

---

## Per-Task Budget Contract — full rationale

> **Every Task this orchestrator spawns MUST state an explicit token-budget
> contract in its prompt.** There is no SDK-level token ceiling that can
> interrupt a running Task — the Claude Agent SDK's `Task` tool has no
> `budget` parameter and throws no `BudgetExceededError`; an earlier version
> of this skill described exactly that (~110 lines, unverified against the
> installed SDK) and it does not exist. That prose is deleted, not
> softened. A Task without a stated contract is still a runaway agent
> waiting to happen, so the contract still goes in every prompt — it is
> just enforced by the time-box, not by a throw.

### What actually stops a runaway agent

Two real mechanisms, both already implemented elsewhere in this skill:

1. **The stated contract (self-discipline, not enforcement).** Every spawned
   Task's prompt states the target ceiling plus an explicit instruction:
   *"If you estimate you are approaching this ceiling, stop expanding scope —
   commit what you have, push, open/update the draft PR, and terminate. Do not
   keep working past it."* This depends on the agent following its own
   instructions; it is advisory.
2. **Time-box kill (the actual hard stop).** The health monitor's stale-kill
   (`staleKillMinutes`, default 20m, no draft PR yet) and hard-kill (45m
   total) thresholds are wall-clock, not token-based, but they are real:
   `TaskStop "<name>"` genuinely terminates a named Task. A lane that ignores
   its stated contract and keeps burning tokens without producing a PR is
   caught here, not by a token counter. This is why the *Stoppable-Only
   Fan-Out Rule* (every spawned agent is a named `Task`) is load-bearing — it
   is the only thing that makes this stop actually work.

There is no separate "budget-exceeded" kill category. A lane either
(a) self-disciplines per its stated contract and exits normally, or
(b) does not, and is caught by the same time-box kill as any other stalled
lane — see the *Stale-lane kill procedure*, which applies uniformly.

### Session budget (harness-measured accounting)

The per-Task target bounds each **individual agent** by convention. The
optional `--session-budget <tokens>` flag (default **2 000 000**) tracks
**cumulative** spend across the run so the orchestrator can decide to stop
spawning new lanes. This is computed from **harness-MEASURED** usage — the
per-turn `TokenUsageRecord` rows that `hooks/token-meter.sh` writes to
`memory/token-usage.jsonl` (token-governance schema v2, the SGD-045 token-cost
data plane) — **not** the self-reported `tokensUsed` an agent guesses into its
completion file. The 2026-07-06 run proved the guess is fiction: lanes
under-reported by 2–4× (guessed 16k–60k, measured 86k–150k). Measured is the
only number the budget guard trusts (see #857):

```bash
# Read MEASURED cumulative spend from the token-meter producer. The reader
# sums outputTokens over every lane record (agent = "impl-<N>", set on
# dispatch — see Phase 3c) plus the orchestrator's own turns (skill =
# "team-pipeline"), scoped to this repo. Missing meter / no jq => 0, so an
# install without the hook degrades to "no spend recorded", never a crash.
. "${CLAUDE_PLUGIN_ROOT:-.}/skills/team-pipeline/lib/measured-usage.sh"
JSONL="$(git rev-parse --show-toplevel)/memory/token-usage.jsonl"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo '')"
SPENT=$(measured_session_tokens "$JSONL" "$REPO")
if [ "$SPENT" -ge "$SESSION_BUDGET" ]; then
  echo "[Budget] session budget exhausted (${SPENT}/${SESSION_BUDGET}) — stop spawning"
  # Finish in-flight agents, then Phase 6 shutdown
fi
```

When the session budget is exhausted the pipeline finishes all in-flight
agents (their stated per-Task targets still apply, unenforced) and enters
Phase 6 cleanly. Log:
`[Budget] session_budget=${SESSION_BUDGET} spent=${SPENT}` every monitor tick.

> **Why measured, not self-reported.** `tokensUsed` in the completion file is
> a streaming-counter guess the agent writes about *itself*; the 2026-07-06
> run showed it under-reports by 2–4×, so a budget built on it silently lets a
> run spend far past its cap. `token-meter.sh` instead records the actual
> Anthropic Messages-API `usage` block per assistant turn — the same number
> the harness bills — so `SPENT` reflects real consumption. Coverage caveat:
> the measured signal exists only for lanes whose dispatch set
> `SGD_AGENT_ID=impl-<N>` **and** whose token-meter hook wrote into this repo's
> `memory/token-usage.jsonl` (see *Correlation & coverage* below). Where the
> meter has not yet recorded a turn, `SPENT` is conservative (under-counts)
> rather than fictional — it is still honor-system-free accounting of what was
> actually metered, and the time-box kill remains the real backstop.

### Raising the defaults

Defaults are intentionally conservative. To raise them for a specific run:

```bash
# Raise the per-agent impl target to 400k for a complex codebase:
# state the raised number in the Task prompt's contract (document the reason).

# Raise the session budget:
/sgd:team-pipeline --session-budget 4000000
```

Never raise a budget to "fix" a stall. A stall is a scope problem; decompose
the issue instead. Budget targets are not the bottleneck for correctly-scoped
work — the time-box kill is what actually protects a run, and it is unaffected
by these numbers.

---

## Durable token-usage persistence — full mechanism

> **/tmp does not survive** — this run's wave history and staleLanes are gone
> the moment the session ends unless something outside `/tmp` records them.
> This is that something: every place this skill reads a
> `/tmp/team-pipeline-agent-<N>.json` completion file, it persists the lane's
> **harness-MEASURED** output tokens — captured from the `hooks/token-meter.sh`
> records the lane wrote into its worktree's `memory/token-usage.jsonl`
> (token-governance schema v2) — as one aggregate `TokenUsageRecord` row in the
> **main** repo's `memory/token-usage.jsonl`. The self-reported `tokensUsed` in
> the completion file is **never** the number persisted (#857); it rides only
> as the cross-check in the visible measured-vs-reported divergence line.

`RUN_ID` is set once at Phase 0 and reused for the whole session. Resolve the
rest once, the first time this helper is needed (source the measured-usage
reader so `measured_lane_tokens` / `compare_measured_vs_reported` are available
— see `skills/team-pipeline/lib/measured-usage.sh`):

```bash
. "${CLAUDE_PLUGIN_ROOT:-.}/skills/team-pipeline/lib/measured-usage.sh"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
JSONL="$(git rev-parse --show-toplevel)/memory/token-usage.jsonl"
mkdir -p "$(dirname "$JSONL")"
```

Reusable helper — call this every time a lane finishes (clean completion,
governance-blocked completion, or a stale/hard-kill), **while the lane's
worktree still exists** so its measured meter file is readable. **It is
idempotent per (lane, role):** after appending it drops a sidecar marker
(`/tmp/team-pipeline-agent-<issue>.<role>.persisted`) and refuses to append
again while the marker exists, so Phase 4 persisting a lane as it completes and
the Phase 6 sweep re-walking every completion file can never double-append the
same lane's spend into the JSONL. The marker deliberately does **not** delete
or rename the completion file — the completion files are still read for
outcome/PR, and the glob never matches `.persisted` files:

```bash
persist_lane_usage() {  # $1=issue $2=agent-role $3=lane-worktree-dir(or jsonl) $4=reported-tokens $5=timestamp
  local issue="$1" role="$2" wt="${3:-}" reported="${4:-0}" ts="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  local marker="/tmp/team-pipeline-agent-${issue}.${role}.persisted"
  [ -f "$marker" ] && return 0   # already persisted (Phase 4 or an earlier sweep) — idempotent no-op

  # Locate the lane's OWN token-meter file (worktree-local; torn down after
  # this call). Accept a dir or a direct .jsonl path; empty => none.
  local wt_jsonl=""
  case "$wt" in
    "")      wt_jsonl="" ;;
    *.jsonl) wt_jsonl="$wt" ;;
    *)       wt_jsonl="$wt/memory/token-usage.jsonl" ;;
  esac

  # MEASURED output tokens for this lane, from the meter — never the guess.
  local measured; measured="$(measured_lane_tokens "$wt_jsonl" "$role" "$REPO")"

  # If the lane's per-turn meter rows already landed in the MAIN JSONL (a
  # deployment that runs lanes in-repo, not in a torn-down worktree), they are
  # already counted — persist a 0 aggregate to avoid double-counting; else
  # import the worktree's measured total.
  local main_have; main_have="$(measured_lane_tokens "$JSONL" "$role" "$REPO")"
  local persist_tokens="$measured"
  [ "${main_have:-0}" -gt 0 ] 2>/dev/null && persist_tokens=0

  # AC3 divergence check (#857): make any regression to guessed numbers visible.
  echo "[Telemetry] lane ${role} $(compare_measured_vs_reported "$measured" "$reported")"

  jq -nc \
    --arg specId "unattributed" \
    --arg sessionId "${RUN_ID}-issue-${issue}" \
    --arg repo "$REPO" \
    --arg skill "team-pipeline" \
    --arg agent "$role" \
    --arg model "unknown" \
    --argjson outputTokens "${persist_tokens:-0}" \
    --arg timestamp "$ts" \
    '{specId:$specId, sessionId:$sessionId, repo:$repo, skill:$skill, agent:$agent,
      model:$model, inputTokens:0, outputTokens:$outputTokens, timestamp:$timestamp}' \
    >> "$JSONL" && touch "$marker"
}
```

The marker is written only **after** a successful append (`&& touch`), so a
failed append leaves the lane unmarked and a later call (or the Phase 6 sweep)
retries it. Markers live in `/tmp` beside the completion files: on a
crash/resume within the same session they prevent re-appending what was already
persisted; a genuinely fresh session gets a fresh `/tmp` — and a fresh `RUN_ID`
— so its rows are new records, not duplicates.

- **`outputTokens` is the harness-measured total**, read from the lane's
  token-meter records (`measured_lane_tokens`) — not the completion file's
  self-reported `tokensUsed`. When the meter recorded nothing for the lane
  (e.g. a lane hard-killed before its first metered turn, or an install without
  the token-meter hook), this is `0`, never the guess.
- `specId` is deliberately `"unattributed"` — a lane's pipeline-level overhead
  is not tied to one spec (the `sgd-implement` run *inside* the lane also emits
  its own per-turn records via `hooks/token-meter.sh`, tagged with the real
  `SGD_SPEC_ID`); this aggregate row makes the lane's measured spend durable in
  the main repo and attributable to `skill: "team-pipeline"`.
- `sessionId` tags both the run and the issue (`<run-id>-issue-<N>`) — additive
  tagging within the existing string field, not a schema change.
- `agent` carries the agent-role (`impl-<N>`, `review-<PR>`, `pr-monitor`) so
  `/sgd:roi-report` / `/sgd:cost-guard` can filter pipeline overhead out of
  per-spec attribution, and `measured_session_tokens` can sum lane rows.
- `model` is `"unknown"` — the aggregate collapses possibly several models'
  turns into one output-token total; honest about that gap rather than guessing.

> **Correlation & coverage (honest limits).** The measured signal is only as
> good as two wiring facts holding at runtime: (1) each lane exported
> `SGD_AGENT_ID=impl-<N>` (Phase 3c dispatch Step 0) so the meter tags its rows
> with the lane, and (2) `persist_lane_usage` ran **before** the worktree was
> removed so the worktree-local meter file was still readable. Where either
> fails, the lane's measured total is `0` and the budget under-counts (never
> over-counts, never fabricates). This is bounded to the team-pipeline
> telemetry wiring; the meter producer itself is `hooks/token-meter.sh` (#726)
> and is out of scope here. Verified via `skills/tests/measured-usage.test.sh`
> (reader + divergence check) and the static persistence guard.

### Call sites (verbatim)

- **Phase 4 step 4 / 4a** (clean or governance-blocked completion) — pass the
  lane's worktree dir so its measured meter is captured before teardown.
- **Stale-lane kill procedure** — pass the worktree dir **before** the
  `git worktree remove`, so a killed lane's measured spend is still captured;
  if the meter recorded nothing, `0` is persisted rather than a guess.
- **Phase 6 sweep** — defensive: persists **only what Phase 4 did not** (e.g. a
  crash/resume between phases left a completion file unprocessed). By then
  worktrees are gone, so there is no meter to read and the sweep persists `0`
  for those lanes (recording that the lane ran); lanes Phase 4 already persisted
  carry a `.persisted` marker and the helper no-ops on them — the sweep is a
  gap-filler, never a re-appender.
