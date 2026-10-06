# Stacked-PR detection

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Stacked-PR detection & merge-order recommendation (#2296)

**At lane-assignment and each backfill,** scan the candidate set for stacked PRs — where one PR's `baseRefName` equals another open PR's `headRefName`. Before acting on any lane in a stack, emit a merge-order recommendation with reasoning (which PR must land first and why). Flag **partial-merge hazards** (merging PR A alone leaves a governance artefact inconsistent with PR B's correction); for any PR in the queue that carries a merge commit, check for silent reversions per AC3. Full detection rules and the merge-order algorithm: [`../lib/stacked-pr-hazards.md`](../../lib/stacked-pr-hazards.md).

---
