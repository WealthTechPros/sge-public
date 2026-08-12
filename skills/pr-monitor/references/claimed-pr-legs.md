# Claimed-PR eligibility legs: stale-claim takeover & held-review stall

Reference for `/sge:pr-monitor` — the second and third legs of the eligibility
scan, both over **claimed** PRs (`fetch_claimed_prs`). The fourth leg, over
abandoned drafts, is [`stale-draft-lane.md`](stale-draft-lane.md). Extracted
from `SKILL.md` under the 35 KB skills-ci size budget (the #1353/#1469
progressive-disclosure pattern); content unchanged.

All mechanics live in [`../monitor-lib.sh`](../monitor-lib.sh) — this file
carries the judgement, the library the code.

### Stale-claim takeover (issue #396)

A `pr-reviewing` claim is a cross-session **mutex**; with no liveness check, a session killed mid-review leaves the label on **forever** and the PR becomes permanently un-mergeable. Fix: treat a claim as a **lease**.

**Definition.** A claim is **stale** only when **taken** more than `STALE_CLAIM_MINUTES` (default 30) ago, from the **most recent** claim-label `labeled` event on the PR's timeline (`claim_labeled_epoch`); inside that window it is **fresh** — honour and skip. Reading the *latest* `labeled` event (not the first) is load-bearing: a released-and-re-applied claim is a **new** event, so the clock resets and a fresh re-claim is not force-reclaimed while its live review runs (#1252). The timeline is server-side, so the age also **survives pod restarts**. No readable event → **fresh** (never reclaim on missing data).

**Mechanics** (`claim_labeled_epoch` / `is_stale_claim` / `reclaim_if_stale` in [`monitor-lib.sh`](../monitor-lib.sh), covered by `skills/tests/pr-monitor-stale-claim-takeover.test.sh`): on a stale claim, `reclaim_if_stale` **logs loudly** and reclaims via `pr-labels.sh start-review` (re-adds `pr-reviewing` owned by us, clears stale `pr-reviewed`), returning 0 to **enter the lane**; a fresh claim returns 1 (strict mutex, skip).

**Eligibility, in two passes.** Each cycle: `fetch_candidate_prs` (unclaimed) **plus** `reclaim_if_stale` over `fetch_claimed_prs`; any claimed PR that comes back stale joins the eligible set (oldest-first). A crash strands a lane for at most `STALE_CLAIM_MINUTES`, never forever. Concurrent monitors are safe: `start-review` is idempotent and its fresh `labeled` event reads fresh to the other monitor's next pass.

### Held-review stall — a fresh claim stuck on red CI (issue #1148)

The stale-claim takeover frees only a **dead** claim. A distinct failure survives it: a PR holding a **fresh** `pr-reviewing` claim that **also** has a red required check. Per `pr-review` Phase 7 a live lane should have handed it to `/sge:pr-fix`; when it doesn't, the PR sits held with no visible reason and blocks every other lane (`spec-drift` is the archetype).

So the eligibility scan has a **third leg**: over `fetch_claimed_prs`, any PR for which `held_review_stall <pr>` returns 0 (fresh claim **and** ≥1 failing required check) is a stall to break. Act:

1. **Surface it — always.** `post_stall_comment <pr>`: one idempotent (per-head-SHA) comment naming the failing check(s) via `named_failing_checks`, so a stuck "reviewing" PR announces *why*.
2. **Route it to the fix.** Reclaim with `pr-labels.sh start-review "$pr" --force-claim`, **not** plain `start-review` (issue #1206): the #699 guard exits 3 on a plain reclaim over a fresh claim, silently no-op'ing; `--force-claim` is the sanctioned override. Then classify **CODE FAIL** / **INFRA FAIL** below and dispatch `/sge:pr-fix` (it owns spec-drift resolution — the monitor never applies `spec-unchanged`).

A fresh claim with **all checks green** is a healthy review — `held_review_stall` returns 1, mutex stands, lane left alone.
