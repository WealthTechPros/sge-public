# Review daemon delegation policy

What the daemon may do without asking a human is **delegation policy**
(`delegation_policy.py`): one `DelegationPolicy` object read through one
accessor, `get_policy()`. The daemon ships **neutral defaults** -- merge arming
off, review-findings fixing off, no org, repo or path values built in -- so an
unconfigured daemon behaves exactly as before. An operator's values (which orgs
may be merged, which never, which paths always need a human) belong in the
operator's deployment configuration. The source today is environment variables
(table below); a policy-file loader (`REVIEW_DAEMON_POLICY_FILE`, standing
orders with ids) can replace it behind `get_policy()` without touching a call
site.

After a review dispatch whose artefact verdict is PASS (the formal verdict is
posted first), `arm_auto_merge_if_eligible(port, change)` -- the one reusable
entry point, also for any later sweeper -- asks the port to arm native
auto-merge. The GitHub adapter runs `enablePullRequestAutoMerge` (the org
rule's `method`, default squash; `expectedHeadOid` = the reviewed head when the
rule's `pin_head` is on, the default) only when **every** gate passes, else logs
why and leaves the PR reviewed and unmerged:

- the org has an `arm-auto-merge` rule (a `never-merge` rule always wins) and
  the policy loaded without errors;
- no blocking label of the org rule (fresh read; default `hold`/`do-not-merge`/`needs-human`/
  `blocked`/`orchestrator-only`/`needs-decision`/`agent-lock`/
  `pr-warden-quarantined`/`pr-review-stalled`);
- the changed-file list, **re-read at arm time**, is known and no path matches
  the rule's `exclude_paths` globs for the repo or for `*` (keys match
  case-insensitively; globs use the routing matcher, where `*` stays inside one
  path segment -- write `infra/**`, not `infra/*`, to cover a whole tree);
- the PR is **not** from a fork (`isCrossRepository` false) and its author's
  association is `OWNER`, `MEMBER` or `COLLABORATOR`;
- the **latest** trusted `sge-verdict` on the PR is `verdict: pass`, `mode:
  full` (a delta or Phase-5 pass-through review rests on inputs the PR author can
  influence, so it never arms a merge), not flagged for a human, and its
  `commit:` is the live head's full SHA; an edited fence counts only when a
  trusted identity made the edit, and a truncated comment/review/label read
  fails closed. Trusted here means identity, not association:
  the daemon's own login or a `REVIEW_DAEMON_TRUSTED_VERDICT_AUTHORS` login,
  never the PR's author (pin the App as `<slug>[bot]`);
- the repo's default branch has **no** `.github/workflows/sge-auto-merge.yml` --
  such repos already merge on `pr-reviewed` through that workflow, with a
  sensitive-path deny native auto-merge would bypass;
- the repo allows auto-merge, the PR is open and ready, and its live head still
  equals the reviewed head. Never in shadow mode.

**Disarm on drift** ([sge#2719](https://github.com/WealthTechPros/sge/issues/2719)).
Every PR the daemon arms is recorded in the armed-merge ledger
(`REVIEW_DAEMON_ARMED_MERGES_PATH`, default
`$REVIEW_DAEMON_LOG_DIR/armed-merges.json`; persist it -- an in-memory ledger
is warned about at startup and forgets every arming on restart). At the top of
every poll cycle, and on its own timer every poll interval independent of how
long a cycle's reviews take -- before the global pause gate, whatever the
current policy says -- the daemon re-reads every
ledgered PR and disables auto-merge (`disablePullRequestAutoMerge`) when any
arming gate above now fails: a blocking label appeared, the head moved past the
armed head, the latest trusted verdict is no longer a full pass on the live
head, a trusted (OWNER/MEMBER/COLLABORATOR) reviewer's standing review requests
changes, the PR became a fork/untrusted-author case, or the policy no longer
delegates the org. A fix that moves the head and a non-pass verdict trigger the
same re-check immediately. Each disarm posts one PR comment. The daemon only
disarms what it armed: when GitHub's `autoMergeRequest.enabledBy` is anyone
else (a human armed or re-armed it), the PR is dropped from the ledger and left
alone. On a PAT install the daemon's identity IS the token owner's login, so a
human re-arming under that same account cannot be told apart (it may be
disarmed -- never merged); use the App identity for the distinction. A failed
read or mutation keeps the entry for the next sweep (10 consecutive failures
log a `CHECK AUTO-MERGE BY HAND` warning). A trusted reviewer's standing
changes-request now also blocks arming in the first place.

Disarm-on-drift is **eventually consistent defence in depth, not the primary
control**: between a drift event and the next sweep (up to one poll interval,
longer while re-checks error) GitHub can still merge. Keep delegating merging
only for repos whose branch protection dismisses stale approvals and enforces
holds with a required check.

`runs.jsonl` records carry `merge_armed: true|false` and `decision`: `{order,
action}` for a delegated action (`auto-merge-armed`, `review-findings-fix`; the
order id comes from the policy and is `null` when env-configured), else `null`.
A disarm is its own record: `kind: merge`, `outcome: disarmed`, `decision:
{order, action: "auto-merge-disarmed", reason}`, `head_sha` = the armed head.
Poll mode only; single-PR job mode does not arm.


## Review-findings fixes

With `REVIEW_DAEMON_FIX_FINDINGS=1`, a PR is a fix candidate when it carries
`changes-requested` plus a *trusted* fail verdict at the current head whose
body is real findings (not the daemon's own fail-closed "the review dispatch
did not complete" verdict) → `fix_reason: review-findings`. It is left for a
human when the PR carries `needs-decision` (or any hold label), or the latest
verdict flags a human decision (`held_for_human: true` / `hold_active: true`);
the dispatch-time re-read (`is_still_fixable`) re-checks both against the
latest verdict *comment* too, fail-closed. The fix system prompt points the
agent at the latest findings (untrusted data) and tells it to add
`needs-decision` rather than guess. The pushed head leaves the fail verdict
behind, so the PR returns to the review lane for a delta review. Conflict and
failing-check reasons win when both apply.

## Env knobs

| Variable | Default | Effect |
|---|---|---|
| `REVIEW_DAEMON_FIX_FINDINGS` | off | Delegation policy: `1` lets the fix lane fix REQUEST_CHANGES review findings. |
| `REVIEW_DAEMON_AUTO_MERGE_ORGS` | empty (off) | Delegation policy: comma list of orgs whose PRs are auto-merged on a PASS verdict. |
| `REVIEW_DAEMON_AUTO_MERGE_DENY_ORGS` | empty | Delegation policy: orgs given a `never-merge` rule; wins over the list above. |
| `REVIEW_DAEMON_AUTO_MERGE_BLOCK_LABELS` | the SGE hold/lock labels above | Delegation policy: comma list replacing the blocking labels. |
| `REVIEW_DAEMON_AUTO_MERGE_EXCLUDE_PATHS` | `{}` | Delegation policy: JSON `{"owner/repo" \| "*": [globs]}`; a PR touching a match is not auto-merged. Invalid JSON disables merge arming. |
| `REVIEW_DAEMON_AUTO_MERGE` | -- | `0` is a kill switch for merge arming. |
| `REVIEW_DAEMON_FIX_RERUN_FIRST` | off | `1` enables flaky-first: rerun failed required Actions jobs once per head before a `failing-check` fix. |
| `REVIEW_DAEMON_FIX_RERUN_TIMEOUT_SECONDS` | `2700` | How long later cycles wait for that rerun before dispatching the fix anyway (operational knob, not policy). |

## Policy-file shape

A policy-file loader populates the same object: `merge_rules` -- one
`MergeRule` per org: `org`, `action` (`arm-auto-merge` | `never-merge`),
`method` (`squash` | `merge` | `rebase`), `pin_head`, `block_labels`,
`exclude_paths` (`{"owner/repo" | "*": [globs]}`), `order` (the standing-order
id recorded in `runs.jsonl` `decision.order`) -- and `routine_fix` -- a
`RoutineFixPolicy`: `allowed` (e.g. `review-findings`), `repo_conventions`,
`default_update_strategy`, `force_push`, `order`. The env source builds
`arm-auto-merge` rules from `REVIEW_DAEMON_AUTO_MERGE_ORGS` and `never-merge`
rules from `REVIEW_DAEMON_AUTO_MERGE_DENY_ORGS`, with no order ids.
