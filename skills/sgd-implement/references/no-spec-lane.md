# No-spec lane (sgd-implement 0B)

The 0B lane detail, extracted from `SKILL.md` for the 35 KB size budget (issue #825). Reached from Phase 0.5 only via `NO_SPEC_WARRANTED`, `NOT_ONBOARDED`, or an accepted `NOT_SGD_SCOPE` override.

### 0B: No-spec lane

Reached only via `NO_SPEC_WARRANTED`, `NOT_ONBOARDED`, or an accepted `NOT_SGD_SCOPE` override — never as a default.

Parse the issue body for **What** (feature/bug/task), **Why** (business context), **Acceptance Criteria** (specific requirements), and **Scope** (layers affected). **If the issue has no acceptance criteria**, derive them from What/Why/Scope and show them for approval before any code.

Then plan briefly: identify affected layers (data model, service/logic, API/interface, async processing, frontend/UI, infrastructure — per repo CLAUDE.md) and write a phased plan with checkboxes.

**Branch taxonomy** (Phase 3, instead of `feat/sgd-<NNN>-…`): `feature/issue-<N>-…`, `fix/issue-<N>-…`, `chore/issue-<N>-…`.

**Trailer**: if the repo follows the SGD change protocol (commit-msg hook or `docs/sgd/change-protocol.md`), no-spec commits **MUST** carry `SGD-Override: <STEP>; <reason ≥10 chars>` instead of `Spec: SPEC-NNN` (or the `SCOPE-OVERRIDE:` form for an accepted `NOT_SGD_SCOPE` override). `/sgd:commit` owns the mechanics — it derives the trailer mechanically even when untold (its step 5).

The no-spec lane **skips Phase 1** (no spec to gate) and joins at Phase 2.
