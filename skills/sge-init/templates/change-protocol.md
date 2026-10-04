# SGE Change Protocol

Every change in this repo follows the SGE (Specification-Governed Development)
7-step protocol, so code traces back to an approved spec and the audit trail is
complete. _Scaffolded by `/sge:sge-init` — tailor the wording to this repo._

## The 7 steps

1. **LOCATE** — find the spec(s) and capability the change serves (`docs/features/` / capability model).
2. **READ** — start from the generated digest (`docs/sge-digest.md`, the ≤2K-token default governance read), then read **on demand** the full spec, its Gherkin acceptance criteria, and dependencies whose scope the change touches. CRITICAL paths (security/auth, migrations, multi-tenant) still take the full read deliberately.
3. **IMPACT** — assess blast radius: which specs, capabilities, tests, and downstream repos are affected.
4. **PROPOSE** — write the plan (TDD slices) before code.
5. **IMPLEMENT** — build with TDD: failing test → minimum code → refactor.
6. **TEST** — full quality suite green (lint, type-check, unit/integration/contract, coherence gate).
7. **UPDATE** — keep specs, ADRs, and docs in lockstep with the code.

## Commit trailer (traceability)

Every commit must carry exactly one of these trailers — enforced by the
`commit-msg` hook (`.githooks/commit-msg`, or `.husky/commit-msg` where this
repo uses husky):

- `Spec: SPEC-NNN` (or `SGD-NNN`) — the feature spec this commit implements.
- `SGE-Override: <STEP>; <reason ≥10 chars>` — an intentional bypass, for a
  governance / infra / docs change that maps to no single feature spec.
  `STEP ∈ { LOCATE, READ, IMPACT, PROPOSE, IMPLEMENT, TEST, UPDATE, ALL }`.
  Logged for audit.

The full trailer semantics (when each applies, the one-trailer rule, never
`--no-verify`) are canonically documented in the `/sge:commit` skill — commit
through it and the right trailer is emitted automatically.

## Enforcement

- `commit-msg` hook — follows the repo's enforcement profile in
  `.sge/posture.yaml` (SPEC-128). Under `onboarding` (the default: no file or
  no `enforcement:` key) it warns and the commit continues. Under
  `enforcement: enforced` it rejects a commit with neither trailer, unless a
  dated `commit-msg` exception in `.sge/posture.yaml` covers it.
- Promotion from `onboarding` to `enforced` is one reviewed PR, made once each
  gate's graduation criterion is met. The steps are in the SGE plugin's
  `skills/sge-init/references/enforcement-profile.md` ("Promotion path").
- The SGE coherence gate in CI fails the build on blocking spec / ADR / test drift.
