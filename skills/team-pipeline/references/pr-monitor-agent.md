# team-pipeline — Phase 2 PR monitor agent

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Before spawning any implementation agent, start the PR monitor as a **named
Task** (stoppable-only). It runs `/sge:pr-monitor` as a **bounded pass**, never
an unbounded poller (#2914): the pass ends on pr-monitor's own no-progress stop
(`IDLE_LIMIT`), when every lane is empty, or when `prMonitorStatus == "stop"`,
whichever comes first. If new lane PRs open after a pass has ended, the
orchestrator may start one fresh bounded pass at the next wave boundary; it
never keeps a monitor alive across the whole session. On a daemon-covered repo
the monitor never dispatches `/sge:pr-review` (PR Warden reviews) and skips any
PR whose claim `scripts/pr-claim.sh check` reports as held. Its prompt MUST state:
the 40 000-token budget target; the bounded-pass rule; append one JSON line per
action to `/tmp/team-pipeline-prmonitor.log`; at each cycle end read
`/tmp/team-pipeline-state.json` and exit after the cycle if
`prMonitorStatus == "stop"`; do NOT implement issues. The name `"pr-monitor"`
lets `TaskStop "pr-monitor"` work in Phase 6. Full prompt: [dispatch-prompts](dispatch-prompts.md).
Set `prMonitorStatus = "running"`.
