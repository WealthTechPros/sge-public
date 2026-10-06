# Phase 4.3a–4.6 — conditional evidence gates

Moved verbatim from `SKILL.md` Phase 4 (issue #2825) to keep the SKILL.md under the skills-ci 34 KB warn line. `SKILL.md` keeps a one-line stub per gate; the full rule, severity and finding literal for each gate live here. Each gate fires only on its trigger; `governance_tier: T0` skips all of them ([`tier-scaling.md`](tier-scaling.md)).

**4.3a Adversarial evidence (#2211).** `CONTROL_BEARING=1`: dispatch mandatory, `qa_evidence: none`/`stale@*` = **BLOCKER**. [details](behavioral-verification-tier.md).

**4.3b Oracle-derivation review (#2222).** `ORACLE_BEARING=1`: apply three-question oracle-derivation lens (→ `major` on fail): [details](oracle-derivation-review.md).

**4.4 Seam-evidence gate (dual-backend surfaces — #1228, SPEC-102).** A surface with **≥2 backends** (demo/mock store + real/warehouse) needs a named, present parity/seam test; unnamed/absent → `{severity:"major", category:"traceability", finding:"dual-backend surface: no present parity/seam test"}` (advisory `minor`, no governing spec). [`seam-evidence.md`](seam-evidence.md).

**4.5 Design evidence (UI-touching PRs — #2235/#2837, SPEC-115).** A UI-file glob diff (`ui-edit-tracker.sh`'s glob) needs a `design-reviewer` PASS for the reviewed commit, or a FAIL passing the base-relative rule; missing/stale/other FAIL → `{severity:"major", category:"traceability", finding:"UI-touching PR with no passing design-reviewer verdict"}`, blocks `pass`. `SGE_UNATTENDED=1` is NOT exempt. [`design-evidence.md`](design-evidence.md).

**4.6 Invariants (#2253, SPEC-118).** `## Invariants` with no matching property test → `major`/`traceability`. [`invariants-gate.md`](invariants-gate.md).
