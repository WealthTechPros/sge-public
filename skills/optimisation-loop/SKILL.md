---
description: Use when optimising a system whose output is gated by a measurable bottleneck and each unit of effort should yield the maximum, *verified* improvement — e.g. "grow/optimise metric X", "size a data-coverage or backlog effort before doing it", "prove this intervention works". The pattern: find the REAL bottleneck (measure, don't assume the logic is at fault), build a leverage-ranked lever, PREDICT the effect, intervene against the REAL system, and verify predicted == actual so the prediction can be trusted. Produces a ranked work-list plus a closing feedback harness (the SGD-052 claim). Not for bug-fixing or feature work — this is for making an existing system's numbers move, provably.
argument-hint: "<the metric or bottleneck to optimise, e.g. 'grow the eligible class'>"
context: fork
allowed-tools: Read, Grep, Glob, Agent, Bash
---

# Optimisation Loop — measure → lever → predict → verify

A reusable loop for improving a system's output *provably*, so a small targeted
effort yields a disproportionate, **verified** lift — and you know the size of
the win before you spend the effort. It is the applied companion to
**SGD-052 (Claim-Validation Coherence)**: the loop's final step *is* a
`prediction` claim + its feedback harness.

## The trap it avoids

The instinct when a number looks wrong is to change the **logic**. Usually the
logic is correct and the output is gated by an **unmeasured input or bottleneck**
one layer down. Optimising the logic then does nothing; the effort is wasted and
the real lever is never found. Separate *"bad because the rule is wrong"* (fix
the rule) from *"bad because an input is degraded/incomplete"* (fix the input) —
they live in different layers, and only measurement tells them apart.

## The five steps

### 1. Find the REAL bottleneck — measure, don't assume
Instrument the output and walk one layer down. What *actually* determines it?
Often it is a data-coverage, throughput, or resolution gap upstream of the logic
you were about to edit. State the bottleneck as a number ("coverage is 48%"),
not a hunch.

### 2. Build a leverage-ranked lever
Do not attack the bottleneck untargeted. Rank the possible interventions by
**leverage = reach × value** (how many downstream units each unlocks × how much
each is worth). The unresolved/blocked set is almost always **skewed** — a few
items carry most of the value *and* recur across many downstream units — so a
ranked top-K captures the bulk of the prize for a fraction of the effort.
Output: a **ranked work-list**, not "resolve everything".

### 3. Predict
Compute the **counterfactual**: "intervening on the top-K moves metric X by N."
Draw the curve (cumulative lift as top-K grows) so the diminishing return is
visible and the stopping point is a decision, not an accident. This is the
`prediction` claim's statement.

### 4. Intervene against the REAL system
Apply the intervention to a controlled scenario and re-run **the real system**,
not a re-implementation of it — a second copy of the logic in your harness is
the exact divergence coherence is meant to prevent. Measure the actual outcome.

### 5. Verify predicted == actual — close the loop
Assert the measured lift equals the prediction. *This is the point.* A harness
that only proves "the intervention did something" is an open loop; one that
proves "it moved the metric by the predicted N" makes the **model trustworthy**,
so you can size every future wave before running it. Register this as an
SGD-052 `prediction` claim with its `@claim-…-closes` assertion — now the build
keeps the loop closed for you.

Then **iterate**: intervene on the next top-K, re-run, migrate/ship the
graduates, repeat. Resolution → measurement → intervention is a flywheel, not a
one-off cleanup.

## Anti-patterns

- **Wrong layer.** Editing the logic when the output is gated by an input. Step 1 exists to catch this.
- **Untargeted effort.** "Resolve/fix everything" instead of a leverage-ranked top-K. You will run out of budget before the metric moves.
- **Open loop.** Predicting a lift and never verifying it against a real run — the prediction stays a guess. Step 5 / SGD-052 Rule 2.
- **Shadow engine.** Re-implementing the system inside the harness so the "proof" validates the copy, not the system. Always drive the real thing.
- **Silent stop.** Halting the top-K at an arbitrary point with no curve. Step 3's curve makes the stop a justified decision.

## Deliverables

1. A **ranked work-list** (the leverage-sorted interventions) — runnable, read-only.
2. A **counterfactual/prediction** (the sized prize + the diminishing-return curve).
3. A **feedback harness** that seeds → runs the real system → predicts → intervenes → re-runs → asserts predicted == actual, registered as an **SGD-052** claim.

## See also

- **SGD-052** — Claim-Validation Coherence: makes the loop's prediction a governed, gated claim.
- **SGD-027** — the coherence-check family SGD-052 extends.
- **SGD-044** — measures whether SGD *itself* works; the same measurement culture, applied to the methodology rather than a product metric.
