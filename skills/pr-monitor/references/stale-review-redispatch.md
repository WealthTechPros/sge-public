# Stale-review re-dispatch (issue #2644)

Reference for `/sge:pr-monitor` — the per-cycle sweep that re-dispatches
`/sge:pr-review` when a PR's latest `sge-verdict` predates its head. Kept out of
`SKILL.md` under the 35 KB skills-ci size budget (the #1353/#1469
progressive-disclosure pattern).

## The gap

A PR is reviewed at commit A; later pushes (design fixes, base merges, a missing
changelog fragment) move its head to D. The automatic review ran once, at
creation, so the PR keeps a verdict — and often a `changes-requested` label —
describing A, even when every finding was fixed by D. `/sge:pr-review` detects a
stale verdict itself (#2294), but only when something invokes it; nothing did.

## The sweep

Each cycle, for **every open PR** (not only the lane PRs), run
`stale_review_check "$pr"` from [`monitor-lib.sh`](../monitor-lib.sh). It reads
`pr-labels.sh review-coverage` (the read-only verdict-vs-head report) and:

| `review-coverage` says | Action |
|---|---|
| `covered=false` (verdict SHA ≠ head), CI green, no claim, not draft/`hold`, under the caps | **dispatch** — prints `dispatch:<scope> head=<sha>`, returns 0; the caller runs `/sge:pr-review "$pr"` (+ `--no-automerge` under `NO_AUTOMERGE=1`) as a named Task |
| `covered=true` | `skip:covered` |
| `covered=shadow-only` (#2655) | `skip:shadow-only` — a PR Warden shadow verdict is not coverage, but this sweep does not re-dispatch over it; the NOT REVIEWED row (no merge-gate label) or a human owns it. Report it in the heartbeat. |
| `covered=unknown` (no verdict / unreadable) | `skip:coverage-unknown` — a PR with no verdict needs a *first* review (NOT REVIEWED row), not a re-review; fail closed |
| CI red / in flight / unreadable | `skip:ci-red` / `skip:ci-pending` / `skip:ci-unknown` — CODE/INFRA FAIL rows go first; re-checked next cycle |
| claim label (`pr-reviewing`/`pr-fixing`), draft, `hold` | `skip:claimed` / `skip:draft` / `skip:hold` — same eligibility rules as a lane |

`scope` is `review-coverage`'s own classification (`delta` for fewer than
`SGE_REVIEW_COVERAGE_DELTA_MAX` intervening commits, else `substantial`).
`/sge:pr-review` itself chooses delta mode whenever a prior verdict exists, so a
head that only merged base in gets the cheap delta review rather than a full one.
It is **not** skipped outright: a merge-from-base can carry conflict resolutions
that change the reviewed content.

## Labels

The monitor never edits review labels. The re-dispatched review owns them:
`pr-labels.sh pass` removes a stale `changes-requested` (#2238) when the new head
passes; `fail` keeps it and the review posts the fresh findings on the PR.

## Anti-thrash

Every dispatch is recorded **before** the review runs (so a crashed dispatch
still counts) in a per-repo, per-PR ledger under `REREVIEW_STATE`
(default `$TMPDIR/sge-prmon-rereview`):

- `REREVIEW_CAP_PER_HEAD` (default **1**) — dispatches per (PR, head). A review
  that fails to post a verdict is not retried every cycle at the same SHA; a new
  push re-arms it.
- `REREVIEW_CAP_PER_WINDOW` (default **3**) per `REREVIEW_WINDOW_MINUTES`
  (default **360**) — a PR pushed to repeatedly cannot burn a review per push.

A capped PR reports `skip:cap-per-head` / `skip:cap-per-window`; surface it in
the exit report rather than retrying.

The sweep costs one `review-coverage` call per open PR per cycle (plus a checks
read only when stale), so respect the GitHub API budget floor (#1153) before
running it on a large backlog.

Covered by `skills/tests/pr-monitor-stale-review-redispatch.test.sh`.
