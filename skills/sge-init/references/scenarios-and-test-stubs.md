# sge-init — Scenarios and test-stub generation (#762 Phase 1)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

For **every** Gherkin acceptance criterion drafted above, also emit an explicit `##
Scenarios` section restating it as a named `Given/When/Then` block, plus a companion
test-stub file that encodes it as a **real assertion** — not a smoke test that merely
proves the code runs. Detect the repo's test stack (from the background-subagent repo
scan in Step 1, or ask if greenfield) and match its idiom; the shape is the same
regardless of language:

```markdown
## Scenarios

### S1 — <scenario name, matches its Gherkin acceptance criterion>

Given <precondition>
When <action>
Then <the concrete, checkable outcome — the actual expected value/state, not "it works">
```

```typescript
// tests/<slug>.spec.test.ts — companion to spec S1 above
test('S1 — <scenario name>', () => {
  // TODO: arrange <precondition>
  // act: <action>
  // assert the concrete outcome named in the Gherkin "Then" — e.g.:
  expect(result.total).toBe(expectedTotal); // not expect(result).toBeDefined()
});
```

**Verify the stub is actually discoverable by the repo's test runner (issue #2312)
— never just write the file and hope.** A generated stub that sits outside the
repo's own test-glob (from the Step 1 repo scan, or the repo's `jest.config`/
`pytest.ini`/equivalent) is invisible to CI: "executable specification" that
nothing ever executes is exactly the gap #2206/#2220 found. Before presenting the
draft, confirm the stub's path matches the repo's actual discovery pattern (e.g.
`**/*.test.ts`, `tests/**/*_test.py`) — if it does not, either relocate it to a
path the runner covers, or flag the mismatch explicitly in the Review Package
(Step 9) rather than silently shipping an orphaned file.

**Scenarios describing not-yet-built behaviour are `skip`-marked with a reason,
never silently included as a stub that could pass or fail depending on the test
framework's handling of an empty/TODO body.** Use the repo's idiom's skip
primitive (`test.skip('S2 — <scenario name>', () => { /* not yet built: <reason> */ })`
in Jest/Vitest, `@pytest.mark.skip(reason="not yet built: <reason>")` in pytest,
`pending` in RSpec, or the closest equivalent) so the ratio of executed-to-skipped
scenarios is an honest, publishable coverage figure per spec (per #2220's own ask)
— a scenario is only ever a bare unskipped stub once real implementation work on
it has actually started.

**Same honesty rule as the `## Validation` stub:** when the spec's real expected
values aren't yet known from the interview, generate the stub with an explicit `//
TODO: fill in the real expected value from <source>` comment rather than inventing one
— a stub asserting a fabricated number is worse than an openly-unfinished stub, because
it looks covered and isn't (this is exactly the gap SGE#762 exists to close: a test
tagged with a scenario's name that only asserts "page renders" while the spec's real
business rule goes untested). The human fills in the real assertion before the spec's
status moves to `implemented`. Run `/sge:spec-validate` before that status change: it
evaluates the declared `## Validation` invariants against their fixtures, so a stub left
unfinished is caught by the check, not only by review. (The CI lint that used to hard-fail
this, sge#762, went with the hosted platform in #2899.)

Every spec **must** open with this front-matter — these are the machine-readable cascade
citation keys `/sge:sge-align` check C7 reads, so seeded repos pass the sweep from day one:

```yaml
---
ref: SPEC-001                  # stable spec ID, sequential
title: <feature title>
capability: CAP-03             # the L1-model capability this spec serves
capability_model_version: 1.0.0  # model version the spec was drafted against
status: draft                  # draft | approved | implemented | superseded
success_measure_moved: SM-2    # the Vision success-measure ID this feature moves
questions: [QD-01, QD-04]      # open QD-NN refs, [] when none
---
```

When the subagents return, **schema-validate every draft's front-matter** (all seven keys
present; `capability`, `success_measure_moved`, and `questions[]` resolve to real IDs in
the sibling drafts) — repair or re-dispatch any that fail — then present **all drafts
together** for one combined user review, not one-by-one.
