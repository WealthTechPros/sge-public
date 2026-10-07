# team-pipeline — options

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

| Flag | Default | Description |
|------|---------|-------------|
| `--duration <Nm\|Nh>` | off | Duration Mode: wall-clock master stop (see that section) |
| `--agents N` | auto, capped at 3 | Max parallel impl agents (hard-clamped 15) |
| `--wave-size N` | min(agentMax, 5) | Max lanes/wave; **hard-capped at 5** |
| `--stale-kill Xm` | 20m | Kill no-draft-PR lanes after X min; → `staleLanes`, not requeued |
| `--session-budget <tokens>` | 2 000 000 | Cap cumulative output, then stop spawning |
| `--pool-size N` | agentMax x 3 | Issues to discover upfront |
| `--module <name>` / `--milestone <name>` | all | Filter by `module:` label / milestone |
| `--ci-limit N` | 25 | Max open PRs before pausing spawns |
| `--dry-run` / `--skip-flush` | off | Preview only / skip the Phase 0.5 flush |
