# Step 1 — artefact homes and schema tolerance

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

| Artefact | Typical home (confirm in `CLAUDE.md` — never hardcode) |
|---|---|
| Vision (incl. Non-goals) | `docs/vision.md` |
| Capability model | `.claude/product-context/capability-model.yaml`, or a repo-specific variant (e.g. `docs/sgd-build/capability-model.yaml`) |
| Feature specs | `docs/features/SPEC-NNN-<slug>.md`, or a repo-specific variant (e.g. `docs/specs/SPEC-NNN-<slug>.md`) — some repos use a feature-slug filename with no `SPEC-NNN` at all (e.g. `docs/features/<slug>.md` with a `feature:` front-matter key instead of `ref:`); treat that as an equally valid spec convention, not an absence of one |

**Schema tolerance.** At least three capability-model shapes and two spec-identification conventions coexist across the fleet (nested YAML domains→capabilities→features with inline `spec:` refs; YAML front-matter with `capability:`/`success_measure_moved:`; feature-slug filenames with a `feature:` label instead of a `ref: SPEC-NNN`). Read whichever this repo actually uses — do not assume the `sge-init` default schema when the repo has its own.

## NOT_ONBOARDED

**Graceful degradation — `NOT_ONBOARDED`.** If **no** Vision, capability model, or spec directory exists at all (zero governance artefacts anywhere), this repo has not adopted SGE governance yet. That is not the same as "this issue needs no spec" — it means there is nothing to trace against. Return verdict `NOT_ONBOARDED` immediately (skip Steps 2–5, but **still run [Step W](../SKILL.md#step-w-cortex-write-on-every-terminal-path-mandatory)** — it is a verdict, so it writes) with a one-line note recommending `/sge:sge-init`. **Do not** confuse this with a repo that uses a non-standard-but-real convention (feature-slug files, a differently-named capability model, etc.) — those are still governed; keep looking before concluding `NOT_ONBOARDED`.
