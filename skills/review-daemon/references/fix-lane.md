# Fix lane — PR Warden review + fix, never merge

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Fix lane — PR Warden "review + fix, never merge"

The daemon runs two lanes off the same poll. A PR the review lane cannot help —
it can't merge whatever a review says — goes to the **fix lane**, which
dispatches `/sge:pr-fix N --repo owner/repo` instead of `/sge:pr-review`, with
the lane's operating contract (resolve the target checkout, pre-claimed, never
merge, bounded) in the SDK system prompt — never appended to the skill
arguments, which Claude Code shell-expands into the skill's `!`gh pr checks
$ARGUMENTS`` step before the session starts (sge#2709).

**Classification** (GitHub adapter, `list_open_reviewable_changes`). After the
shared exclusions (draft, `pr-reviewing` live claim, `pr-review-stalled`
quarantine, hold labels `hold`/`do-not-merge`/`needs-human`/`blocked`), a PR is a
**fix candidate** when either:

- `mergeable == CONFLICTING` or `mergeStateStatus == DIRTY` → `fix_reason: conflict`, or
- its rollup is `FAILURE`/`ERROR` **and** a per-PR re-read
  (`isRequired(pullRequestNumber:)`, which covers branch protection and rulesets)
  shows at least one **required** check completed as failed
  (`FAILURE`/`TIMED_OUT`/`STARTUP_FAILURE`, or status `FAILURE`/`ERROR`)
  → `fix_reason: failing-check: <names>`, or
- its **current SGE verdict is REQUEST_CHANGES** and the delegation policy
  enables it (`REVIEW_DAEMON_FIX_FINDINGS=1`; **off by default**): the
  `changes-requested` label plus a *trusted* fail verdict with real findings at
  the current head → `fix_reason: review-findings`; never with `needs-decision`,
  a hold label, or a verdict flagging a human decision. Rules:
  [references/delegation-policy.md](delegation-policy.md#review-findings-fixes).

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

**Flaky-first** (delegation policy `fix_rerun_first`, off by default;
`failing-check` fixes only). Before claiming, the first time a head is seen
failing, the adapter reruns the failed jobs of each Actions run behind a failing
**required** check once (`POST .../actions/runs/{id}/rerun-failed-jobs`),
records it per head in the FixLedger (never a fix attempt) and skips the fix;
later cycles wait while it runs (bounded by
`REVIEW_DAEMON_FIX_RERUN_TIMEOUT_SECONDS`, 2700). Still failing on the same head
afterwards (or unknown, or timed out) -> fix. No Actions run, a rerun API
failure (e.g. HTTP 403) or an exception -> fix now.

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
| `REVIEW_DAEMON_FIX_FINDINGS`, `REVIEW_DAEMON_AUTO_MERGE*` | off | Delegation policy -- see [references/delegation-policy.md](delegation-policy.md). |
| `REVIEW_DAEMON_FIX_MODEL` | unset | Model for fix dispatches (e.g. `sonnet`). Unset: fixes go through model routing at a fixed **sonnet** tier (the routing config's `sonnet` model; a fix is not sized by the PR's diff, so the per-path/size rules do not apply), with `ANTHROPIC_MODEL` still a hard override. Precedence: `REVIEW_DAEMON_FIX_MODEL` > `ANTHROPIC_MODEL` > routed sonnet tier. |
| `REVIEW_DAEMON_RED_MAIN_*` | on | Red default-branch lane: [references/red-main.md](red-main.md). |

**Red default branch**: when a fleet repo's default branch fails a required check, the fix lane opens one fix (or culprit-revert) PR -- [references/red-main.md](red-main.md).

---
