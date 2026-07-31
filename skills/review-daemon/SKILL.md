---
description: "Operational reference for the SGD review daemon (SPEC-090 Layer 1). Read before operating, configuring, or extending the daemon or its claim-mutex protocol."
---

# Review Daemon — Operator Reference

The **review daemon** (`services/review-daemon-poc/`) polls a fleet of repos for
open, non-draft PRs and dispatches `/sgd:pr-review --no-automerge` against eligible
candidates.  All code-host access goes through the provider-agnostic `HostPort`
(`hostport.py`) so the daemon core is decoupled from GitHub specifics.

This document covers the **claim-mutex protocol** (issue #1312) in full — the
mechanism that prevents double-review races across daemon pods, interactive
orchestrators, and sgd-implement Phase-7 lanes.

---

## Claim comment format (issue #1312)

When any actor claims a PR for review it MUST post a machine-readable comment
**alongside** the `pr-reviewing` label.  The comment identifies the owner and
declares the TTL so any other actor can determine liveness without a timeline API
call.

```
```sgd-claim-metadata
{"owner":"<agent-id>","claimedAt":"<ISO-8601-UTC>","ttl":900}
```
```

| Field | Type | Description |
|---|---|---|
| `owner` | string | The claiming agent's identity.  Review daemon: `REVIEW_DAEMON_AGENT_ID` env var or hostname.  Interactive: `SGD_AGENT_ID` env var or hostname. |
| `claimedAt` | ISO-8601 string | UTC timestamp when the claim was placed. |
| `ttl` | integer | Seconds before the claim is considered stale **if no heartbeat was posted**.  Default 900 (15 min). |

The `pr-reviewing` **label** is the real mutex — it is the only signal that `pr-labels.sh` and `list_open_reviewable_changes` use for hard exclusion.  The claim comment is enrichment metadata for TTL-based staleness decisions.

---

## TTL self-heal logic (issue #1312 AC2)

The stale-claim sweep (`list_stale_reclaimable_changes`) treats a claim as
**orphaned** (reclaimable) when **both** conditions hold:

1. `claimedAt + ttl` has elapsed (the base TTL window).
2. No `sgd-claim-heartbeat` comment was posted within the last `ttl` seconds.

A heartbeat comment (see below) posted by the daemon during a long dispatch
extends the effective window, so a review that legitimately takes > 15 minutes is
**not** reclaimed while the daemon is running.

### Heartbeat comment format

```
```sgd-claim-heartbeat
{"owner":"<agent-id>","at":"<ISO-8601-UTC>"}
```
```

The daemon posts a heartbeat comment every `CLAIM_HEARTBEAT_INTERVAL_SECONDS`
(default 600 s, configurable) for each in-flight dispatch.  The sweep looks for
any heartbeat comment within the claim's TTL window — if one exists, the claim is
still live regardless of `claimedAt`.

### Fallback (backward compat)

For PRs claimed before issue #1312 was deployed (label-only claims with no
comment), the sweep falls back to the `pr-reviewing` label's `LabeledEvent`
timestamp from the PR timeline, compared against the daemon's
`REVIEW_DAEMON_CLAIM_TTL_SECONDS` policy (default 2700 s, 45 min).

---

## Skip-on-live-claim rule (issue #1312 AC3)

Before attempting to claim a PR, any actor checks for an existing live claim
comment:

1. `pr-labels.sh start-review <PR>` calls `find_claim_comment` and tests
   `claim_comment_live`.  If a live comment is found, it exits **3** without
   applying the label or posting a new comment.

2. The daemon's `apply_review_marker` does a fresh single-PR re-read before the
   label write.  If the label is already present (placed by another actor), the
   write is skipped — claim lost.

Both checks are advisory best-effort (the label write has no compare-and-swap on
GitHub); a narrow simultaneous-claim race can still result in two agents both
believing they won.  The claim comment's `owner` field is the tiebreaker for
human investigation; the daemon's double-dispatch window is accepted PoC scope
(issue #1164 hardening).

### Two-agent simultaneous claim scenario

```
Agent A                   Agent B
  find_claim_comment → ∅    find_claim_comment → ∅   (both see no comment)
  add_label(pr-reviewing)   add_label(pr-reviewing)  (both POST, both 200)
  post_claim_comment(A)     post_claim_comment(B)    (both post comments)
  → dispatches review       → sees label already set on re-read → skips
```

In practice Agent B's pre-write `_live_marker` read will see the label placed by
Agent A (if A wins the label POST first), and B exits early.  Residual race
window: milliseconds (label read → label write gap).

---

## Draft-skip rule

The daemon **never** claims or dispatches a draft PR.  Drafts signal lane
ownership: an `sgd-implement` Phase-7 or similar pipeline is the exclusive owner
and runs its own review (issue #699, SPEC-090 §2.2).

The skip is applied at two points:
- **Poll time**: `list_open_reviewable_changes` excludes `isDraft=true` PRs.
- **Dispatch time**: `is_still_reviewable` re-reads the PR and returns `False`
  if it has become a draft since the poll snapshot.

A PR that was non-draft at poll time but converted to draft before the daemon's
claim write is caught by the `is_still_reviewable` guard in `_claim_and_dispatch`.

---

## `--force-claim` protocol

Use `--force-claim` **only** when a claim is provably orphaned and the normal
TTL-based reclaim cannot clean it up fast enough.  It bypasses all liveness
checks and takes over regardless of the claim comment's TTL.

```bash
# Interactive takeover:
pr-labels.sh start-review <PR> --force-claim

# Daemon pre-claim (pre-dispatched by the daemon's force-claim path):
# The daemon already pre-claims before dispatching; this flag is for the
# dispatched /sgd:pr-review invocation when the daemon pre-claimed first.
/sgd:pr-review <PR> --no-automerge   # prompt carries --force-claim authorisation
```

**When to use:**
- The owning agent is confirmed dead (container OOMed, host rebooted) and the TTL
  self-heal has not yet fired (claim < TTL).
- An operator needs to force a review after the daemon's stale-claim sweep missed
  the PR (e.g., comment was deleted manually, losing the claimedAt record).

**Not a substitute for debugging:** if a claim keeps needing force-claim, the root
cause (heartbeat posting failure, unexpectedly long reviews) should be fixed.

---

## Environment variables

| Variable | Default | Effect |
|---|---|---|
| `REVIEW_DAEMON_AGENT_ID` | `$(hostname)` | Owner field in claim comments posted by the daemon. Set per pod for fleet-wide identity. |
| `SGD_AGENT_ID` | `$(hostname)` | Owner field in claim comments posted by `pr-labels.sh` (interactive reviews). |
| `SGD_REVIEW_CLAIM_TTL` | `900` | Claim comment TTL in seconds (used by `pr-labels.sh`). |
| `REVIEW_DAEMON_CLAIM_TTL_SECONDS` | `2700` | Daemon's fallback reclaim TTL for label-only (pre-#1312) claims. |

---

## Claim comment lifecycle (summary)

```
start-review / apply_review_marker
  → add_label(pr-reviewing)           # label = real mutex
  → post_claim_comment(owner, ttl)    # metadata enrichment

  [review in progress]
  → post_claim_heartbeat() every 600s # extends TTL window

pass / fail / release_review_marker
  → delete_claim_comment()            # metadata cleanup
  → swap/remove labels                # label state machine
```

---

## Outage-aware dispatch (SPEC-103, issue #1341)

During a **GitHub degradation event** the daemon's box-saturation and
failure-tracking machinery would otherwise misfire — GitHub's own 503s, checkout
failures, and HTML error pages are not the box over-committing, and an
outage-era artefact re-read is unreliable, not a proven no-op. The daemon reads
the **shared outage predicate** — `is_github_degraded()` from
`services/review-daemon-poc/github_status.py` (the in-process port of
`scripts/github-status.sh`; both read GitHub Status API v2, cached ~5 min,
fail-safe to *degraded* on an unreachable API) — at **three** decision points and
switches each from *failure* to **retry-later**:

| Decision point | Healthy (`indicator == "none"`) | Degraded (`indicator != "none"`) |
|---|---|---|
| **Timed-out / failed dispatch** (AC1) | `_track_failed_dispatch` increments the per-PR no-op/quarantine counter; PR marches toward `pr-review-stalled` | `_claim_and_dispatch` releases the claim and returns `None` (retry-later). The attempt is **not** counted against the 1800 s timeout budget and the **no-op/quarantine counter is not incremented**. |
| **Cycle wall-clock timeout** (AC2) | `_AdaptiveWidth.observe(timed_out=True)` halves effective dispatch width for the backoff window | `run_once` reports the cycle as clean (`timed_out=False`); width is **held at the configured value** — no backoff armed |
| **Exit-0-no-artefact read** (#1250, AC3) | reported as a silent no-op **failure** (`ok=False`), counter increments | released and returned `None` (retry-later); the unreadable artefact is a transient read failure, not a no-op |

**Retry-later contract.** "Retry-later" means the daemon releases its
`pr-reviewing` claim and returns a `None` verdict (omitted from the cycle's
outcome map, no `report_verdict`), so the **next poll cycle re-dispatches** the PR
once GitHub recovers. Nothing is quarantined, no width is lost, no alert fires for
an infrastructure-caused blip.

**Fail-safe.** Because an unreachable status API classifies as *degraded*, a
daemon that cannot confirm GitHub is healthy errs toward retry-later — it never
quarantines a PR or halves its width on an **unconfirmed** window. A briefly
re-queued PR is strictly better than a falsely-quarantined one.

**Healthy-path parity.** When `is_github_degraded()` is false, all three points
behave byte-identically to the pre-outage-aware daemon — the predicate is the
only new branch and is inert while GitHub is operational. A dispatch that *raises*
(vs. returns not-ok) is out of scope and still counts toward quarantine (#1436).

> ⚠️ Because the predicate does live network I/O with a fail-safe-to-degraded
> contract, daemon behaviour tests that assert the **healthy** path pin
> `daemon.is_github_degraded` to `False` for determinism; the outage-path
> regressions (`daemon_outage.test.py`) pin it to `True`. Do not add un-pinned
> failure/quarantine assertions — they flake to retry-later whenever the status
> API is unreachable.

---

## Token model and throughput tuning (issue #1324)

**Poll is free. Tokens are spent per dispatch.** The daemon's poll loop uses only
the gh GraphQL API — zero model tokens per cycle. Tokens are consumed only when
`claude -p` fires for a review. Parallelism (concurrency) changes wall-clock
latency only; two workers at queue depth 1 are token-identical to one worker.
Tune `REVIEW_DAEMON_POLL_INTERVAL_SECONDS` (default 120 s) and
`REVIEW_DAEMON_CONCURRENCY` (default 2) freely — the cost driver is dispatches,
not poll frequency or worker count.

**The 2nd worker fires only at queue depth > 1.** With concurrency=2 and one PR
in the queue, `batch = candidates[:2]` yields a batch of one. No extra tokens,
no extra REST calls — same behaviour as concurrency=1 on a solo queue.

## Pre-PR review and the daemon are complementary (issue #1324)

The implement-lane's Phase-5 independent review (pre-PR, fresh-context
`/sgd:sgd-review`) is **not duplicated** by the daemon's merge-gate review — they
serve different roles and should both run:

| Layer | When | Guards against |
|-------|------|----------------|
| Phase 5 (`/sgd:sgd-review`, pre-PR) | Before the draft lands in the merge queue | Wasted daemon dispatch on a doomed PR |
| Daemon (`/sgd:pr-review`, merge-gate) | After the PR is ready | Cross-author review; gate label + auto-merge |

Never suppress Phase 5 on daemon-covered repos. Evidence: on client-onboarding#2389,
Phase 5 caught 2 CI-confirmed blockers before the daemon pod fired, preventing a
wasted dispatch at full review cost.

---

## References

- SPEC-103: outage-aware dispatch — retry-later, not failure, during GitHub degradation (issue #1341)
- SPEC-090: Layer 1 review daemon specification
- Issue #1247: original stale-claim TTL self-heal
- Issue #1281: claim-TTL self-heal origin
- Issue #1312: owner+TTL metadata on pr-reviewing (this feature)
- Issue #1324: poll interval 300→120 s, per-repo default 2 workers, token model note
- `services/review-daemon-poc/README.md`: architecture and operational runbook
- `skills/pr-review/pr-labels.sh`: label state machine implementation
