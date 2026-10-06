# team-pipeline — Phase 2.5 env-health verdict actions

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

| Verdict | Action |
|---|---|
| `PASS` | proceed — spawn the wave at full `waveSize`. |
| `THROTTLE` | proceed at reduced concurrency + env-health's stagger spacing. |
| `REFUSE` | do NOT spawn. Let env-health remediate (or wait on the saturation condition), then re-run the preflight before retrying. |
