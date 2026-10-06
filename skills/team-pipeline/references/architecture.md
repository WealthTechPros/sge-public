# team-pipeline — architecture

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Orchestrator state is ephemeral (`/tmp/team-pipeline-state.json`); issue locking
is durable (GitHub `agent-lock` label). All spawned agents are **named `Task`
invocations** (never detached/remote) so `TaskStop` can terminate any — the basis
of Phase 4 stall detection and Phase 6 shutdown. Cross-session resume relies on
the pushed branches, draft PRs, and `agent-lock` labels. Diagram + detail:
[rationale](rationale.md).
