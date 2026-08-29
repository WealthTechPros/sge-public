# Step 2G dispatch — tool choice and fork-of-fork nesting (issue #2452)

Split out of `SKILL.md` to keep it under the 35 KB skill-size budget
(`skills-ci-size-budget.test.sh`) — referenced from Step 2G's dispatch bullets.

## Dispatch tool — `Agent`, never `Skill(args=)`

`Skill(skill: "sge:governance-trace", args: "<N> --no-comment")` does not fork
— it inlines the skill's own SKILL.md into the caller's context, so the issue
number is never received by any background execution. Use `Agent` with the
issue number, `--repo`/target-repo resolution, and Step 2G's mandatory
termination line spelled out in the prompt text.

## No-nested-spawning guard — the fork-of-fork case

This skill itself declares `context: fork` and, per its own docs
(`references/apply-sge-ready.md`), is normally *run as* a forked subagent.
When that is the case, the Step 2G dispatch is a **fork dispatching a further
fork** — and a forked subagent cannot itself spawn further subagents (the same
"no nested spawning" constraint `qa-audit`/`pr-review` document at their own
dispatch points). An `Agent()` call issued from inside an already-forked
execution will not produce a working second fork; it degrades to the
`DISPATCH_FAILED` path (or worse, a silent no-op), **every time**, not
intermittently.

Before attempting this dispatch, check whether you are yourself running as a
forked subagent (no reliable in-band signal exists for this today — until one
does, an orchestrator that dispatches `build-ready-audit` as a fork should
pass a **front-loaded governance verdict** per issue instead of relying on
this skill's own Step 2G to fork again from inside its fork; see
`sge-implement`'s `SGE_GOVTRACE_VERDICT` reuse path for the shape). If you are
running standalone (not yourself a fork), the `Agent()` dispatch is safe and
expected.
