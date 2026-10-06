# Step 2 — capability, feature and spec matching detail

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

1. **Capability mapping** — which capability (however this repo's model names its L1/L2 units) owns this issue's area? Match on meaning, not just keyword overlap (an issue about "logbook entries won't save offline" maps to a capability about offline-first data entry even if it never says "capability" or "offline").
2. **Feature mapping** — *within* that capability, which feature does the issue's behaviour belong to? A capability typically has several features; get the right one, not just the right capability. Skip this sub-step entirely (and treat `feature` as `n/a` throughout) if this repo's actual model is two-layer — capability → spec directly, no separate feature entity (check Step 1's schema-tolerance note; don't force a three-layer answer onto a two-layer model).
3. **Spec/feature-file coverage** — does an existing spec (or, in a two-layer model, the feature file itself) already describe the behaviour this issue touches?

**Path-mapped surfaces override lexical matching.** Some repos pair their capability model with a deterministic path→feature map for a whole surface (e.g. the SGE repo's `docs/sgd-build/skills-map.yaml`, which maps every `skills/<name>/` to a `CAP-METHOD` feature — the model's own scope note names any such map). When the issue's affected files fall under a mapped surface, resolve capability + feature by **looking the path up in that map** — do not semantically match those files against the rest of the model. Lexical/topical overlap across such a boundary is exactly the false-positive class the map exists to prevent (an issue about a repo's own PR-review *tooling* is not governed by a product capability named "PR governance checks" — see SGE issue #694). Files *outside* any mapped surface follow the normal semantic matching above.

## No-capability-mapping judgment call

Moved verbatim from `SKILL.md` Step 4.

**No-capability-mapping judgment call (only reached from Step 2's first bullet).** When nothing in the capability model maps and there's no non-goal conflict either, decide between `NEEDS_NEW_SPEC` (a real capability gap — the model just hasn't caught up yet) and `NOT_SGE_SCOPE` (this genuinely doesn't belong to the product's mission). **Bias toward `NEEDS_NEW_SPEC`** — blocking legitimate work that just hasn't been modelled yet is more costly than asking someone to review a two-paragraph spec stub. Reserve `NOT_SGE_SCOPE` for cases with an actual non-goal conflict, or work so far outside the product's stated mission (per the Vision's problem statement) that inventing a capability for it would be absurd on its face — not merely "small" or "not yet planned."
