# Readiness analysis is optional, not authorisation

`/sge:issue-intake` maps acceptance criteria and recommends a bounded scope.
It may run unattended. No approval marker, approver configuration or timed
reapproval is required for build or dispatch.

An eligible issue carrying the repository's dispatch label may be dispatched
without a readiness report. Preserve source-owned `/sge:build-ready-audit`,
dependency checks, in-flight PR reconciliation and all existing selection
criteria. Incomplete acceptance criteria, unknown blockers and unresolved
decisions remain paused; never substitute an always-READY fallback.

After a merged partial slice, re-evaluate the remaining acceptance criteria
against current source. Do not request human re-intake or rebuild completed ACs.

Phase 0.5 freshly classifies the current issue scope (the existing trivial-tier
inline classification is permitted). Never adopt `SGE_GOVTRACE_VERDICT` or
comment-cached verdicts. For a fork, register and join via `fork-util.mjs`,
binding the issue and repository; validate its verdict and echoes before writes.
Blocking spec changes and non-goal decisions still require the existing decision
process. Review, secrets, TDD and claimed worktree controls are unchanged.

Readiness does not authorise external writes, automatically change state,
grant access or permit destructive, live or deployment actions. Those require
their normal explicit authority.
