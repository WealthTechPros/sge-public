# Oracle-derivation review lens — test oracle / domain invariant changes (issue #2222)

**Reading the diff is not enough when the diff defines what "correct" means.** `DIFF_RISK` and the adversarial tier (`CONTROL_BEARING`) both verify that controls work and code is correct — but they verify *against the spec*. If the spec's own acceptance criterion or test oracle was derived by the same AI session that drafted the spec, a second AI session verifying implementation against that spec is still just checking two AI-derived artefacts for internal consistency, not whether the oracle itself is true. This lens operates one layer upstream: **invariant-vs-truth**, not implementation-vs-invariant.

Confirmed in practice: adviser-mcp ADR-0008 added this as a control after observing that "AI checks its own AI-derived work" is a structural risk whenever specs and tests are substantially AI-drafted — not specific to any one repo.

```bash
ORACLE_BEARING=$(rl_diff_oracle_bearing "$PR")   # 1|0, issue #2222
```

**`ORACLE_BEARING=1`** fires when the diff touches a path that constitutes a test oracle, domain invariant, or fixture-generation rule (snapshot file, fixture directory, file named `*oracle*`/`*invariant*`, etc.). Like `CONTROL_BEARING`, this is a mixed-diff trigger — one oracle-bearing file among many unrelated ones still fires.

This lens is **advisory with a major threshold**, not a hard blocker: unlike the adversarial tier where reading the diff literally cannot substitute for executing the control, an oracle-derivation review CAN succeed inline (a reviewer session that didn't draft the spec can answer the three questions directly). It becomes a `major` finding only when the questions cannot be answered or the answers indicate derivation-circularity.

## The three questions (Phase 4.3b)

When `ORACLE_BEARING=1`, apply the oracle-derivation lens:

**Q1 — Derivation from rule, not sample data.** Does this invariant/oracle/fixture follow from stated spec, ADR, or regulatory text — not from sample data the drafting session happened to observe? If the "expected value" was derived by inspecting real data and assuming the observed pattern is the governing rule, flag it: `{severity:"major", category:"traceability", finding:"oracle derived from observed sample data rather than stated governing rule — cite the spec/ADR text the invariant follows from"}`.

**Q2 — Adversarial construction.** Can the reviewer construct a case where this invariant is satisfied by *incorrect* output (the invariant passes, but the actual domain rule is violated)? If yes: `{severity:"major", category:"correctness", finding:"oracle admits incorrect output — <constructed counterexample>"}`.

**Q3 — Derivation independence.** Was this invariant/oracle derived by a session different from the one that drafted the spec it supports? (This is a different independence axis from reviewer-identity independence in `#2219` — it is about the reasoning session that produced the oracle, not the identity reviewing code.) If the same session both drafted the spec and derived the oracle, note it as `{severity:"minor", category:"traceability", finding:"oracle derivation not independently reviewed — same session authored both spec and invariant (adviser-mcp ADR-0008 pattern)"}`.

## What "applies" means in practice

The lens applies to changes that **define** a new oracle, invariant, or fixture rule — not to changes that merely consume an existing one. Heuristics:
- A new `.snap` file or added entries in an existing snapshot → applies.
- A new fixture file or additions to a fixture directory → applies.
- A changed constant named `expected*`/`oracle*`/`invariant*` in a test → applies.
- A test that calls an existing fixture but adds no new expectations → does NOT apply (consuming, not defining).

When in doubt, apply the lens — a false positive costs one extra review question; a false negative misses the structural assurance gap.

## Relationship to the adversarial tier (#2211)

These two lenses are **independent and composable**. A PR can be `CONTROL_BEARING=1` and `ORACLE_BEARING=1` simultaneously (e.g. a CI check script whose acceptance tests include snapshot expectations). Both lenses apply independently; record both fields in the verdict.

`CONTROL_BEARING` asks: *does the control still work at runtime?*
`ORACLE_BEARING` asks: *was the thing we're checking against correctly derived?*

## Verdict field

Record `oracle_bearing: true | false` in the `sge-verdict` block. Set `true` when `rl_diff_oracle_bearing` returns 1 (the lens was triggered), `false` otherwise.
