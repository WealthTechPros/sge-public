---
description: Use before committing to a build approach for an architecture bet — a new extraction approach, pipeline, or adapter/integration layer that could plausibly be built two different ways and whose right shape is genuinely unknown up front. Time-boxes a throwaway, ungoverned exploration with a mandatory keep/kill checkpoint before the winning approach is industrialised through the normal SGE pipeline. A judgment prompt, not a hard gate — nothing enforces this mechanically.
argument-hint: "[issue-number or one-line description of the bet]"
---

# /spike — Time-Boxed Architecture Spike

## Role
Decide, explicitly and up front, whether a piece of work is an **architecture bet** worth de-risking with a short throwaway spike before it is built for real — and if so, run that spike inside a hard time-box with a recorded keep/kill decision at the end.

## Out of scope
- Building the production implementation (the *kept* approach goes through `/sge:sge-implement` normally — this skill only covers the exploration before that)
- Enforcing the time-box mechanically (no hook kills a spike at 2 days — this is a discipline the operator applies, not a control the platform imposes)
- Sizing or splitting ordinary (non-architecture-bet) issues — use `/sge:sge-implement` Phase 2 for that

## Is this an architecture bet? (the trigger)

Ask before any code: does this issue involve a **new** extraction approach, pipeline, adapter/integration layer, or similar mechanism that could credibly be built more than one defensible way, where the *right* way is not yet known? If the shape is already established (extending an existing pattern, a straightforward CRUD slice, a bug fix) this does not apply — go straight to `/sge:sge-implement`. This is a judgment call; when in doubt, spike — a wasted 2 days is far cheaper than a wasted 9.

## The spike checklist

1. **Time-box it, ≤ 2 days, before starting.** State the box out loud (issue comment or PR description) so there is a public deadline, not an open-ended exploration.
2. **Keep it ungoverned and throwaway.** No spec citation, no full TDD rigor, no `/sge:sge-review`/`/sge:pr-review` gate, no production-shaped code review expectations. The point is speed of learning, not a mergeable PR — spike code is disposable by default; it must not land on `main` as-is even if it "basically works". Isolate it (a scratch branch/worktree), and say plainly in the branch/PR that it is a spike.
3. **Define the keep/kill bar before you start, not after.** Pick a measurable signal in advance — e.g. "must clear 90% completeness on the sample set", "must resolve the ambiguous case without a special-case per input", "must not require a third external dependency". A bar chosen after seeing the result is not a bar.
4. **At the time-box, stop and decide — explicitly, in writing (issue/PR comment):**
   - **Keep** — the approach cleared the bar. Re-implement it properly through `/sge:sge-implement` (spec if warranted, real tests, real review) — the spike itself is not the deliverable, the *validated approach* is.
   - **Kill** — it didn't clear the bar. Discard the branch, record what was learned and why it was rejected (this is the valuable output of a killed spike, not a failure), and either spike a different approach or escalate for a design decision.
   - **Extend, once, with a reason** — if the signal is genuinely inconclusive, a single explicit extension is allowed with a stated reason and a new deadline. A second extension without a decision is a kill by default — an open-ended "still exploring" is exactly the failure mode this exists to prevent.

## Why this exists (rationale)

Observed in a real engagement: roughly 9 days and ~150 PRs went into industrialising a rules/regex-based extraction approach that plateaued at 60–70% completeness, before it was abandoned in favour of a different approach (an LLM-driven script) that took 6 days and reached ~99% completeness. A 2-day time-boxed spike at the outset — cheap, throwaway, judged against a completeness bar — would plausibly have surfaced the working approach in the first week instead of the second. The cost of a spike that gets killed is bounded and small; the cost of an un-spiked bet that plateaus is not.

## Related commands

- `/sge:sge-implement` — where the *kept* approach is built for real, governed, reviewed, and merged
- `/sge:deep-dive` — for investigating an unclear issue or weighing known alternatives with a recorded decision (no code); use `/spike` instead when the only way to know which approach works is to build a small throwaway version of each
- `/sge:decompose-issue` — for splitting an oversized but already-understood issue; not for an unresolved architecture bet
- `/sge:team-pipeline`, `/sge:issue-swarm`, `/sge:fleet-dispatch` — their default lane cap exists for the same reason this skill does: an unproven approach should not be scaled out to many parallel agents before it is validated
