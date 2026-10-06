# sge-implement — Phase 7 context

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

The PR is not yet in a clean, reviewed state. `pr-reviewed` drives auto-merge (`sge-auto-merge.yml`); the old `require-pr-reviewed-label.yml` branch-protection required check was removed org-wide 2026-09-16. Drive the PR to a clean, reviewed, auto-merging state yourself — never hand review off to the user.

> **Graceful degradation:** merge is no longer label-blocked by branch protection — run the review loop the same, note this in your summary.

> **Skipped when `SGE_GATE_OWNER=pod`.** See Phase 6.5. This phase runs only in **self-drive mode** (gate owner unset or not `pod`).
