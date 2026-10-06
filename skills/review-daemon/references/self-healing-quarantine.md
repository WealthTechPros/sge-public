# Self-healing quarantine

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
is the PR Warden supervisor's label and is released by the supervisor.

> ⚠️ Because the predicate does live network I/O with a fail-safe-to-degraded
> contract, daemon behaviour tests that assert the **healthy** path pin
> `daemon.is_github_degraded` to `False` for determinism; the outage-path
> regressions (`daemon_outage.test.py`) pin it to `True`. Do not add un-pinned
> failure/quarantine assertions — they flake to retry-later whenever the status
> API is unreachable.

---

## Global pause on a Claude usage/session limit

A subscription usage or session limit (HTTP 429, for example "You've hit your session limit · resets 9:10pm (Europe/London)") belongs to the whole host, not to any PR. Every dispatch fails in about 1 s until the limit resets.

The daemon detects it from typed SDK fields only, never from model text:

- a `RateLimitEvent` with status `rejected`;
- a `ResultMessage` with `api_error_status` 429;
- a synthetic `AssistantMessage` with `error` set to `rate_limit`.

When it sees one, it pauses all polling and dispatching until the limit resets, plus a 60 s margin. The pause is capped at 24 h.

- **Reset time:** taken from `resets_at`. If that is missing, it is parsed from the harness message. If that fails, a 15-minute default applies.
- **Restarts:** the pause is persisted to `global-pause.json` in the log dir (or `REVIEW_DAEMON_PAUSE_FILE`), so a restarted daemon stays paused.
- **Quarantine:** the failure is `transient`. It never counts toward quarantine and never backs off the individual PR.
- **Logging:** the dispatch that started the pause writes one `runs.jsonl` record with `decision: {action: "global-pause", until}`. The supervisor's digest shows it once under "Decided on your behalf".

## Dispatch permission denied

On 2026-09-29, 2 of 19 dispatches (sge#2710, sge#2725) called the `Skill` tool for `sge:pr-review` instead of following the already-expanded slash command. Under `dontAsk` with no `Skill` rule this is denied ("Permission to use Skill has been denied because Claude Code is running in don't ask mode"), the run ends with no verdict, and it had been counted against the PR.

- **Allowlist:** the default `--allowedTools` carries exactly `Skill(sge:pr-review)`, `Skill(sge:qa-audit)` and `Skill(sge:pr-fix)` (Claude Code's exact-match skill rule). It never carries a bare `Skill`, and the permission mode stays `dontAsk`.
- **Prompt:** both lanes' system prompts say the slash command is already expanded and the Skill tool must not be called for it.
- **Classification:** the daemon reads the typed `ResultMessage.permission_denials`, never free text. Only a config fault counts: `Skill` for one of those three skills, or a `REQUIRED_GATE_TOOLS` entry missing from the effective `--allowedTools` (an override that dropped it). Such a denial is `transient` and never counts toward quarantine, unless the run timed out. Everything else stays the PR's failure, so PR content cannot steer the model into endless retries. That includes a per-call refusal of a tool that is allowed outright (a Bash safety check, a protected path), another skill and `WebSearch`.
- **Logging:** the record carries `permission_denied: [...]`. The first hit of each denied-tool set in a daemon process has `decision: {action: "dispatch-permission-denied", tools}`, so the digest shows it once under "Decided on your behalf". Later hits log `transient-retry`. stderr names the fix (`REVIEW_DAEMON_ALLOWED_TOOLS`).
- **Record fields:** `permission_denied` (string[]) and the `dispatch-permission-denied` decision action extend the `runs.jsonl` contract in SKILL.md.
