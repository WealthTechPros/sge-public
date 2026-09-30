# Outage-aware dispatch (SPEC-103, issue #1341)

Moved out of `SKILL.md` (35 KB skill size budget); content unchanged.

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
(vs. returns not-ok) is a **transient** failure (see "Self-healing quarantine"
below): backed off, never counted.

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
retry-later. From the next one on, the dispatch is a **transient** failure
(self-healing quarantine, below): jittered exponential backoff, an uncounted
`sge:dispatch-transient` breadcrumb naming the cap, and **never** quarantine
(superseding #2652's count-then-quarantine, Rob 2026-09-29). Any other
dispatch outcome breaks the streak. The streak counter is in-memory, so a
daemon restart re-grants at most one cap's worth of retries. Every dispatch
span carries `sge.dispatch.hook_terminate` (true/false) for fleet-wide
alerting. **Job mode** (`REVIEW_DAEMON_SINGLE_PR`) does not apply the
carve-out: a one-shot container has no next poll cycle, so returning
retry-later would leave no trace at all — the attempt is recorded as a
transient failure (uncounted breadcrumb naming the hook-terminate).
