# Step 0 — typical layer artefact homes

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

| Layer | Typical home (confirm in `CLAUDE.md`) |
|---|---|
| L0 Vision | `docs/vision.md` |
| L1 Capability model | `.claude/product-context/capability-model.yaml` |
| L2 Design System | probed via `/sge:atomic-audit` (C10), not a file lookup |
| L3 Feature specs | `docs/features/*.md` — front-matter `ref`, `capability`, `status`, `success_measure_moved`, `questions[]` |
| Acceptance criteria | Gherkin `Given/When/Then` inside each spec (or `*.feature`) |
| L4 ADRs | `docs/decisions/*.md` — front-matter `vision_element_protected` |
| Tests / Code (spine) | `tests/**` / `src/**` keyed to a capability/spec |
| Stakeholder questions | the `QD-NN` registry referenced by specs |
| Fleet manifest (C9 / fleet mode) | `docs/sge/fleet.yaml` — `repos: [{name: <org>/<repo>, contracts: [<paths>]}]` |

Note the capability model's *internal* L1→L2→L3 taxonomy is distinct from the governance layer numbers above — a "capability" is an L1 artefact regardless of its depth in that tree. A missing layer is the cascade's first gap — report it **once** ("layer absent") and move on; never crash on a missing layer.
