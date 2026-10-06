# Related skills

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

- `/sge:available-issues` — dependency/conflict-aware build-ready discovery; runs this audit per candidate
- `/sge:team-pipeline --duration` — the autonomous duration-bounded loop; Duration Mode gates every candidate through this audit before any claim
- `/sge:decompose-issue` — split a `TOO_LARGE` issue into child issues, then re-audit the children
- `/sge:sge-preflight` — the deep per-spec entry-criteria check that runs *after* an issue is claimed (this audit is the cheap upstream gate)
- `/sge:sge-implement` — implement one issue end-to-end once it is build-ready
- `/sge:deep-dive` — when a `NOT_READY` issue needs investigation and a recorded decision rather than a quick drop
