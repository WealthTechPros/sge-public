# Consumption modes

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

1. **Dispatched (headless)** — `/sge:sge-implement` Phase 0.5 invokes this as a forked subagent for every issue, in verify or classify mode as appropriate. No interactive questions; return the Step 7 JSON and let the dispatcher decide what to do with each verdict. `/sge:deep-dive` Phase 4 also dispatches this headlessly. `/sge:build-ready-audit` folds this classification into its own Step 2G (issue #872) — it dispatches this skill headlessly with `--no-comment` (plus `--spec` when the issue cites one), once per audited issue, so a build-ready gate and a governance classification come back in **one skill hop** instead of two chained commands. The fold delegates to this skill unchanged; it does not re-implement the classification.
2. **Standalone (interactive)** — a human runs it directly to check "what would happen if I ran sge-implement on this?" without committing to implementation. Same classification, same JSON, plus the audit-trail comment (Step 6) and a plain-language summary printed in chat.

Both modes run the same Steps 0–5; only Step 6 (commenting) and whether a human sees a chat summary differ.
