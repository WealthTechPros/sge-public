# issue-loop — durability and idempotent re-entry

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Interrupted mid-run (container reclaim, crash, user stop)? Re-invoking `/sge:issue-loop` resumes correctly with **no state file**:

- Merged issue A is closed → `available-issues` never re-picks it.
- Mid-flight issue B left a durable trail — a pushed branch, an open PR, an `agent-lock` label — so the claim gate treats it as in-flight/claimed rather than double-claiming; reconcile or finish it via `/sge:pr-monitor` / `/sge:pr-fix`, or release the stale claim and let the loop re-pick it.
- Skips persist as `loop-skip` labels; nothing lives only in `/tmp`.
