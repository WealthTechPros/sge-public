# Reproduce-first (issue #2512)

Extracted from `SKILL.md` for the 35 KB size budget (issue #825). The operational rule (reproduce the claimed failure against current `main` before routing or writing code; a mismatch stops the run) stays in `SKILL.md` Phase 0; this file carries the procedure, the completion shape for a mismatch exit, and the worked example.

## Why (governance, 2026-09-22)

Human decision comment on #2512: "adopt as a mandatory step — sge-implement dispatches must reproduce the claimed failure against current main before writing any code." An issue body is a **dated claim, not current state** — `main` moves under it. Building the prescribed fix without first confirming the claim still holds risks: building a redundant fix for something already resolved, building the *wrong* fix for a symptom that has since changed shape, or silently trusting stale file/line references the issue cited when it was filed.

This is a general rule — it applies uniformly to both the spec lane and the no-spec lane, which is why it lives in Phase 0 (before the spec/no-spec route is even chosen), not inside the spec-only Phase 1 Entry Criteria Gate.

## Procedure

Run this before choosing a route (Phase 0's "spec or no spec?") and before any `Edit`/`Write`:

1. **Reproduce the claimed failure against current `main`.** Use the cheapest reproduction available for the claim — a failing test, a scan, a build, the exact error/log line the issue quotes. If the repo's CLAUDE.md or the issue template names a baseline command (a scan, a failing test, a build the repo already runs), use that one — the reproduce step should be a single copy-paste, not an invented new probe.
2. **Check whether the relevant paths have moved since the issue was filed.** `git log --oneline -- <paths the issue names or implies>` — a prior merged PR may have already fixed it, partially fixed it, or moved the code such that the issue's file/line references no longer point at the right place.
3. **Grep for the symptom directly**, rather than trusting the issue's file/line references. An issue written against an older commit can cite a line number that has since shifted or a function that has since been renamed or removed.
4. **Diff the actual observed output against the issue's claim.**

## Branch on the result

**Match** — the failure reproduces as claimed, on current `main`, in the way described → proceed to Phase 0's routing step (spec or no spec) as normal. Carry the reproduction evidence (the actual failing output) forward into the PR body as confirmation the fix addresses a real, current failure.

**Mismatch** — already fixed, doesn't reproduce at all, or reproduces differently than described → **stop. Do not build the prescribed fix.**

- Comment on the issue with what you actually observed vs. what it claimed — cite the command you ran, its output, and (if applicable) the PR/commit that already resolved it.
- This is a **correct, successful outcome** — a lane that catches a stale claim and declines to build a redundant or wrong fix did its job. It is not a `blocked` exit (nothing is waiting on a human decision) and not a `failed` exit (nothing went wrong) — write the completion file with `outcome: "success"`, `prNumber: null`, and a `note` describing the mismatch.

```json
{
  "issue": <N>,
  "outcome": "success",
  "prNumber": null,
  "completedAt": "<ISO>",
  "note": "Reproduce-first (#2512): issue claimed <X>; current main shows <Y> (fixed by #<prior-PR> / never reproduced / reproduces as <different-shape>). Commented on the issue; no fix built."
}
```

This mirrors the shared completion-file shape Phase 0.5 already uses for a governance-blocked exit ([`orchestration.md`](orchestration.md#headless-completion-contract-phase-05-governance-pause)) — same file, same channel, different `outcome` value because a caught stale claim is success, not a block.

## Worked example: impl-2579 (this convention, before it was written down)

In the same 2026-09-22 `/sge:team-pipeline` run that produced this issue, lane `impl-2579` was dispatched against sge#2579, which reported a missing dependency. Before writing any code, it checked current `main` against the claim and found the dependency had already been added by a prior merged PR (**#2580**). It did not build a redundant fix. It commented on the issue explaining what it found and stopped, reporting a clean `outcome: "success"` with no PR.

That is the exact behavior this file codifies as the **default opening move**, not a judgment call left to an unusually careful lane. Any dispatch that skips straight to Phase 1/2/3 without first checking the issue's claim against current `main` is the failure mode this closes — the redundant-or-wrong-fix case impl-2579 avoided by accident of good judgment, now enforced by the skill itself.

## Related recommendation: name the baseline command in the issue template

Where a repo already has a cheap baseline command — a scan, a failing test, a build — that reliably reproduces the class of failure a task template is meant for, naming it directly in the issue template (e.g. this repo's `task.yml` "Problem" field) turns the reproduce step into a single copy-paste instead of an implementer having to invent one from scratch. This repo's `.github/ISSUE_TEMPLATE/task.yml` does not yet carry that field — adding it is a template-authoring decision (what the right baseline command even is varies per issue class) best made by whoever owns that template, not mechanically inserted here. Noted as a follow-up, not implemented as part of #2512.
