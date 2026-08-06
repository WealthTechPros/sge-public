# Worked example — the SGE platform's own React adoption (SPEC SGD-047 / epic #60)

The SGE platform repo ran this audit on itself and executed the resulting
roadmap as **SGD-047** (tracked in epic **#60**). It is the reference instance
of the skill's output shape — read it for flavour, not as required structure.

## What the audit found (abridged)

- **Stack:** `react` (web only). Tokens existed (Tailwind theme) but raw hex
  and px literals were sprinkled across feature components.
- **Primitive layer:** a thin `src/components/ui/` existed; most features
  re-rolled card/badge/modal markup instead of composing it.
- **Tier:** atomic maturity **L1 (Emerging)** — tokens and a primitive layer
  existed (dims 1–2 ≥ 1) but composition, catalog, and testing were Partial.

## The roadmap it produced

The slice order in Step 5 of the skill mirrors what SGD-047 executed:

1. **S0 — inventory audit**: catalogued duplicated patterns, finalised the
   primitive list, documented the layering contract.
2. **Tokens** → **Primitives** → **Catalog** → **Testing** → **Compose** —
   each landed as its own issue under epic #60.
3. **Enforce**: an ESLint `no-restricted-imports` rule barring `ui/**`
   primitives from importing data/store/router modules, wired into a
   build-failing CI job — the dimension-6 "Enforced (3)" bar.

## Why it's quarantined here

The skill body stays generic and stack-agnostic; SGD-047/#60 are artefacts of
one repo. Cite this file when a user asks "what does a finished adoption run
look like?" — never assume their repo follows the same paths or slice sizes.
