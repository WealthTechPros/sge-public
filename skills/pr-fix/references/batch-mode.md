# Batch mode — `--all-prs`

Triage and fix **every** open PR in one pass, classifying upfront so no time is wasted on PRs that are already good or can't be touched.

1. **Pre-classify with one API call** (no model cost):

   ```bash
   gh pr list --state open \
     --json number,title,headRefName,mergeable,mergeStateStatus,isDraft,updatedAt,labels,statusCheckRollup --limit 500
   ```

2. **Bucket each PR:**

   | Bucket | Condition | Action |
   |---|---|---|
   | CLEAN | mergeable, all checks pass | skip — already good |
   | FAILING | mergeable, has failed checks | fix queue (priority) |
   | DIRTY | `mergeable: CONFLICTING` | conflict queue |
   | DRAFT (orphaned) | `isDraft: true` AND no `pr-reviewing`/`pr-reviewed` label AND `updatedAt` quiet ≥ `DRAFT_ORPHAN_MINUTES` (default 30) | route to `/sge:pr-review` (first pass; undrafts on a clean pass — issue #755) |
   | DRAFT | `isDraft: true` (not orphaned — labelled, or active within the window) | skip |
   | PENDING | checks still running | wait queue |
   | MERGED/CLOSED | done | skip |

3. **Process FAILING first** (highest value), then **DIRTY** (resolve conflicts, then re-enter the loop), then **re-check PENDING** once the others settle. Run each through the single-PR Loop above.
4. **Fix systemic failures once.** If the same check is broken across several PRs, fix it in the **oldest** PR and let rebase propagate — never fix N copies of one bug.
5. While one PR's CI is being watched, you can triage or start the next — the watches are the clock ([wait-for-condition loop](../../loops/SKILL.md#b-wait-for-condition-loop)).

For ongoing, unattended shepherding of a backlog (review gates, auto-merge, lane discipline), prefer `/sge:pr-monitor` — it owns the rolling-window merge-queue duty. `--all-prs` is a one-pass batch fix, not a standing monitor.
