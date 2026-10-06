# Global-blast-radius carve-outs

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Global-Blast-Radius Carve-Outs

> **Carve-out list is defined in one place** — see
> [`skills/pr-monitor/SKILL.md` → Appendix A](../../pr-monitor/SKILL.md#appendix-a--global-blast-radius-carve-outs).
> This section describes what `pr-fix` must do when it receives or detects a
> carve-out PR; the authoritative condition table lives in that appendix.

A PR is a **carve-out** (global blast radius) when it touches dependency
manifests / lockfiles, shared config, CI workflows, codegen / schema / migrations,
or when its author is a bot such as Dependabot or Renovate. An affected-tests
run on these PRs is insufficient — transitive breakage can hide outside the
directly changed files.

**When fixing a carve-out PR, always run the full build + test suite — never
just the affected tests or only the check that CI flagged.**

Detect at triage time (Step 0) whether the PR is a carve-out using
`is_blast_radius_pr` as defined in `skills/pr-monitor/SKILL.md` Appendix A
(canonical single source — do not duplicate the function body here).

If `is_blast_radius_pr` returns true, add `CARVE_OUT=true` to your local context
and apply these rules throughout the fix loop:

1. **Pre-push quality gate (Step 6)** — run the repo's *full* quality suite
   (type-check + lint + *all* tests + build), not just the subset that was
   failing. Discover the exact full-suite commands from the repo's `CLAUDE.md`
   and `.github/workflows/`.
2. **Declaring green** — the PR is green only when the full suite passes
   end-to-end on CI, not when a single re-run of the flagged check goes green.
   A carve-out PR with one check green and others not yet run is **not green**.
3. **Exit report** — set the `carve_out: true` extension field on the fixed
   PR's outcome in the [exit report](../../exit-report/SKILL.md) so
   `/sge:pr-monitor` and `/sge:team-pipeline` know the full suite was run
   (the shared schema allows extra per-outcome fields):

   ```json
   { "item": "pr:<N>", "status": "success", "carve_out": true }
   ```

These rules do **not** change what you fix — they change what you verify before
declaring the fix complete.

---
