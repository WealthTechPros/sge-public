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

**Azure Repos** has the full review lane (below); **Forgejo/Gitea** has the read/diff
routing here plus the bare mutators, and its gate state machine is still
GitHub-only.

**Mutating ops, Forgejo — partially deferred still (issue #2582).** `pr-labels.sh`'s full
review-gate STATE MACHINE (`start-review` claim mutex, stale-claim takeover,
`pr-reviewing`/`pr-reviewed`/`changes-requested`/`hold` transitions, heartbeats,
`sync-check`, `sge-verdict` coverage tracking, follow-up preservation gate, `gh pr
review`, `gh pr ready`) is **NOT ported to Forgejo** — that is a materially larger
slice than #2582's budget covered and remains GitHub-only. On a Forgejo repo, skip
any action that needs that state machine and log the deferral, exactly as before.

What #2582 **did** ship, reusable by a simplified Forgejo review flow if one is
built later: `skills/lib/forgejo-pr-mutate.sh` gives bare `fpr_add_label` /
`fpr_remove_label` (direct label add/remove, no claim semantics), `fpr_merge_ready`
(a degrading linked/reviewed-label/CI-green check — the reviewed-label gate only
applies when `SGE_FORGEJO_REVIEWED_LABEL` is configured for the repo) and
`fpr_merge` (squash-merge, TOCTOU-pinned to the current head SHA), plus `fpr_rerun`
(CI retrigger — Forgejo has no native failed-only rerun, only a full-retrigger
empty commit). See [`pr-monitor`'s copy of this
doc](../../pr-monitor/references/host-adapter-routing.md#mutating-ops-rerun--merge--label--issue-2582)
for the full routing table and the open cancelled-vs-failed question — this file
does not duplicate it. **Not live-validated** against a real Forgejo instance
(built without `git.feaw.co.uk` credentials or `mcp__forgejo__*` access); needs a
manual pass before any Forgejo repo's pr-review flow depends on it.

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
