# Pre-merge verification checklist (Phase 8)

Every box ticked before `pr-reviewed`:

- [ ] Full diff read; requirements table (4.1) has no unmet `❌`.
- [ ] Security findings and bugs/logic errors: none, or all fixed inline (Phase 6.5).
- [ ] Type check, lint (zero warnings), tests: green on the promoted head.
- [ ] CI: all required checks GREEN (Phase 7); PR **MERGEABLE**.
- [ ] Every unfixed finding has an inline/summary comment; no leftover dead code / debug lines.
- [ ] Phase 5 *Verify against head* checks 1–5 all pass (head re-pinned; every claimed fix in the diff; reviewers attested; no `REQUEST_CHANGES`; threads resolved).
- [ ] Every declared follow-up references a tracking issue (#859) — else `pr-labels.sh pass` refuses (exit 6).
