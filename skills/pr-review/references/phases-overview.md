# PR Review — phases at a glance

Orientation table for the nine phases defined in `../SKILL.md`. The `Typical model` column is
transparency, not contract (scale up for release-critical, down for trivial calls). Optional
phases run only when needed; a clean read-only review goes 1 → 6 → 8.

| # | Phase | What it does | Typical model |
|---|---|---|---|
| 1 | Discovery | Resolve `$PR`, pin reviewed head, run cheap short-circuits (concurrency, delta/pass-through) before the pricier bot-signal detection, ensure issue-linkage — **staged** (#1158): Stage 0 gate reads → Stage 1 parallel reads → Stage 2 conditional body write → Stage 3 diff-risk reads, ordered by read/write set so no read-after-write on the PR body | haiku |
| 2 | Parallel agent review | Classify diff risk, claim the gate (`start-review`), scale native engine + specialist dispatch to risk/bot-signal within a budget | sonnet (opus for deep verify) |
| 3 | Quality gates | Run the repo's type/lint/test/coverage suite **concurrently** with Phase 2 | sonnet |
| 4 | Issue validation & traceability | Requirements table, SM-1 spec linkage, QA evidence | sonnet |
| 5 | Aggregate & report | Merge findings, verify blockers, build the `sgd-verdict` block | sonnet |
| 6 | Post review + resolve label gate | Inline + summary review, then `pr-labels.sh pass`/`fail` | sonnet/haiku |
| 6.5 | Direct fix (optional) | Fix safe, in-scope issues inline on the PR branch instead of just commenting | sonnet (opus for complex) |
| 7 | CI to green (optional) | If checks are red, drive them green via the `/sgd:pr-fix` loop before passing | sonnet |
| 8 | Promote & undraft | `pass $AUTOMERGE_FLAG --expect-head` (`--auto-merge` unless `--no-automerge`); auto-undraft a draft that now qualifies | haiku |
| 9 | Cleanup | Remove any worktree created for fixes | haiku |
