# BDD Quality Rules (mandatory for all BDD wave agents)

When generating or reviewing Gherkin acceptance-criteria scenarios (spec, issue body, or feature file), every scenario MUST satisfy all five rules before the phase proceeds:

1. Never leave a `Then` vague — name the exit code / status / exact output.
2. Define units for every threshold/SLO inline.
3. Collapse repeated-shape scenarios into a `Scenario Outline` + `Examples`.
4. Anchor `Given` to observable system state, not private bug references.
5. One unhappy-path scenario per happy-path cluster, with a concrete `Then`.

Rationale, examples, and audit evidence: [`docs/sgd-build/bdd-quality-rules.md`](../../../docs/sgd-build/bdd-quality-rules.md).

## SKILL.md summary (moved from SKILL.md)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Five mandatory rules for Gherkin acceptance-criteria scenarios (spec, issue body, or feature file) — vague `Then`s, undefined units, repeated-shape scenarios, private bug references, and missing unhappy paths are all non-compliant. Full rules + rationale: [`bdd-quality-rules.md`](bdd-quality-rules.md).
