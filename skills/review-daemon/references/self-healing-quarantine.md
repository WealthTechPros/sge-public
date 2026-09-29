# Self-healing quarantine (Rob, 2026-09-29)

On 2026-09-29 healthy PRs (sge#2703, sge#2707) were quarantined by the daemon's
**own** faults — GitHub App JWT `exp` 401s on token exchange and 0-turn
fix-lane exits — because every failure counted alike. Now
`classify_failure_transience` splits a failed dispatch:

| Class | When | Effect |
|---|---|---|
| `transient` | dispatch **raised**; typed SessionStart hook-terminate; `ResultMessage.num_turns == 0`; the SDK **raised** (`DispatchResult.sdk_error`) before any turn — token mint / exchange 401/403, "Control request timeout", connection errors; the SDK raised mid-run with a rate-limit / 429 / 529 / overloaded / auth signature | **Never** counts toward quarantine. Per-PR jittered exponential backoff (`REVIEW_DAEMON_TRANSIENT_BACKOFF_BASE_SECONDS`, default 120 s, doubling, capped at `REVIEW_DAEMON_TRANSIENT_BACKOFF_MAX_SECONDS`, default 3600 s); the poll skips the PR until it elapses. An uncounted `sge:dispatch-transient` breadcrumb on the 1st and every 5th failure of a streak; a streak ≥ 5 is logged with `ATTENTION:`. A transient **fix** failure also un-burns its per-head fix-ledger attempt. |
| `pr` | the run reached model turns and still failed, no-op'd or timed out (a timeout is the PR's size/content) | Counted exactly as before: `sge:dispatch-fail` breadcrumb, quarantine (`pr-review-stalled`) at `REVIEW_DAEMON_MAX_DISPATCH_ATTEMPTS`. |

Every tunable (SDK signatures, backoff base/cap, alert streak) is read through
one accessor, `transient_policy()` (a frozen `TransientPolicy`;
`set_transient_policy()` installs an override), so a policy loader can replace
it without touching call sites; with nothing installed the defaults above apply.

`detail` is consulted only when `sdk_error` says it is SDK exception text —
otherwise it is the model's output tail, which the PR under review can steer,
and free text alone never makes a failure transient.

**Auto-release on head move.** The daemon's quarantine comment now carries
an `sge:quarantine-head` HTML-comment marker carrying the head SHA. Each cycle the poll records the head of
every open `pr-review-stalled` PR; `release_moved_quarantines` releases one
(removes the label, posts an `sge:quarantine-released` marker, resets the
in-memory counters) when its head differs from the SHA in the **latest
daemon-authored** quarantine comment. A label without that marker — human-applied,
or a pre-marker legacy quarantine — is never touched. `pr-warden-quarantined`
is the wtp-org supervisor's label and is released by the supervisor.

> ⚠️ Because the predicate does live network I/O with a fail-safe-to-degraded
> contract, daemon behaviour tests that assert the **healthy** path pin
> `daemon.is_github_degraded` to `False` for determinism; the outage-path
> regressions (`daemon_outage.test.py`) pin it to `True`. Do not add un-pinned
> failure/quarantine assertions — they flake to retry-later whenever the status
> API is unreachable.

---
