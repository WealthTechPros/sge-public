# Step 5: Spec-stub (and capability-model) drafting (`NEEDS_NEW_SPEC` only)

Draft **whichever layers Step 2 marked `new`** — never the spec in isolation. A `NEEDS_NEW_SPEC` verdict that only proposes a spec file, when the feature (or capability) it belongs to doesn't exist in the model either, creates exactly the orphan `/sge:sge-align` check C6 already flags — the model must move in the same step as the spec.

Draft each `new` layer **independently — never gate one layer's drafting on another layer's status**, since a two-layer model's `feature` stays `n/a` even when its `capability` is genuinely new (Step 2), and gating capability-drafting on `feature.status == "new"` would silently skip it for exactly that case:

- **If `layers.feature.status == "new"`**: draft the capability-model row for it, following this repo's actual row shape (Step 1) — e.g. the flat-record convention already used in `docs/sgd-build/capability-model.yaml`: `{ id: F-XXX, name: <feature title>, mvp: false, status: planned, spec: SPEC-NNN }`.
- **If `layers.capability.status == "new"`** (check this independently of `feature` — it applies whether `feature` is `new` or `n/a`): draft the enclosing capability (and domain, if the model requires one at that level) the same way, using this repo's actual nesting — do not invent a flatter or deeper structure than the model already uses.

Populate `suggestedCapabilityModelEdit` in the Step 7 JSON with the target file path, a one-line description of what's being added, and the exact YAML block(s) to insert for **every** layer drafted above (not just the first one found). `null` only when `capability` and `feature` are both already `existing`/`n/a` (a spec-only gap needs no model edit).

**Spec stub.** Draft a minimal real spec, not a placeholder. Follow this repo's actual front-matter convention (Step 1) — if it's the `sge-init` default:

```yaml
---
ref: SPEC-NNN                   # next free id: node "$SGE_ROOT/scripts/spec-map/next-spec-id.mjs" (counts intake reservations, sge#2951); intake reserves it
title: <feature title, derived from the issue>
capability: CAP-xx              # existing capability if one was found in Step 2/4, else the newly-drafted one above
capability_model_version: <the model's current version:>
status: draft
success_measure_moved: SM-?     # best-guess from the Vision's success measures; mark "TBD — confirm" if genuinely unclear
questions: []
---
```

Body: one paragraph of business intent (what does the user get, citing the success measure), and **at least one Gherkin scenario** derived directly from the issue's acceptance criteria (or What/Why/Scope if it has no explicit AC) — not a TODO placeholder; write the actual scenario the issue implies.

Populate `suggestedSpecStub` in the Step 7 JSON with the full markdown content and the intended file path (`docs/features/SPEC-NNN-<slug>.md`, adjusted to this repo's real convention). **Do not write either the spec file or the capability-model edit yet** — both are proposals for the caller (a human, or `sge-implement` surfacing them to one) to approve or edit together before either becomes real, so the model and the spec that cites it land in the same approval, never one without the other.
