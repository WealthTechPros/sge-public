# Azure Repos host routing

Reference for [`../SKILL.md`](../SKILL.md) — the host-adapter read routing used
by Phases 1–4 when the repo is not on GitHub. Extracted for the SKILL.md size
budget (progressive disclosure); behaviour is unchanged.

Before Phase 1, detect the host and source the PR-read shim so every read in
Phases 1–3 routes correctly without branching on the host inside each phase:

```bash
SGE_ROOT="$(bash ./scripts/resolve-sge-root.sh 2>/dev/null || bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-sge-root.sh")" || exit 1
HOST_KIND="$("$SGE_ROOT/scripts/with-repo-cwd.sh" host)"
source "$SGE_ROOT/skills/lib/host-pr-read.sh"
```

| Read operation            | GitHub (`gh`)                           | Any host (`hpr_*`)    |
|---------------------------|-----------------------------------------|-----------------------|
| View PR metadata          | `gh pr view "$PR" --json ...`           | `hpr_view "$PR"`      |
| Fetch diff                | `gh pr diff "$PR"`                      | `hpr_diff "$PR"`      |
| Read CI check statuses    | `gh pr checks "$PR" --json ...`         | `hpr_checks "$PR"`    |

**Scope:** only the non-mutating read and diff phases (Phase 1 Discovery, Phase 2
agent dispatch input, Phase 3 quality gates CI read, Phase 4 issue validation) are
routed here.

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
