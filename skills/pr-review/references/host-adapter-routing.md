# Non-GitHub host (Azure Repos, Forgejo/Gitea) — host routing

Reference for [`../SKILL.md`](../SKILL.md) — the host-adapter read routing used
by Phases 1–4 when the repo is not on GitHub. Extracted for the SKILL.md size
budget (progressive disclosure); behaviour is unchanged.

Before Phase 1, detect the host and source the PR-read shim so every read in
Phases 1–3 routes correctly without branching on the host inside each phase:

```bash
SGE_ROOT="$(bash ./scripts/resolve-sge-root.sh 2>/dev/null || bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-sge-root.sh")" || exit 1
HOST_KIND="$("$SGE_ROOT/scripts/with-repo-cwd.sh" host)"
source "$SGE_ROOT/skills/lib/forgejo-pr-read.sh"
```

| Read operation            | GitHub (`gh`)                           | Any host (`fpr_*`)    |
|---------------------------|-----------------------------------------|-----------------------|
| View PR metadata          | `gh pr view "$PR" --json ...`           | `fpr_view "$PR"`      |
| Fetch diff                | `gh pr diff "$PR"`                      | `fpr_diff "$PR"`      |
| Read CI check statuses    | `gh pr checks "$PR" --json ...`         | `fpr_checks "$PR"`    |

**Scope:** only the non-mutating read and diff phases (Phase 1 Discovery, Phase 2
agent dispatch input, Phase 3 quality gates CI read, Phase 4 issue validation) are
routed here.

**Azure Repos** has the full review lane (below). **Forgejo/Gitea** has the read/diff
routing here and its own gate state machine (next section).

## Forgejo/Gitea — the gate model (SPEC-094 §2.2a, #3029)

> **Forgejo gate: not live-validated.** The gate as a whole has not run against a real instance. Every
> behaviour below is exercised only against offline stubs
> (`skills/tests/pr-labels-forgejo-*.test.sh`), except one targeted live run
> on Forgejo 16.0.2 (2026-10-14) that covered only the admin-versus-write branch-protection
> read (see the merge-arm note below). The full gate has not run against a real
> Forgejo instance; slice S6 (#3073) is that run. Do not make a Forgejo
> repo's merge depend on this gate until S6 has run and this marker is removed.

When `host` reports `forgejo`, `pr-labels.sh` dispatches to `pr-labels-forgejo.sh`
(modules under `pr-labels-forgejo.d/`, REST verbs under `scripts/forgejo-adapter.d/`).
No `gh` call is made on this path, and an adapter or API error is a non-zero exit,
never a pass. Writes need `FORGEJO_ADAPTER_ALLOW_WRITE=1`, which the modules set for
their own calls only. Auth is `FORGEJO_API_TOKEN` then `GITEA_TOKEN`.

| Step | Forgejo mechanism |
|---|---|
| Claim (`start-review`, `claim-fix`) | A **git ref** `refs/heads/sge-claims/pr-<n>-<reviewing\|fixing>-g<k>`, created through the branches API. Gitea answers 409 when the ref exists, so two racers resolve to exactly one 201 (server-side compare-and-swap). Labels `pr-reviewing` / `pr-fixing` are display only. |
| Liveness | A comment `<!-- sge-claim: {...} -->` written by the winner carries the owner; its **server** `created_at` and the response `Date` header give the age (never the local clock). `heartbeat` posts a second comment that extends the TTL, never past the max lifetime. |
| Takeover | A stale top generation is raced for as generation k+1 (one taker wins the CAS). A live or unknowable claim is lost (exit 3), with one exception: an armed live claim whose lane label is gone is taken over at once, only if the label list is readable and well-formed. A ref with no record is taken over once a `sge-claim-orphan` observation is older than the TTL. |
| Verdict (`pass`, `fail`, `shadow-pass`) | A **commit status** on the reviewed head: context `sge/pr-review` (success / failure) or `sge/pr-review-shadow`. A status names its commit, so it cannot describe another head, and it works when the agent authored the PR (Gitea refuses a self-approval review). Only a status created by the token's own user counts. |
| Hold (`held`, `apply-hold`, `sync-check`, `stale`) | The `hold` label stops `pass` (exit 8) and merge arming. `release-hold` always refuses (exit 9): no delegation policy is wired for Forgejo, so a human removes the label. |
| Merge arm (`pass --auto-merge`) | After the pass is recorded, one squash-merge request pinned to the reviewed head (`head_commit_id`), refused unless branch protection can enforce the gate. A refusal leaves the pass standing and, once the PR has been read, attempts to cancel any scheduled merge (best-effort; refusals on bad arguments, advisory/shadow dispatch, missing `jq` or path setup return before that). |

**Claim defaults.** `SGE_REVIEW_CLAIM_TTL` (900 s) for review, `SGE_FIX_CLAIM_TTL_MIN`
(30 min) for fixing, `SGE_FORGEJO_CLAIM_MAX_LIFETIME` (14400 s). A malformed TTL
refuses. The owner id is `SGE_AGENT_ID`, defaulting to the hostname.

**Pass refusals** (`pass <pr> --expect-head <sha>`, in order): advisory dispatch (4),
shadow dispatch (9), unattested reviewer (5), no claim held (7) (waived only by an explicit `--skip-claim-check` for a deliberately unclaimed inline review), no `--expect-head`,
PR not open or a draft, `hold` present (8), head moved since review, CI not exactly
`success` (`none`, `pending`, `unknown` all refuse), unresolved review threads,
declared follow-up with no issue (6). The PR is re-read before the verdict is
written and again after the labels move; if the head moves after the status was written, or the PR is closed, drafted or held, cleanup is best-effort: the command attempts to post a failure status for the reviewed head and remove `pr-reviewed`, and either call can fail and leave stale state.

**`--expect-head`.** Required by `pass`, `fail` and the merge arm. `pass` and `fail`
accept a prefix of at least 7 hex characters; the merge arm needs the full 40-hex id
and compares it by exact equality. The merge request itself is pinned to that SHA.

**Exit codes.** 2 usage / subcommand not ported, 3 claim lost or held by another
owner, 4 advisory dispatch, 5 reviewer attestation missing, 6 follow-up gate (a head
that moved is exit 1 here, not 6), 7 claim not held, 8 hold, 9 shadow dispatch / not
eligible / `release-hold`, 1 any other refusal.

**No label-based required check.** Forgejo cannot require a *label* to merge, so
`pr-reviewed` is a signal only. The gate is enforced by the base branch's protection
rule, which `pass --auto-merge` reads (`branch-protection`) before arming:

| Protection field | Required value |
|---|---|
| `enable_status_check` | `true`, with a non-empty `status_check_contexts` (the script requires only that and does not check that `sge/pr-review` is in the list; list it so the server enforces the verdict itself) |
| `status_check_contexts` | every context (globs allowed) must be `success` at the reviewed head |
| `required_approvals` | must be readable; the gate does not set it. A human approval count is the repo owner's policy, separate from the commit-status verdict |

An unreadable rule, a rule requiring no status checks, or a non-green or missing
required context refuses to arm the merge. Setting the rule is repo configuration, not
something these scripts do.

**Still stubs (exit 75, then the pre-existing inline path):** `claim-status`,
`claim-work`, `release-work`, `reconcile-orphaned-claim`, `review-coverage`,
`excluded-reviewer`. The inline path does not see a claim taken by the ref mutex.

**Bare mutators.** `skills/lib/forgejo-pr-mutate.sh` still provides `fpr_add_label`,
`fpr_remove_label`, `fpr_merge_ready`, `fpr_merge` and `fpr_rerun`; the gate modules
reuse the label and readiness ones. See [`pr-monitor`'s copy of this
doc](../../pr-monitor/references/host-adapter-routing.md#mutating-ops-rerun--merge--label--issue-2582).

**Forgejo merge arm (`pass --auto-merge`) — required permission (#3122).** Before it
merges, the arm reads the base branch's protection rule (`status_check_contexts`,
`required_approvals`) and checks every required context is green at the reviewed head.
Forgejo/Gitea allow that read (`GET /repos/{o}/{r}/branch_protections/{branch}`) only
for **repo admins**, so the reviewing identity needs **admin** on the repo to arm a
merge. A write collaborator can still record the verdict (`pass` without
`--auto-merge`), but the arm refuses with `no readable branch protection for '<branch>'
(HTTP <code>)` and exit 1; nothing merges and any scheduled merge is cancelled. HTTP 403
means the identity is not an admin; 404 is ambiguous (no rule, or hidden from a
non-admin). The arm never skips or degrades the protection read for a write identity:
it is the safety pre-check that required contexts are satisfied. (The cause is inferred
from the admin-versus-write difference seen in the 2026-10-14 live run on Forgejo
16.0.2; it was not isolated further.) The message shows only the numeric status, never a
response body or token.

**Forgejo merge arm — required status context (#3127).** The arm also refuses unless the
base branch's `status_check_contexts` includes the review verdict context `sge/pr-review`
(a glob that matches it counts), so branch protection itself enforces "no merge without a
pass verdict". The refusal is exit 1, names the missing context and merges nothing.
`SGE_FORGEJO_REVIEW_CONTEXT` renames the required context per repo, and
`SGE_FORGEJO_ALLOW_UNREQUIRED_REVIEW_CONTEXT=1` is the explicit operator override.

**Forgejo claims and merge method (#3124).** A claim taken by one token identity that has
gone stale cannot be taken over by a different identity without `--force-claim`: the
foreign record reads `live=unknown`. Same-identity takeover with a different
`SGE_AGENT_ID` works (generation 2). The Forgejo merge arm is squash-only
(`pr-merge-squash`); a repo that forbids squash merges refuses the request, so the arm
exits 1 with `merge request failed` and nothing is armed or merged.

**Unported work-lane verbs (#3123).** On a Forgejo host `claim-status`, `claim-work`,
`release-work` and `reconcile-orphaned-claim` refuse with exit 2 ("not implemented on
forgejo") and never call `gh`.

**Forgejo PR fields mapping** (from Gitea JSON to the names this skill references):

| This skill uses           | Gitea JSON field                        |
|---------------------------|-----------------------------------------|
| `number`                  | `.number`                               |
| `title`                   | `.title`                                |
| `body`                    | `.body`                                 |
| `isDraft`                 | `.draft`                                |
| `headRefName`             | `.head.ref`                             |
| `headRefOid`              | `.head.sha`                             |
| `baseRefName`             | `.base.ref`                             |
| `state`                   | `.state` (`open`/`closed`)              |
| `labels[].name`           | `.labels[].name`                        |
| `additions` / `deletions` | not in Gitea schema — derive from diff  |

`fpr_view "$PR"` returns the full Gitea PR JSON object; use `jq` to project
the fields this skill needs before passing to downstream phases.

## Azure Repos (`azdo`) — the supported review lane (SPEC-110 S4, #2985 / #2989 / #3028)

Host detection is the same (`with-repo-cwd.sh host` -> `azdo`). On `azdo` the whole
Phases 1-9 lane runs without `gh`: nothing is ever sent to a `gh` that cannot see the
repo. Anything that has no Azure route **refuses** (non-zero exit, message on stderr)
or takes its documented fail-closed value; it never falls through.

**Auth.** `SGE_AZDO_TOKEN` (a PAT or Entra token) plus `SGE_AZDO_ORG`/`SGE_AZDO_HOSTS`
as for `scripts/azdo-adapter.sh`. Scopes: Code (Read) for the read/diff phases; Code
(Read & Write) plus Pull Request Threads (Read & Write) for claims, labels, threads and
votes; Build (Read) and Policy evaluations for the CI-green reduction (DP5). Writes need
the explicit `AZDO_ADAPTER_ALLOW_WRITE=1` opt-in, which `pr-labels.sh` sets for its own
calls only.

| Phase / need | Route on `azdo` |
|---|---|
| PR view / diff / files / checks / threads | `sge_gh_pr view\|diff\|checks` (`skills/lib/azdo-gh-pr.sh`) -> adapter `get-pr`, `pr-diff`, `pr-files`, `pr-ci`, `pr-threads` |
| Repo slug, PR number, head SHA | `rl__repo` / `sge_gh_pr view --json number\|headRefOid` |
| Claim, release, heartbeat, hold, stale, sync-check, `pass`, `fail` | `pr-labels.sh` -> `pr-labels-azdo.sh` (git-ref CAS claim, PR tags, vote bound to `--expect-head`) |
| Verdict vote (APPROVE / REQUEST_CHANGES) | **Only** `pr-labels.sh pass\|fail <pr> --expect-head <40-hex> [--verdict-file <f>]`. `rl_post_verdict` refuses it with exit 8 |
| Verdict COMMENT (advisory / incomplete), `rl_post_verdict_comment` | adapter `pr-comment` (a closed thread; prints its numeric id) |
| `rl_verify_verdict_posted "$PR" <id or -> [expected]` | `-`: the newest verdict artefact (`pr-verdict-status`) judged the current head **and** is the expected kind (`approve`/`wait`/`reject`, or `pass`/`fail`; **required** for `-`, omitted is refused). A numeric id: that COMMENT thread carries exactly one fence whose `commit:` is the current head, checked alone and never satisfied by a vote artefact |
| `rl_unresolved_threads`, `rl_failing_checks`, `rl_idempotency_check`, `rl_lane_manifest_active`, `rl_hold_check`, `rl_qa_evidence`, `rl_phase5_verdict`, `rl_diff_risk` | routed to the adapter (see `review-lib.sh`) |
| `rl_changes_requested` | our newest verdict artefact (`pr-verdict-status`) **plus** every reviewer's own Wait/Reject vote (`pr-votes`), human votes included; either unreadable is non-zero, never `0` |
| Phase 1 Stage 1 reads, Phase 8 mergeability | `sge_gh_pr diff --name-only`, `sge_pr_comments_json`, adapter `view-item` (linked work item), `sge_gh_pr view --json mergeable`; the `gh` branch of the Stage 1 block is the non-azdo `else` |
| Rename-aware classifiers (`rl_diff_trivial`, `_generated`, `_prose`, `_control_bearing`, `_oracle_bearing`, `rl_generated_manifest_lookup`) | refuse -> "not detected" (the normal risk tier applies) |
| `rl__findings_diff_paths` | refuses -> findings provenance is `unverifiable` |
| `rl_post_findings_comment` | refuses (exit 1): fold findings inline (`findings_comment: inline`) |
| `rl_ensure_closing_link` | refuses (exit 1): link work items with adapter `link-close-on-merge` |
| `rl_rate_limit_status`, `rl_checks_status_gql` | refuse (exit 1): no GitHub quota / `statusCheckRollup` |
| `rl_pr_state_gql` | `rl_pr_state` (same shape) |
| `release-hold`, `rl_hold_release_order` | refuse / no order: a human removes the `hold` tag |

**Phase 6 on `azdo`:** write the Phase-5 verdict body to a file, run `pr-labels.sh start-review`
earlier as usual, then `pr-labels.sh pass "$PR" --expect-head "$REVIEWED_HEAD" --verdict-file "$F"`
(or `fail`). `REVIEWED_HEAD` must be the full 40-hex id.

**Hold trust (azdo).** Azure comments carry no `author_association`, so `rl_hold_check` reads every commenter as a repo contributor: all comments are scanned (no tail window), so a sign-off-pending note is never pushed out by later comments. The `hold` tag stays authoritative.

**Exit codes** (as GitHub): 3 claim lost, 4 advisory, 6 follow-up unreferenced / head moved,
7 claim not held, 8 hold, 9 shadow / release not eligible, 2 usage / not ported, 1 any
other refusal. Exit 8 from `pr-labels.sh` is a hold; exit 8 from
`rl_post_verdict` on `azdo` means "cast the vote via `pr-labels.sh pass|fail`", not a hold.

**Not live-validated.** The behaviour above is exercised against the offline stubs
(`skills/tests/azdo-pr-review-no-gh.test.sh`, `azdo-pr-labels-ported.test.sh`), with one
exception: the `rl_diff_risk` route is NOT covered end to end, because the stub cannot
serve its real `git fetch` (only `rl_diff_weighted_lines` is tested, over a stubbed diff).
Also unverified against a real organisation: branch-policy shape for `--auto-merge`, vote
rendering with other reviewers, and thread-status semantics on very large PRs.
