# TTL self-heal logic (issue #1312 AC2)

Moved out of `SKILL.md` (35 KB skill size budget); content unchanged.

The stale-claim sweep (`list_stale_reclaimable_changes`) treats a claim as
**orphaned** (reclaimable) when **both** conditions hold:

1. `claimedAt + ttl` has elapsed (the base TTL window).
2. No **qualifying** `sge-claim-heartbeat` comment was posted within the last
   `ttl` seconds (qualifying rules below).

A heartbeat comment (see below) posted by the daemon during a long dispatch
extends the effective window, so a review that legitimately takes > 15 minutes is
**not** reclaimed while the daemon is running.

### What makes a heartbeat qualify (issues #2229, #2246)

Claim and heartbeat comment bodies are **untrusted data** — the fences are
public and any PR commenter can post one. Four rules bound what they can do:

| Rule | Effect |
| --- | --- |
| **Owner-bound** | Only a heartbeat whose `owner` matches the claim's `owner` counts. Un-bound, any commenter's heartbeat could keep *any* claim alive. |
| **Claim-ordered** | Only a heartbeat posted at/after the claim's `claimedAt` counts, so a leftover heartbeat from a prior claim can't resurrect a later one. |
| **Absolute ceiling** | Past `claimedAt + CLAIM_MAX_LIFETIME_SECONDS` (default 14400 s / 4 h) **no** heartbeat keeps the claim alive — a wedged or malicious heartbeat loop cannot hold the mutex forever. Bash parity: `SGE_REVIEW_CLAIM_MAX_LIFETIME`. The ceiling also clamps an inflated `ttl`, so the TTL check alone cannot outlive it either. |
| **Author-authenticated** | The claim comment and each heartbeat must be *posted by* the daemon, not merely *claim to be* it. Owner-binding alone is spoofable, because the owner string is plainly visible in the claim comment: a forged *later* claim naming a different owner would otherwise displace the genuine one, stop its real heartbeats matching, and hand an in-flight review's mutex to the forger. Anchors below. |

Unlike an `sge-verdict` block — which a human OWNER may legitimately post by
hand — a claim or heartbeat has exactly **one** legitimate author. So the anchor
is *identity*, never author association:

* `REVIEW_DAEMON_TRUSTED_VERDICT_AUTHORS` when the operator pins one;
* the daemon's own resolved posting login;
* `APP_ACTOR_LOGIN` (`REVIEW_DAEMON_APP_ACTOR`, default `sge[bot]`).

Association (`OWNER`/`MEMBER`/`COLLABORATOR`) is deliberately **not** accepted
here: on a private repo that is everyone who can comment, so the gate would
block nobody — and conversely a GitHub App bot reports association `NONE`, so an
association check would make the daemon reject *its own* claims and
double-dispatch onto its own in-flight reviews. The daemon's own identity is
always an anchor, even beside a pinned allow-list, because a daemon that cannot
recognise its own claim comment cannot hold its own mutex.

Ordering matters for the last rule: a comment that cannot be authenticated at
all (fetched by a query that did not select the author fields) is **honoured**,
not discarded — dropping it would hide live claims and make the daemon
double-dispatch, breaking the mutex outright. Both queries feeding the sweep
select the author fields, so this only covers legacy call paths.

`claimedAt`/`ttl` are likewise never trusted at face value. A non-string,
malformed, timezone-naive, or future-dated `claimedAt`, and a non-numeric,
infinite, or non-positive `ttl`, all degrade to the same fallback a missing
field takes. This matters beyond the one PR: the sweep has no per-PR
`try`/`except` and neither does the fleet loop above it, so an uncaught parse
error aborts the scan for **every** remaining PR and repo — and repeats every
poll cycle for as long as the comment exists.

### Heartbeat comment format

```
```sge-claim-heartbeat
{"owner":"<agent-id>","at":"<ISO-8601-UTC>"}
```
```

The daemon posts a heartbeat comment every `CLAIM_HEARTBEAT_INTERVAL_SECONDS`
(default 600 s, configurable) for each in-flight dispatch.  The sweep looks for
a *qualifying* heartbeat comment within the claim's TTL window — if one exists,
the claim is still live regardless of `claimedAt`, up to the absolute ceiling.

### Fallback (backward compat)

For PRs claimed before issue #1312 was deployed (label-only claims with no
comment), the sweep falls back to the `pr-reviewing` label's `LabeledEvent`
timestamp from the PR timeline, compared against the daemon's
`REVIEW_DAEMON_CLAIM_TTL_SECONDS` policy (default 2700 s, 45 min).
