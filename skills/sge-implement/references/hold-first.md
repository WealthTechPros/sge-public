# `hold`-first PR protection (issue #2509)

Relocated here from `../SKILL.md` Phase 3/6/7.1 to keep the SKILL body within its size budget
(issue #825/#1217 — the 35 KB fatal ceiling).

## Why a label, not a prompt

`hold` is the only label the fleet's auto-merge bot (`sge-auto-merge.yml` / `auto-merge-reusable.yml`)
actually honours — it is re-checked against **live** label state, never trusted from an event payload
or a dispatch prompt. A prompt-level instruction to a review agent ("don't apply `pr-reviewed`", "don't
merge") is not equivalent: the agent's own loaded skill (`/sge:pr-review`) applies `pr-reviewed` as part
of its normal pass path, and asking it not to does not change what that code does when it reaches a
clean verdict.

Proven live on `trust-fabric#328` (sge#2508): a review agent was dispatched with an explicit brief not
to apply `pr-reviewed` and not to merge. On a clean verdict it applied `pr-reviewed` anyway, arming
auto-merge for 16 seconds before the dispatching lane caught it, removed the label, and applied `hold`.
Contained, but only because a human/lane was watching in real time — the fleet runs unattended lanes
where that is not guaranteed.

## The fix: `hold` covers the whole window, by default

1. **Phase 3** applies `hold` in the same call as `gh pr create --draft` — before any push, any review
   dispatch, any external trigger can reach the PR. Cheap to carry; the failure mode it prevents (an
   unsanctioned merge) is not.
2. **Phase 7.1** removes `hold`, and only `hold`, as its first action — immediately before dispatching
   `/sge:pr-review` in self-drive mode. Reaching Phase 7 in self-drive mode (Phase 6.5 already confirmed
   gate owner ≠ pod) is itself the decision that a real, non-advisory, merge-authoritative review should
   run now; removing `hold` at that exact point is what signals it.
3. **Pod-gate mode never removes it here.** Phase 6.5 hands off to the pod without touching any label —
   the pod inherits a held PR and manages `hold` (and `pr-reviewed`) itself. This is not a gap: a pod
   that never receives `hold` off is a pod that was never told this PR is ready, which is the safe
   default, not a stuck one.

This composes with `/sge:pr-review`'s own Stage 0 hold gate
([`hold-handling.md`](../../pr-review/references/hold-handling.md)), which treats a live `hold` label as
**authoritative** and forces advisory mode (`REVIEW_MODE=advisory`) regardless of dispatch flags or
prompt — "even a clean APPROVE must not graduate under a hold." So a review dispatched while `hold` is
still present is automatically comment-only, with no label transition, independent of what the dispatch
prompt says. Phase 7.1 removing `hold` right before dispatch is what opts a self-drive PR **into** a
graduating review — not a workaround for the absence of enforcement, a deliberate handoff to it.

## What NOT to do

Do not remove `hold` earlier than Phase 7.1 "to be safe" — every phase before it is exactly the window
this label protects. Do not add `hold` removal to Phase 6 (final commit) or Phase 6.5 (pod-gate check):
both run before self-drive mode is confirmed, and Phase 6.5's whole point is to hand off untouched when
the gate owner is a pod.
