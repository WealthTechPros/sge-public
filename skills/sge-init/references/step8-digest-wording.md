# sge-init — Step 8: digest-by-default CLAUDE.md wording

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

> **Default governance read:** load `docs/sge-digest.md` (in the target repo) — the
> generated ≤2K-token digest (Vision one-liner + non-goals, capability position, active
> ADR constraints, change-protocol steps, open spec pointers). It carries a link to every
> full artefact; **read the full document on demand** only when the task's complexity tier
> needs it (CRITICAL paths — security/auth, migrations, multi-tenant — still take the full
> read deliberately). Regenerate with `node scripts/build-sge-digest.mjs`; CI verifies
> freshness with `node scripts/build-sge-digest.mjs --check`.
