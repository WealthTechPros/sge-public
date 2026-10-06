# team-pipeline — global-blast-radius carve-outs

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

A **carve-out** PR (lockfiles, shared config, CI workflows, codegen/migrations,
or bot-authored) has global blast radius: partial test runs are **not**
evidence of green — **never consider it green until the full suite passes on
CI**, enforced by pr-monitor, the Phase 4 monitor, and the Phase 3d agent.
Detector: [`pr-monitor` Appendix A](../../pr-monitor/SKILL.md#appendix-a--global-blast-radius-carve-outs).
