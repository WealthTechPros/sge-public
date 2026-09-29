---
description: "Operational reference for the SGE review daemon (SPEC-090 Layer 1). Read before operating, configuring, or extending the daemon or its claim-mutex protocol."
---

# Review Daemon — Operator Reference

The **review daemon** (`services/review-daemon-poc/`) polls a fleet of repos for
open, non-draft PRs and dispatches `/sge:pr-review --no-automerge` against eligible
candidates — or, for a PR that is conflicting or has a failing required check,
`/sge:pr-fix` via the [fix lane](#fix-lane--pr-warden-review--fix-never-merge-wtp-org-adr-0021).
Neither lane ever merges.  All code-host access goes through the provider-agnostic `HostPort`
(`hostport.py`) so the daemon core is decoupled from GitHub specifics.

This document covers the **claim-mutex protocol** (issue #1312) in full — the
mechanism that prevents double-review races across daemon pods, interactive
orchestrators, and sge-implement Phase-7 lanes.

---

## Claim comment format (issue #1312)

When any actor claims a PR for review it MUST post a machine-readable comment
**alongside** the `pr-reviewing` label.  The comment identifies the owner and
declares the TTL so any other actor can determine liveness without a timeline API
call.

```
```sge-claim-metadata
{"owner":"<agent-id>","claimedAt":"<ISO-8601-UTC>","ttl":900}
```
```

| Field | Type | Description |
|---|---|---|
| `owner` | string | The claiming agent's identity.  Review daemon: `REVIEW_DAEMON_AGENT_ID` env var or hostname.  Interactive: `SGE_AGENT_ID` env var or hostname. |
| `claimedAt` | ISO-8601 string | UTC timestamp when the claim was placed. |
| `ttl` | integer | Seconds before the claim is considered stale **if no heartbeat was posted**.  Default 900 (15 min). |

The `pr-reviewing` **label** is the real mutex — it is the only signal that `pr-labels.sh` and `list_open_reviewable_changes` use for hard exclusion.  The claim comment is enrichment metadata for TTL-based staleness decisions.

---

## TTL self-heal logic (issue #1312 AC2)

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
ownership: an `sge-implement` Phase-7 or similar pipeline is the exclusive owner
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
# dispatched /sge:pr-review invocation when the daemon pre-claimed first.
/sge:pr-review <PR> --no-automerge   # prompt carries --force-claim authorisation
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
| `SGE_AGENT_ID` | `$(hostname)` | Owner field in claim comments posted by `pr-labels.sh` (interactive reviews). |
| `SGE_REVIEW_CLAIM_TTL` | `900` | Claim comment TTL in seconds (used by `pr-labels.sh`). |
| `REVIEW_DAEMON_CLAIM_TTL_SECONDS` | `2700` | Daemon's fallback reclaim TTL for label-only (pre-#1312) claims. |
| `REVIEW_DAEMON_REPO` | unset | `owner/repo` single-repo mode. Wins over `REVIEW_DAEMON_ORGS` and App-scope enumeration. Mandatory on the PAT path. |
| `GITHUB_APP_INSTALLATION_ID` | unset | The single App installation polled when `REVIEW_DAEMON_ORGS` is unset (legacy / default mode). Not read in multi-org mode. |
| `REVIEW_DAEMON_ORGS` | unset | Comma-separated account logins (e.g. `WealthTechPros,Professional-Performance-Portfolio`): the **explicit allowlist** of App installations to poll, one installation token each. Unset/blank = single-installation mode (`GITHUB_APP_INSTALLATION_ID`). Requires App auth. See [Multiple orgs](#multiple-orgs). |

---

## Multiple orgs

The GitHub App can be installed on several accounts — including **client orgs
that PR Warden must never review**. So the daemon never polls "every
installation the App can see": with `REVIEW_DAEMON_ORGS` set it lists the App's
installations (`GET /app/installations`, App JWT), keeps **only** those whose
`account.login` is in the allowlist (exact whole-login match, case-insensitive
— never a prefix/substring), and mints a separate installation token per kept
installation.

- **Explicit allowlist rule.** An org is reviewed only if it is named in
  `REVIEW_DAEMON_ORGS`. Every other installation is skipped — no token is ever
  minted for it — and each skip is logged once at startup
  (`[token] skipping installation for account '<login>' ...`) so the exclusion
  is visible in the daemon log.
- **Never add a client org.** Client orgs the App is installed on for other
  purposes (e.g. `MultreesInvestorServices`) must never appear in
  `REVIEW_DAEMON_ORGS`. Adding an org is an owner decision, not a config tweak.
- **Per-installation tokens.** Every GitHub call for a repo — polling,
  claim/labels, comments, verdicts — uses that repo's own installation token,
  and a dispatched review receives (`GH_TOKEN` / `SGE_REVIEW_APP_TOKEN`) only
  the token for the PR's own org. A repo whose owner has no allowlisted
  installation is refused (fail-closed; the dispatch gets no token).
- **Missing installation.** An allowlisted org with no App installation logs a
  loud `WARNING` at startup naming it; the daemon keeps running for the others.
- **Precedence.** `REVIEW_DAEMON_REPO` (single-repo mode) and shadow mode keep
  their narrower scope and ignore `REVIEW_DAEMON_ORGS`. Unset/blank
  `REVIEW_DAEMON_ORGS` is today's single-installation behaviour, unchanged.

---

## Fix lane — PR Warden "review + fix, never merge" (wtp-org ADR-0021)

The daemon runs two lanes off the same poll. A PR the review lane cannot help —
it can't merge whatever a review says — goes to the **fix lane**, which
dispatches `/sge:pr-fix owner/repo#N` instead of `/sge:pr-review`.

**Classification** (GitHub adapter, `list_open_reviewable_changes`). After the
shared exclusions (draft, `pr-reviewing` live claim, `pr-review-stalled`
quarantine, hold labels `hold`/`do-not-merge`/`needs-human`/`blocked`), a PR is a
**fix candidate** when either:

- `mergeable == CONFLICTING` or `mergeStateStatus == DIRTY` → `fix_reason: conflict`, or
- its rollup is `FAILURE`/`ERROR` **and** a per-PR re-read
  (`isRequired(pullRequestNumber:)`, which covers branch protection and rulesets)
  shows at least one **required** check completed as failed
  (`FAILURE`/`TIMED_OUT`/`STARTUP_FAILURE`, or status `FAILURE`/`ERROR`)
  → `fix_reason: failing-check: <names>`.

These never trigger a fix: pending checks, non-required checks, `CANCELLED`/`ACTION_REQUIRED`
runs, and the ignore list (`hold-gate`, `Require pr-reviewed label` by default).
A live `pr-fixing` claim keeps the PR out of the fix lane. Classification runs
*before* the reviewed-marker and standing-fail-verdict exclusions, so a
`pr-reviewed` PR that has since gone dirty or red is picked up. Any read error
classifies as "review" (the pre-fix-lane behaviour).

**Dispatch.** Same machinery as a review: fresh re-read (`is_still_fixable`),
the same `pr-reviewing` claim (`apply_fix_marker`, which tolerates a standing
`pr-reviewed`), the box-wide budget slot, the diff-sized turn/wall-clock budget,
the heartbeat, the OTEL span (`sge.dispatch.kind=fix`) and the shared per-PR
quarantine counter. The daemon **always** releases its claim after a fix run —
`/sge:pr-fix` takes its own `pr-fixing` claim. No review verdict is ever posted
for a fix run. The prompt (`build_fix_prompt`, contract locked by
`fix_lane.test.py`) says: pre-claimed; never `gh pr merge`, never add or
re-apply `pr-reviewed`, never `pr-labels.sh pass`; drop a standing
`pr-reviewed` with `pr-labels.sh stale` before pushing; push and exit, without
waiting for CI.

**Success means the head moved**, not exit 0 alone. After the run the daemon
re-reads the head:

- **moved** → success. The failure counter resets, and any standing
  `pr-reviewed` is dropped with a short comment (`mark_approval_stale`, the
  adapter equivalent of `pr-labels.sh stale`), so merge automation can't fire
  over unreviewed fix commits in repos without sge's head-binding. The PR goes
  back to the **review** lane on a later cycle.
- **not moved** (or the dispatch failed or timed out) → counts toward the shared
  quarantine (`pr-review-stalled` after `REVIEW_DAEMON_MAX_DISPATCH_ATTEMPTS`).
  A failure during a GitHub outage is retried later and doesn't count.

**Loop safety** (`fix_lane.py::FixLedger`):

- one fix per `(repo, pr, head_sha)`, never re-dispatched against the same head.
  An unknown head is not eligible.
- at most `REVIEW_DAEMON_FIX_MAX_ATTEMPTS` (default 2) fix attempts per PR in any
  `REVIEW_DAEMON_FIX_WINDOW_SECONDS` (default 86400) window.
- the attempt is recorded *before* dispatch, so a crash mid-run can't loop.
  The ledger persists to `REVIEW_DAEMON_FIX_LEDGER_PATH`, or to
  `$REVIEW_DAEMON_LOG_DIR/fix-ledger.json` when only the log dir is set, so it
  survives `Restart=always`.
- a fix candidate the ledger won't allow is left out of **both** lanes that
  cycle. Reviewing a PR that can't merge is wasted work, and quarantine is how
  it reaches a human.

**Scheduling.** Fix candidates are dispatched first, but they share the same
concurrency cap as reviews. Each lane is ordered oldest-first. A PR sits in
exactly one lane per cycle, so it is never reviewed and fixed in the same cycle.
Dispatch logs record the lane in their header (`# dispatch PR #N @ <ts> kind: fix|review`).

| Variable | Default | Effect |
|---|---|---|
| `REVIEW_DAEMON_FIX_LANE` | on | `0` disables the lane: fix candidates take the review path (pre-fix-lane behaviour). |
| `REVIEW_DAEMON_FIX_MAX_ATTEMPTS` | `2` | Fix attempts per PR per window. |
| `REVIEW_DAEMON_FIX_WINDOW_SECONDS` | `86400` | Rolling window for the attempt cap. |
| `REVIEW_DAEMON_FIX_LEDGER_PATH` | `$REVIEW_DAEMON_LOG_DIR/fix-ledger.json` | Ledger file (in-memory only when neither is set). |
| `REVIEW_DAEMON_FIX_IGNORE_CHECKS` | `hold-gate,Require pr-reviewed label` | Comma-separated check names that never trigger a fix. |
| `REVIEW_DAEMON_FIX_MODEL` | unset | Model for fix dispatches (e.g. `sonnet`). Unset: fixes go through model routing at a fixed **sonnet** tier (the routing config's `sonnet` model; a fix is not sized by the PR's diff, so the per-path/size rules do not apply), with `ANTHROPIC_MODEL` still a hard override. Precedence: `REVIEW_DAEMON_FIX_MODEL` > `ANTHROPIC_MODEL` > routed sonnet tier. |

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
| **Exit-0-no-artefact read** (#1250, AC3) | an exit=0-no-artefact dispatch whose last SDK message is a SessionStart hook_started event with zero tool calls is reclassified as an infra failure and does NOT increment the per-PR quarantine counter (or is auto-retried once within the same cycle), regardless of GitHub health; every other exit=0-no-artefact dispatch is still reported as a silent no-op **failure** (`ok=False`), counter increments | released and returned `None` (retry-later); the unreadable artefact is a transient read failure, not a no-op |

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

**SessionStart-hook-terminate carve-out (issue #2502).** One sub-case of the
healthy-GitHub AC3 cell is further split, independent of `is_github_degraded()`:
if the dispatch's SDK stream (captured as `DispatchResult.detail`, requires
`include_hook_events=True` on the dispatch's `ClaudeAgentOptions`) ended with a
bare `HookEventMessage(subtype='hook_started', hook_event_name='SessionStart',
...)` and zero tool calls anywhere in the run, the session was torn down while
still inside its own startup hook — before the dispatched skill ever got a
turn. `daemon.py`'s `_HookTerminateObserver` classifies this from the SDK's
**typed** events over the **whole** stream (not text matching over the
20-event `detail` tail, which carries PR-steerable model output), and carries
the result as `DispatchResult.hook_terminate`. `_claim_and_dispatch`
reclassifies it the same way as an outage-era read failure: release the claim,
return `None` (retry-later), skip `_track_failed_dispatch` — so it does **not**
walk the PR toward `pr-review-stalled`. This is a harness/infra failure, not a
review outcome, so it is checked and applied regardless of GitHub health.
Every other exit=0-no-artefact dispatch on a healthy GitHub (permission-denied
tools, skill back-off, plugin load failure, turn-budget exhaustion) still
falls through to the original silent-no-op failure path.

**Retry cap (issue #2652).** Unlike the outage carve-out, nothing time-bounds
a SessionStart hook that fails on every dispatch, so the carve-out is capped:
only the first `REVIEW_DAEMON_HOOK_TERMINATE_RETRY_CAP` (default **3**; `0`
disables the carve-out) *consecutive* hook-terminates for a PR are
retry-later. From the next one on, the dispatch is counted through
`_track_failed_dispatch` (breadcrumb reason names the cap), so quarantine
engages after `REVIEW_DAEMON_MAX_DISPATCH_ATTEMPTS` further attempts. Any other
dispatch outcome breaks the streak. The streak counter is in-memory, so a
daemon restart re-grants at most one cap's worth of retries. Every dispatch
span carries `sge.dispatch.hook_terminate` (true/false) for fleet-wide
alerting. **Job mode** (`REVIEW_DAEMON_SINGLE_PR`) does not apply the
carve-out: a one-shot container has no next poll cycle, so returning
retry-later would leave no trace at all — the attempt is counted, with the
hook-terminate named in its breadcrumb reason.

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
`/sge:sge-review`) is **not duplicated** by the daemon's merge-gate review — they
serve different roles and should both run:

| Layer | When | Guards against |
|-------|------|----------------|
| Phase 5 (`/sge:sge-review`, pre-PR) | Before the draft lands in the merge queue | Wasted daemon dispatch on a doomed PR |
| Daemon (`/sge:pr-review`, merge-gate) | After the PR is ready | Cross-author review; gate label + auto-merge |

Never suppress Phase 5 on daemon-covered repos. Evidence: on client-onboarding#2389,
Phase 5 caught 2 CI-confirmed blockers before the daemon pod fired, preventing a
wasted dispatch at full review cost.

---

## Per-dispatch model routing (owner decision 2026-09-28)

Each dispatch runs at a model **tier** chosen from the PR itself
(`services/review-daemon-poc/model_routing.py`). Thresholds and globs are
owner-approved defaults (Rob, 2026-09-28), overridable per host.

| Tier | Default model | Chosen when |
|---|---|---|
| `haiku` | `claude-haiku-4-5-20251001` | docs-only change (every file `*.md`/`*.mdx`/`*.markdown`/`*.txt`/`*.rst`/`*.adoc`); Dependabot/Renovate-authored PR; diff < 50 changed lines touching no risky path |
| `sonnet` | `claude-sonnet-5` | default for code PRs |
| `opus` | `claude-opus-5-5` | any risky path; diff >= 1500 changed lines (the largest budget bucket); changed-file list unavailable (fail closed) |

Check order is the precedence: unknown file list → **risky path** → dependency
bot → docs-only → large diff → small diff → sonnet. A risky path always wins
(a Dependabot PR that edits a workflow routes to opus). Default risky globs:
`infra/**`, `platform/infra/**`, `.github/workflows/**`, `**/migrations/**`,
`**/*auth*[/**]`, `**/*security*[/**]`, `**/*secret*[/**]`, `**/*crypto*[/**]`,
`**/Pulumi*.y[a]ml`, `**/Dockerfile`, `**/Dockerfile.*`, `**/*.Dockerfile`,
`.githooks/**`, `hooks/**` (case-insensitive; a rename counts both paths).

The changed-file list comes from one paginated `pulls/{n}/files` call per
**dispatched** PR (after the claim is won), never per polled PR.

**Precedence of configuration:** `ANTHROPIC_MODEL` (issue #2491) is a hard
override — one model for every dispatch, routing bypassed (the displaced tier
is still logged) → `REVIEW_DAEMON_MODEL_ROUTING` JSON (`haiku`/`sonnet`/`opus`
model ids, `small_diff_lines`, `large_diff_lines`, `risky_globs` (replace),
`risky_globs_add` (append), `docs_globs`, `bot_authors`) → built-in defaults.
An invalid `REVIEW_DAEMON_MODEL_ROUTING` **refuses to start**, like the #1435
tool-config check. The chosen model + tier is recorded on the `dispatching:`
log line, the dispatch log file header, and the OTEL span attributes
`sge.dispatch.model` / `sge.dispatch.model_tier`.

## Startup skill check and zero-turn dispatches (2026-09-28)

On 2026-09-28 the WSL daemon host had no `sge` plugin installed: every
dispatch returned `num_turns=0` in ~50 ms, three attempts per PR were burned,
and PR #4 was quarantined before anyone noticed. Two guards now apply:

- **At startup** the daemon verifies `/sge:pr-review` is resolvable by the
  Claude Code its SDK spawns (`skill_check.py`): an `sge@*` entry in
  `$CLAUDE_CONFIG_DIR`/`~/.claude` `plugins/installed_plugins.json` applying to
  the dispatch cwd, whose `installPath` has `skills/pr-review/SKILL.md`, not
  disabled in `enabledPlugins`. Otherwise it **refuses to start** with a FATAL
  line naming the fix.
- **At runtime** a dispatch whose `ResultMessage` reports `num_turns == 0` is an
  immediate **INFRA** failure (named cause: skill not found), not an exit-0
  candidate for artefact verification — no verdict is posted; it counts toward
  quarantine like any other INFRA failure.

## Dispatch run log — `runs.jsonl` (2026-09-28)

The daemon appends **one JSON line per completed dispatch** to
`$PR_WARDEN_RUNS_LOG` (wtp-org's PR Warden supervisor sets it to
`$WTP_HOME/review-daemon/logs/runs.jsonl`; ADR-0021 §3.3), falling back to
`$REVIEW_DAEMON_LOG_DIR/runs.jsonl`, else nothing is written. Readers: the
supervisor's quarantine sweep and cost/status feed, and wtp-mcp's `pr_agent_*`
tools (wtp-mcp#888, MCP-031). Field names are a cross-repo contract:

| Field | Type | Meaning |
|---|---|---|
| `ts` | string | completion time, `YYYY-MM-DDTHH:MM:SSZ` (UTC) |
| `kind` | string | `review` or `fix` (PR Warden fix lane). A fix record's `verdict` is always `none`; its `outcome` is `pass` only when the fix moved the head |
| `repo` | string | `owner/name` |
| `pr` | int | PR number |
| `head_sha` | string | head commit the dispatch ran against (`""` if unknown) |
| `outcome` | string | `pass`, `fail`, `timeout` or `quarantined` — see below |
| `verdict` | string | `approve`, `request_changes` or `none` (from the review artefact's own verdict) |
| `needs_human` | bool | the review concluded `blocked` (supervisor escalates; never counted as a failure) |
| `model` / `model_tier` | string | routed model and tier (`override` under `ANTHROPIC_MODEL`) |
| `duration_s` | float | dispatch wall time, seconds |
| `cost_usd` / `num_turns` | number or null | from the SDK `ResultMessage` (`total_cost_usd`, `num_turns`) |

`outcome` is the **dispatch-execution** outcome, matching the supervisor's
"failed attempt" semantics: `pass` = the review ran and left a verified
artefact **whatever it concluded** (`verdict` carries approve/request-changes);
`fail` = no review produced (SDK error, silent no-op, zero-turn run, raised
dispatch); `timeout` = wall-clock backstop; `quarantined` = the failed dispatch
that exhausted the attempt budget. A request-changes review is therefore
`outcome: pass` and never walks a PR toward the supervisor's quarantine.
**Retry-later exits** (GitHub outage, SessionStart-hook-terminate) are not
completed dispatches and write no line.

Each record is one `os.write` of one line (< 4096 bytes, PIPE_BUF) to a file
opened `O_APPEND`, so concurrent workers never interleave. It never contains PR
content, prompts, dispatch output or secrets. A write failure is logged and
never reaches the dispatch path.

## Org-wide poll and quiet hold logging (2026-09-28)

Under App-scope enumeration each cycle runs **one** paginated GraphQL `search`
(`org:<owner> is:pr is:open archived:false sort:created-asc`) for the whole
fleet instead of two queries per repo; selection rules (draft, markers, hold,
fail-at-head, shadow-at-head, stale-claim reclaim, rate-limit floor) are
unchanged and run on the same node shape, truncated to the per-repo path's 50
oldest PRs per repo. One line per cycle logs the GraphQL cost and remaining
budget. Falls back to per-repo queries when `REVIEW_DAEMON_REPO` is set, when
search reports > 1000 results, or on any search error. The "has a hold label …
excluded" line is logged when a PR enters the held state and once when it
leaves — not every cycle (in-memory; a restart re-logs each held PR once).

In multi-org mode (`REVIEW_DAEMON_ORGS`) the org-wide poll runs **per
allowlisted installation**: one search per installation, over only that
installation's repos (`org:<its owner>`), made with that installation's own
token — never one global search across installations. A non-allowlisted owner
is never searched, and one installation's search failure drops only that
installation back to per-repo polling.

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
