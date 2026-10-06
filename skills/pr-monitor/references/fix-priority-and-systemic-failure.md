# Fix priority and systemic-failure detection

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Fix-priority rules

1. **Oldest first** — never start lane 2's fix while lane 1 is still failing.
2. **One fix agent at a time** unless lanes have genuinely independent failure types.
3. **Rerun infra before fixing code.**
4. **Rebase before fix** — behind-main PRs often go green for free after a rebase.
5. **Endemic failures** — fix once in the oldest PR, rebase the rest.

---

## Systemic-failure detection (pre-flight + each backfill)

Before assigning lanes — and whenever a wave goes red — check whether the oldest-N eligible PRs are failing **the same way**: one bug wearing many hats, not N bugs. `check_systemic_failure [N]` ([`monitor-lib.sh`](../monitor-lib.sh)) returns 0 when ≥ 67% of the oldest-N (default 3) are failing.

The 67% threshold is the trip-wire, not the diagnosis — confirm a shared root cause (same test/step/error) first. **If systemic:** dispatch `/sge:pr-fix` on the **oldest lane only**; once it merges, `gh pr update-branch` the rest (then sync each stale worktree, #1666). Never open N fix lanes for one bug.

---
