# team-pipeline — Phase 6 shutdown and report

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

When queue is empty AND all agent maps are empty (or a Duration Mode terminal
condition fired — that section covers the grace-window drain before this phase in
a `--duration` run):

1. Set `prMonitorStatus = "stop"`, wait ≤ 90s for the monitor to finish its cycle.
2. Cleanup all worktrees and `agent-lock` labels: remove each lane's tree from the
   **execution** checkout it was created in (`git -C "${AGENT_EXEC_ROOT[<N>]}"
   worktree remove … --force` — a cross-repo tree lives under the execution repo,
   SPEC-057 #1024); labels come off the **tracking** issue.
3. Compute + print the summary (below), held as `$PHASE6_REPORT` for step 5.
4. **Persist token usage durably (mandatory):** a gap-filler sweep for any file
   Phase 4 didn't persist (a crash/resume can leave one unprocessed); lanes it
   handled carry a `.persisted` marker and `persist_lane_usage` no-ops on them:
   ```bash
   for f in /tmp/team-pipeline-agent-*.json; do
     [ -f "$f" ] || continue
     ISSUE=$(jq -r '.issue' "$f"); TOKENS=$(jq -r '.tokensUsed // 0' "$f"); TS=$(jq -r '.completedAt' "$f")
     persist_lane_usage "$ISSUE" "impl-${ISSUE}" "" "$TOKENS" "$TS"   # idempotent; skips marked lanes
   done
   ```
5. **Post the run report durably (mandatory).** **Default:** append
   `$PHASE6_REPORT` as a comment on the rolling "pipeline runs" tracking issue
   (find-or-create once per repo). That comment is the only durable copy; the
   hosted-backend snapshot POST was retired with the platform (#2899). Bash: [mechanisms](mechanisms.md).
6. **Emit the machine-readable exit report** — one fenced ` ```exit-report `
   block in the final message, validating against the shared
   [`exit-report`](../../exit-report/SKILL.md) contract
   ([`schema.json`](../../exit-report/schema.json)): `skill: "team-pipeline"`,
   `runId`, `duration` (s); one `outcomes[]` per worked issue (`item: "issue:<N>"`,
   `status` per exit-report's legacy-shape table — `success`/`blocked` pass
   through, `failed`/stale-killed→`failed` with the re-scope rec in `detail`);
   `stopReason`; `followUps[]` (issues filed). A parent orchestrator parses it.

Print the human-readable `$PHASE6_REPORT` (captured in step 3) with lines
`Completed` (issues → PRs), `Reviewed` (approved), `Changes` (PRs
flagged), `Failed`, `Stale-killed` (per-lane: killed-at / age / re-scope rec),
`Blocked (governance)` (per-issue note), `Duration`.
Template: [mechanisms](mechanisms.md).

`Stale-killed` is the human's action list (each needs decomposition or a file-map
before re-dispatch). `Blocked (governance)` lists issues the governance-trace gate
paused (from `governanceBlockedIssues[]`) — **not** failures or re-scope
candidates; the issue carries the gate's comment; a human re-runs
`/sge:sge-implement <n>` once resolved.
