#!/usr/bin/env bash
# pr-labels.sh — the single state machine for the SGE review-gate labels.
#
#   pr-reviewing  (amber)  review in progress
#   pr-reviewed   (green)  merge-gate label required by branch protection
#   pr-fixing     (amber)  CI-fix in progress — a fix-in-flight mutex (#1174)
#
# pr-reviewing / pr-reviewed are MUTUALLY EXCLUSIVE — a PR must never carry both.
# This script is the only place that transition logic lives; /sge:pr-review owns
# the review transitions, /sge:pr-monitor verifies them, /sge:pr-fix marks
# staleness AND owns the pr-fixing claim (claim-fix / release-fix below).
#
# pr-fixing is orthogonal to the review pair: it is a cross-session claim that
# ONE /sge:pr-fix agent is driving this PR's CI to green, so a second monitor
# does not dispatch a duplicate fix agent onto a branch already being
# force-pushed (issue #1174). It mirrors pr-reviewing's concurrency guard (#699)
# and stale-claim lease (#396) exactly, with its own TTL knob.
#
# Usage:
#   pr-labels.sh start-review <pr> [--force-claim]
#                                             claim review   (+pr-reviewing, -pr-reviewed)
#                                             Concurrency guard (#699): refuses (exit 3)
#                                             when another run holds a FRESH pr-reviewing
#                                             claim (younger than SGE_REVIEW_CLAIM_TTL_MIN,
#                                             default 30 minutes). Stale claims are taken
#                                             over; --force-claim overrides deliberately.
#   pr-labels.sh pass <pr> [--auto-merge] [--expect-head <sha>] [--skip-claim-check]
#                                             gate passed    (+pr-reviewed, -pr-reviewing;
#                                             Claim-check gate (#981): refuses (exit 7)
#                                             to promote a PR carrying NEITHER label —
#                                             i.e. one that never called start-review, so
#                                             pr-reviewing never appeared and the #699
#                                             concurrency guard never armed. A PR already
#                                             holding pr-reviewing (normal claim) or
#                                             pr-reviewed (re-assert/delta) proceeds.
#                                             --skip-claim-check bypasses (loud warning).
#                                             optionally enable squash auto-merge — skipped
#                                             when the repo runs its own dedicated auto-merge
#                                             bot workflow (issue #2079), deferring to it
#                                             instead; see _repo_has_dedicated_automerge_bot;
#                                             --expect-head refuses if the head moved
#                                             since the review — forces a delta re-review;
#                                             before auto-merge, a 3-way convergence check
#                                             (branch ref tip == PR head, mergeable!=UNKNOWN)
#                                             must pass with bounded backoff — see #288)
#                                             NOTE: --auto-merge / --expect-head prefer CWD
#                                             inside a clone of the PR's repo ('git ls-remote
#                                             origin'); outside a clone they fall back to the
#                                             gh REST API via GH_REPO (#662).
#                                             Thread check: cheap totalCount==0 pre-check
#                                             before the full paginated walk (#973);
#                                             fail-closed on pre-check error (#717).
#                                             Follow-up preservation gate (#859): refuses
#                                             (exit 6) when the PR body — or the review text
#                                             fed via SGE_REVIEW_FOLLOWUP_TEXT/_FILE —
#                                             declares a follow-up ("follow-up", "deferred",
#                                             "future PR", …) with no nearby issue reference,
#                                             so a follow-up cannot evaporate when the linked
#                                             issue auto-closes on merge. --skip-followup-check
#                                             bypasses it.
#                                             Human-hold gate (issue #1393): refuses (exit 8)
#                                             when the `hold` label is present — the gate
#                                             cannot open while a human sign-off is pending.
#                                             Remove the `hold` label to release the block;
#                                             the next review cycle then promotes normally.
#   pr-labels.sh fail <pr>                    gate failed    (remove BOTH labels; the
#                                             posted findings carry the state)
#   pr-labels.sh held <pr>                    review passed but a `hold` label is
#                                             present — release pr-reviewing without
#                                             applying pr-reviewed; the gate stays
#                                             closed until the hold is removed and a
#                                             new review cycle promotes normally.
#                                             Reports "pass, held for human sign-off".
#   pr-labels.sh apply-hold <pr>              apply the `hold` label (+hold); used by
#                                             /sge:pr-review when a `HOLD:` marker is
#                                             found in the PR body or a security MAJOR
#                                             finding requires human sign-off.
#   pr-labels.sh stale <pr>                   new commits after a pass (-pr-reviewed)
#   pr-labels.sh claim-fix <pr> [--force-claim]
#                                             claim a CI-fix (+pr-fixing). The
#                                             /sge:pr-fix mutex (issue #1174),
#                                             mirroring start-review's #699 guard:
#                                             refuses (exit 3) when another run
#                                             holds a FRESH pr-fixing claim
#                                             (younger than SGE_FIX_CLAIM_TTL_MIN,
#                                             default 30 minutes). Stale claims are
#                                             taken over; --force-claim overrides.
#   pr-labels.sh release-fix <pr>             release a CI-fix claim (-pr-fixing).
#                                             The binding termination contract —
#                                             /sge:pr-fix MUST call this on exit so
#                                             a crashed fix frees the lane within
#                                             the lease window. Idempotent.
#   pr-labels.sh sync-check <pr> <new-head>   strip pr-reviewed when the latest
#                                             sge-verdict's commit does not cover
#                                             <new-head> (issue #1941). Called on
#                                             pull_request:synchronize to keep the
#                                             gate label honest after a push. Posts
#                                             a comment naming the superseded SHA.
#                                             No-op when pr-reviewed is absent or
#                                             when the verdict covers the new head.
#   pr-labels.sh status <pr>                  print "reviewing=<bool> reviewed=<bool> hold=<bool>"
#                                             (Forgejo keeps the two-field form — #1419)
#                                             (issue #1147: falls back to a
#                                             GraphQL read — a separate quota
#                                             bucket — on a REST failure; see
#                                             label_status below)
# END_USAGE
#
# Defensive by design:
#   - label creation is idempotent (gh label create --force)
#   - adds tolerate the label already being present
#   - removals tolerate the label being absent (non-zero + known message → silent skip)
#   - `pass` refuses draft PRs and verifies the swap actually took (with retry)
#   - when SGE_REVIEW_ADVISORY=1 in the environment, `pass` refuses (exit 4):
#     an advisory / review-only dispatch may post a verdict comment but must
#     never move the pr-reviewed gate or arm auto-merge (issue #754). Subagents
#     inherit the parent env, so a dispatcher exports one variable and the
#     capability is gone mechanically — a conflicting prompt cannot talk past it.
#   - `pass` refuses (exit 5) while any dispatched Layer 2/3 reviewer recorded in
#     the per-PR attestation ledger never cleared rl_reviewer_ran (issue #883) —
#     the mechanical backstop that forces the guard to be consulted, mirroring
#     the exit-4 advisory gate. `start-review` resets the ledger; review-lib.sh
#     writes it (rl_reviewer_dispatch/rl_reviewer_attest). SGE_REVIEW_ATTEST_SKIP=1
#     bypasses it for a genuinely inline review with no dispatched specialists.
#   - `pass` refuses (exit 6) when a declared follow-up in the PR body / review
#     text has no issue reference (issue #859) — a follow-up whose only home is a
#     `Fixes #N` issue that auto-closes on merge would silently evaporate. The
#     reviewer must file the tracking issue first (as happened manually with
#     #847). --skip-followup-check bypasses it for a PR that declares none.
#   - `pass` refuses (exit 7) when the PR carries NEITHER label (issue #981):
#     a review that skipped `start-review` would jump straight from no label to
#     pr-reviewed, leaving no amber pr-reviewing interstitial and never arming the
#     #699 concurrency guard — the operator observed 3 PRs merged this way. The
#     claim step is now unskippable in the normal path; --skip-claim-check is the
#     loud escape hatch for a rare deliberately-unclaimed inline review.
#   - `pass` refuses (exit 8) while the `hold` label is present (issue #1393):
#     a hold is a human sign-off requirement — pr-reviewed must never be applied
#     and auto-merge must never arm while it is set. Fails CLOSED: an unreadable
#     hold state refuses. The remediation is 'pr-labels.sh held $PR' (review
#     passed; release pr-reviewing, leave hold and no pr-reviewed) + instruct the
#     operator; a new review cycle after hold removal promotes via delta fast-path.
#   - rate-limit stalls fail LOUD, not silent (issue #1147): a PR #1144 dispatch
#     ran 3+ hours and burned 268k tokens silently retrying rate-limited `gh`
#     REST calls instead of failing or switching quota buckets. `label_status`
#     now falls back to a GraphQL read (a separate quota bucket from the REST
#     calls elsewhere in this file) when its normal REST read fails, before
#     giving up; and any exhausted-quota / 403-rate-limit condition (in
#     `label_status`, `is_draft`, or the required-checks guard) posts a PR
#     comment naming the stall (best-effort) and exits non-zero rather than
#     retrying. This is purely additive — no existing fail-closed gate (thread
#     resolution, required-checks, follow-up preservation, claim-check) is
#     weakened; a rate-limit stall now fails the whole `pass`/`start-review`
#     invocation exactly as any other unreadable-state error already did.
set -euo pipefail

REVIEWING="pr-reviewing"
REVIEWED="pr-reviewed"
FIXING="pr-fixing"
HOLD="hold"

usage() {
  # awk, not sed: BSD/macOS sed rejects the `{ /re/d; p }` one-liner address
  # form ("extra characters at the end of p command"), which broke printing
  # this block exactly when a caller had the subcommand wrong (issue #1671).
  awk '/^# END_USAGE/{exit} f{sub(/^# ?/,""); print} /^# Usage:/{f=1; sub(/^# ?/,""); print}' "$0"
  exit 2
}

# ---------------------------------------------------------------------------
# Claim comment support (issue #1312)
#
# A JSON metadata block is posted alongside the pr-reviewing label so any
# actor can verify liveness and ownership without a timeline API call.
# Format:  ```sge-claim-metadata\n{"owner":"<id>","claimedAt":"<ISO>","ttl":N}\n```
# The label remains the real mutex; the comment is enrichment metadata.
# ---------------------------------------------------------------------------

CLAIM_COMMENT_FENCE="sge-claim-metadata"
# Default TTL for a claim comment in seconds. Heartbeat comments (fence
# sge-claim-heartbeat) posted by the review daemon extend the effective window.
CLAIM_COMMENT_TTL="${SGE_REVIEW_CLAIM_TTL:-900}"

# _claim_repo_full: canonical owner/repo for API calls. Prefers GH_REPO;
# falls back to gh detection. Prints nothing on failure.
_claim_repo_full() {
  printf '%s' "${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
}

# find_claim_comment: return the latest sge-claim-metadata comment as raw JSON,
# or empty string if none. Silent on failure — callers check for non-empty.
find_claim_comment() {
  local _rf
  _rf="$(_claim_repo_full)"
  [[ -n "$_rf" ]] || { printf ''; return 0; }
  # Fetch all comments and select those whose body starts with the fence.
  # --paginate so a PR with many comments is fully scanned; last // empty
  # returns the most recent claim comment or nothing.
  gh api "repos/$_rf/issues/$PR/comments" --paginate \
    --jq "[.[] | select(.body | ltrimstr(\"\n\") | startswith(\"\`\`\`${CLAIM_COMMENT_FENCE}\"))] | last // empty" \
    2>/dev/null || true
}

# parse_claim_metadata <comment-json>: extract the JSON object from inside the
# sge-claim-metadata code block. Prints the JSON or nothing on failure.
parse_claim_metadata() {
  local body meta
  body=$(printf '%s' "${1:-}" | jq -r '.body // empty' 2>/dev/null) || return 0
  # awk: extract lines between the opening fence and the next closing fence.
  meta=$(printf '%s\n' "$body" | awk "
    /^\`\`\`${CLAIM_COMMENT_FENCE}/{f=1;next}
    f && /^\`\`\`/{exit}
    f{print}
  ") || true
  printf '%s' "${meta:-}"
}

# claim_comment_live <comment-json>: return 0 (true) if the comment represents
# a live (non-stale) claim. A claim is live when claimedAt + ttl > now.
claim_comment_live() {
  local meta claimed_at ttl_val claimed_epoch now_epoch
  meta=$(parse_claim_metadata "${1:-}")
  [[ -n "$meta" ]] || return 1
  claimed_at=$(printf '%s' "$meta" | jq -r '.claimedAt // empty' 2>/dev/null) || return 1
  ttl_val=$(printf '%s' "$meta" | jq -r '.ttl // 900' 2>/dev/null) || ttl_val=900
  [[ -n "$claimed_at" ]] || return 1
  # GNU date first (Linux/Git-Bash), BSD date fallback (macOS).
  claimed_epoch=$(date -u -d "$claimed_at" +%s 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$claimed_at" +%s 2>/dev/null) || return 1
  now_epoch=$(date -u +%s)
  [[ $((claimed_epoch + ttl_val)) -gt "$now_epoch" ]]
}

# post_claim_comment: post the JSON claim comment alongside the pr-reviewing
# label. Owner is SGE_AGENT_ID if set, else the system hostname. Best-effort —
# a failure is logged but does not abort the claim (the label is the real mutex).
post_claim_comment() {
  local owner claimed_at body _rf
  owner="${SGE_AGENT_ID:-$(hostname 2>/dev/null || echo "unknown")}"
  claimed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  body="$(printf '```%s\n{"owner":"%s","claimedAt":"%s","ttl":%d}\n```' \
    "$CLAIM_COMMENT_FENCE" "$owner" "$claimed_at" "$CLAIM_COMMENT_TTL")"
  _rf="$(_claim_repo_full)"
  if [[ -z "$_rf" ]]; then
    echo "warning: PR #$PR could not determine repo for claim comment — skipping (issue #1312)" >&2
    return 0
  fi
  local comment_id
  comment_id=$(gh api "repos/$_rf/issues/$PR/comments" \
    -f body="$body" --jq '.id' 2>/dev/null) || comment_id=""
  if [[ -n "$comment_id" ]]; then
    echo "PR #$PR: claim comment posted (id=$comment_id, owner=$owner, ttl=${CLAIM_COMMENT_TTL}s)" >&2
  else
    echo "warning: PR #$PR could not post claim comment — continuing (issue #1312)" >&2
  fi
}

# delete_claim_comment: delete the latest sge-claim-metadata comment on the PR.
# Idempotent: no-op if none is found or the deletion fails (best-effort).
delete_claim_comment() {
  local comment_json comment_id _rf
  comment_json=$(find_claim_comment) || return 0
  [[ -n "$comment_json" ]] || return 0
  comment_id=$(printf '%s' "$comment_json" | jq -r '.id // empty' 2>/dev/null) || return 0
  [[ -n "$comment_id" ]] || return 0
  _rf="$(_claim_repo_full)"
  [[ -n "$_rf" ]] || return 0
  if gh api --method DELETE "repos/$_rf/issues/comments/$comment_id" >/dev/null 2>&1; then
    echo "PR #$PR: claim comment $comment_id deleted" >&2
  else
    echo "warning: PR #$PR could not delete claim comment $comment_id (best-effort)" >&2
  fi
  return 0
}
# ---------------------------------------------------------------------------

CMD="${1:-}"
PR="${2:-}"
[[ -n "$CMD" && -n "$PR" ]] || usage
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "error: <pr> must be a PR number, got '$PR'" >&2; exit 2; }

# ── Forgejo/non-GitHub host routing (issue #1239) ─────────────────────────
# Detect the git host from the current checkout's origin (or FORGEJO_ORIGIN).
# On non-GitHub hosts, label read/write operations route through forgejo-adapter.sh
# instead of gh, preserving every exit-code and output-contract in this script.
_PRL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PRL_WRC="${_PRL_SCRIPT_DIR}/../../scripts/with-repo-cwd.sh"
_PRL_ADAPTER="${_PRL_SCRIPT_DIR}/../../scripts/forgejo-adapter.sh"
_PRL_HOST="github"    # default: existing gh-based path, unchanged
_PRL_ORIGIN=""        # origin URL used to derive slug / API base for Forgejo

if [ -f "$_PRL_WRC" ] && [ -f "$_PRL_ADAPTER" ]; then
  if [ -n "${FORGEJO_ORIGIN:-}" ]; then
    _PRL_ORIGIN="$FORGEJO_ORIGIN"
  else
    _PRL_ORIGIN=$(git remote get-url origin 2>/dev/null) || _PRL_ORIGIN=""
  fi
  if [ -n "$_PRL_ORIGIN" ]; then
    # shellcheck source=scripts/with-repo-cwd.sh
    . "$_PRL_WRC"
    _PRL_HOST=$(_wrc_host_kind "$(_wrc_url_host "$_PRL_ORIGIN")")
  fi
fi

ensure_labels() {
  # Idempotent — creates if missing, updates colour/description if present.
  gh label create "$REVIEWING" --color FBCA04 --description "PR review in progress (SGE)"     --force >/dev/null
  gh label create "$REVIEWED"  --color 0E8A16 --description "Reviewed via SGE PR-review gate" --force >/dev/null
}

# The pr-fixing claim label is only created by the fix path (claim-fix), so the
# review path never materialises a label it does not use. Same idempotent shape.
ensure_fixing_label() {
  gh label create "$FIXING" --color FBCA04 --description "CI-fix in progress (SGE pr-fix)" --force >/dev/null
}

# The hold label is only created by apply-hold / the pr-review skill when it
# detects a HOLD: marker or a security MAJOR finding.  Same idempotent shape.
ensure_hold_label() {
  gh label create "$HOLD" --color B60205 --description "Held for human sign-off (SGE)" --force >/dev/null
}

# hold_status -- print "hold=<bool>" for the hold label (issue #1393). Thin
# wrapper over the shared REST→GraphQL→fail-loud reader (_read_label_state);
# fails non-zero on an unreadable state so callers fail CLOSED (hold absent must
# be proven, not assumed).
hold_status() {
  _read_label_state '"hold=\(index("hold")!=null)"' hold_status 'hold label' 1393
}

# fix_claim_status -- print "fixing=<bool>" for the pr-fixing claim (issue
# #1174). Thin wrapper over the shared reader; fails non-zero on an unreadable
# state so callers fail CLOSED.
fix_claim_status() {
  _read_label_state '"fixing=\(index("pr-fixing")!=null)"' fix_claim_status 'pr-fixing claim' 1174
}

add_label() {
  # gh tolerates re-adding an existing label; any other failure should surface.
  gh pr edit "$PR" --add-label "$1" >/dev/null
}

remove_label() {
  # Tolerate the label not being present (e.g. labelled out of band).
  # All other failures — auth, rate-limit, archived repo — surface as warnings.
  local out
  if ! out=$(gh pr edit "$PR" --remove-label "$1" 2>&1); then
    if [[ "$out" != *"Label is not associated"* && "$out" != *"not found"* ]]; then
      echo "warning: failed to remove label '$1' from PR #$PR: $out" >&2
    fi
  fi
}

# --- Rate-limit detection + fail-loud stall reporting (issue #1147) ---------
# pr-labels.sh deliberately does NOT source review-lib.sh (see the #883 ledger
# comment above) so this mirrors review-lib.sh's rl_is_rate_limit_error /
# rl_rate_limit_status / rl_rate_limit_exhausted / rl_fail_loud_rate_limited —
# keep the two in sync on any future change.

# is_rate_limit_error <text> -- 0 (true) if <text> carries a GitHub rate-limit
# signature (403 + "rate limit", "API rate limit exceeded", secondary rate
# limit, or HTTP 429). Pure string match, no network call.
is_rate_limit_error() {
  printf '%s' "${1:-}" | grep -qiE '(^|[^0-9])403([^0-9]|$).*rate limit|rate limit.*(^|[^0-9])403([^0-9]|$)|api rate limit exceeded|secondary rate limit|(^|[^0-9])429([^0-9]|$)'
}

# rate_limit_status -- print "<remaining> <limit> <reset>" for the REST core
# quota via the GraphQL rateLimit field (cost 0-1, separate bucket from the
# REST calls this script makes everywhere else). Non-zero exit on failure.
rate_limit_status() {
  gh api graphql -f query='query { rateLimit { remaining limit resetAt } }' \
    --jq '"\(.data.rateLimit.remaining) \(.data.rateLimit.limit) \(.data.rateLimit.resetAt)"' 2>/dev/null
}

# rate_limit_exhausted [floor] -- true if REST remaining <= floor (default 50,
# SGE_REVIEW_RATE_LIMIT_FLOOR). Fails CLOSED TO FALSE (assume not exhausted)
# when the status can't be read — this feeds a loud-failure decision and must
# never fabricate a positive signal from missing data.
rate_limit_exhausted() {
  local floor="${1:-${SGE_REVIEW_RATE_LIMIT_FLOOR:-50}}" status remaining
  status=$(rate_limit_status) || return 1
  remaining=$(printf '%s' "$status" | awk '{print $1}')
  [[ "$remaining" =~ ^[0-9]+$ ]] || return 1
  [[ "$remaining" -le "$floor" ]]
}

# fail_loud_rate_limited <context> -- THE #1147 fix. <context> is the failed
# gh command's captured stderr/output. If <context> itself carries a rate-
# limit signature, OR the live REST quota is exhausted, posts a best-effort PR
# comment naming the stall and returns 0 (true, "yes this was a rate-limit
# stall") so the caller can exit non-zero instead of retrying. Never loops or
# sleeps itself -- fail LOUD, not retry.
fail_loud_rate_limited() {
  local ctx="${1:-}" hit=false reason="" status=""
  if is_rate_limit_error "$ctx"; then
    hit=true
    reason="a gh call returned a rate-limit response (403/429 rate-limit signature)"
  fi
  status=$(rate_limit_status 2>/dev/null) || status=""
  if rate_limit_exhausted; then
    hit=true
    if [[ -n "$reason" ]]; then
      reason="$reason; REST quota is also exhausted (${status:-unknown})"
    else
      reason="REST rate-limit quota is exhausted (${status:-unknown} remaining/limit/reset)"
    fi
  fi
  "$hit" || return 1

  echo "STALLING ON RATE LIMIT for PR #$PR: $reason. Failing loud instead of retrying silently (issue #1147)." >&2
  local repo msg
  repo="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
  msg=$(printf 'pr-review stopped: GitHub rate-limit exhaustion detected (%s).\n\nQuota snapshot (remaining limit reset): `%s`\n\nThis run is failing loud instead of silently retrying/wedging (issue #1147). Re-run once the quota window resets.' \
    "$reason" "${status:-unknown}")
  if [[ -n "$repo" ]]; then
    gh api "repos/$repo/issues/$PR/comments" -f body="$msg" >/dev/null 2>&1 \
      || echo "fail_loud_rate_limited: could not post the stall-reason PR comment (best-effort; the stderr message above is the primary signal)" >&2
  fi
  return 0
}

# _read_label_state <jq-projection> <fn-name> <noun> <issue-ref> --
# The shared REST-read → GraphQL-fallback → rate-limit-aware-failure shape for
# reading PR label state, factored out of hold_status / label_status /
# fix_claim_status, which were near-verbatim copies of it (issue #1443).
# Behaviour is byte-identical to those three:
#   * REST first (gh pr view --json labels). stdout and stderr are captured to
#     SEPARATE files so on success we emit ONLY stdout — an incidental stderr
#     line on an exit-0 call (e.g. gh's update notifier) can never fold into the
#     "<field>=<bool> ..." contract that callers exact-match on (issue #1147).
#     Use (.labels // []) so a missing labels field doesn't crash jq. stderr is
#     folded into the error context only on the failure path below.
#   * On a REST failure, fall back to the GraphQL equivalent before giving up --
#     GraphQL draws from a SEPARATE quota bucket, so a REST-exhausted run can
#     still read label state. Needs the owner/repo split (GH_REPO if set, else a
#     best-effort `gh repo view`); skipped if neither resolves.
#     DELIBERATELY INLINE: this script must not source review-lib.sh (see the
#     #883 ledger comment near the top of this file), so this GraphQL read lives
#     here rather than as a shared review-lib.sh helper — review-lib.sh's former
#     rl_label_status_gql duplicate was removed for that reason.
#   * If both fail, fail LOUD on a rate-limit signature (issue #1147) else emit
#     the plain error; either way return non-zero so callers fail CLOSED.
# <jq-projection> is the trailing jq string interpolation ("field=..."), built
# onto BOTH the REST name array ([(.labels // []) | .[].name]) and the GraphQL
# name array, so one projection drives both reads. <fn-name>/<noun>/<issue-ref>
# only shape the log lines.
_read_label_state() {
  local projection="$1" fn_name="$2" noun="$3" issue_ref="$4"
  local rest_out rest_err rest_errfile
  rest_errfile=$(mktemp)
  if rest_out=$(gh pr view "$PR" --json labels \
      --jq "[(.labels // []) | .[].name] | $projection" \
      2>"$rest_errfile"); then
    rm -f "$rest_errfile"
    printf '%s\n' "$rest_out"
    return 0
  fi
  rest_err=$(cat "$rest_errfile" 2>/dev/null)
  rm -f "$rest_errfile"
  # GraphQL fallback — a SEPARATE quota bucket from the REST read above.
  local gql_out gql_errfile gql_nwo
  gql_errfile=$(mktemp)
  gql_nwo="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"
  if [[ -n "$gql_nwo" ]] && gql_out=$(gh api graphql -f query='
      query($owner:String!,$repo:String!,$pr:Int!){
        repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
          labels(first:50){ nodes{ name } } } } }' \
      -f owner="${gql_nwo%/*}" -f repo="${gql_nwo#*/}" -F pr="$PR" \
      --jq "[.data.repository.pullRequest.labels.nodes[].name] | $projection" \
      2>"$gql_errfile"); then
    rm -f "$gql_errfile"
    echo "PR #$PR: $fn_name recovered via GraphQL after a REST failure (issue #$issue_ref): $rest_err" >&2
    printf '%s\n' "$gql_out"
    return 0
  fi
  local gql_err
  gql_err=$(cat "$gql_errfile" 2>/dev/null)
  rm -f "$gql_errfile"
  if fail_loud_rate_limited "$rest_err"$'\n'"${gql_err:-}"; then
    echo "error: could not read $noun for PR #$PR -- rate-limit stall (issue #$issue_ref)" >&2
    return 1
  fi
  echo "error: could not read $noun for PR #$PR: $rest_err" >&2
  return 1
}

# label_status -- print "reviewing=<bool> reviewed=<bool>" (the #1147 output
# contract callers exact-match on). Thin wrapper over the shared reader.
label_status() {
  _read_label_state '"reviewing=\(index("pr-reviewing")!=null) reviewed=\(index("pr-reviewed")!=null)"' label_status 'label state' 1147
}

is_draft() {
  local val
  val=$(gh pr view "$PR" --json isDraft --jq .isDraft 2>&1) \
    || {
      if fail_loud_rate_limited "$val"; then
        echo "error: could not determine draft status for PR #$PR -- rate-limit stall (issue #1147)" >&2
      else
        echo "error: could not determine draft status for PR #$PR: $val" >&2
      fi
      return 1
    }
  [[ "$val" == "true" ]]
}

# 3-way head-convergence check (issue #288).
#
# After a push, GitHub's PR-object head SHA can lag the branch ref tip for many
# minutes while `mergeable` reads UNKNOWN. Promoting in that window enables
# squash auto-merge against the cached STALE snapshot — silently dropping the
# just-pushed commits (hit on client.onboarding #1669, 2026-06-16).
#
# Before enabling auto-merge we require all three observations to agree:
#   1. git ls-remote origin <branch>  — the authoritative branch ref tip
#   2. gh pr view --json headRefOid   — the head GitHub's PR object reports
#   3. gh pr view --json mergeable    — must not be UNKNOWN
# If they diverge (or mergeable==UNKNOWN) we wait with bounded backoff until
# convergence, and refuse to promote if it never converges. Sets the global
# CONVERGED_HEAD to the agreed SHA on success.
#
# Distinct from #1085 webhook-suppression handling — both can apply to one PR.
CONVERGED_HEAD=""
await_head_convergence() {
  local head_ref ref_tip pr_head mergeable
  head_ref=$(gh pr view "$PR" --json headRefName --jq .headRefName 2>&1) \
    || { echo "error: could not read headRefName for PR #$PR: $head_ref" >&2; return 1; }

  # Bounded backoff (issue #973): 0,2,3,5,8,13,21,30,30,30s — ~2.4 min total
  # before giving up. Fibonacci-tightened early attempts vs. the prior
  # 0,5,10,15,20,25,30,30,30,30s (~3.25 min) — convergence typically
  # completes on attempt 2 in practice (the branch-ref/PR-object lag this
  # guards against is usually sub-5s), so the original 5s floor on the
  # first retry paid a stall most passing PRs never needed. Same 10-attempt
  # count and the same 30s per-attempt cap on the later attempts, so the
  # correctness guarantee (retry until convergence or exhaustion) and the
  # protection against real, longer-lived staleness are unchanged — only
  # the *average* latency for the common near-immediate-convergence case
  # drops, not the ceiling's ability to wait out a genuinely slow case.
  local delays=(0 2 3 5 8 13 21 30 30 30)
  local attempt
  for attempt in "${!delays[@]}"; do
    [[ "${delays[$attempt]}" -gt 0 ]] && sleep "${delays[$attempt]}"

    # Rate-limit check (issue #1147): this loop retries up to 10 times over
    # ~2.4 min. Without this check, a rate-limited quota would make every
    # remaining attempt fail the same way for no new information — burning
    # the full bound before falling through to the generic "did not converge"
    # refusal with no indication WHY. Detect it on the FIRST attempt where the
    # quota is already exhausted and fail loud immediately instead of paying
    # out the rest of the bound.
    if [[ "$attempt" -gt 0 ]] && rate_limit_exhausted; then
      fail_loud_rate_limited "" || true
      echo "refusing: PR #$PR convergence check aborted early (attempt $((attempt+1))/${#delays[@]}) — REST rate limit exhausted (issue #1147)" >&2
      return 1
    fi

    # 1. Branch ref tip (authoritative) — column 1 of the matching ls-remote row.
    # || true: transient failures (network, GitHub 5xx) must not abort via set -euo pipefail;
    # the convergence condition handles empty strings correctly by continuing to retry.
    ref_tip=$(git ls-remote origin "refs/heads/$head_ref" 2>/dev/null | awk 'NR==1{print $1}') || true
    if [[ -z "$ref_tip" ]]; then
      # Control-session fallback (the pr-labels.sh slice of #662): when CWD is not
      # inside a clone of the PR's repo, `git ls-remote origin` resolves nothing
      # (or the wrong repo's remote is absent) and the check would spin to refusal.
      # Resolve the branch ref tip via the REST API instead — GH_REPO (or gh's cwd
      # detection) names the repo, matching how every other call here targets it.
      _CONV_REPO="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
      if [[ -n "$_CONV_REPO" ]]; then
        ref_tip=$(gh api "repos/${_CONV_REPO}/git/ref/heads/${head_ref}" --jq .object.sha 2>/dev/null) || true
      fi
    fi
    # 2. PR-object head as GitHub reports it.
    pr_head=$(gh pr view "$PR" --json headRefOid --jq .headRefOid 2>/dev/null) || true
    # 3. Mergeability — must resolve away from UNKNOWN.
    mergeable=$(gh pr view "$PR" --json mergeable --jq .mergeable 2>/dev/null) || true

    echo "PR #$PR: convergence check (attempt $((attempt+1))/${#delays[@]}) — ref_tip=${ref_tip:0:9} pr_head=${pr_head:0:9} mergeable=${mergeable:-?}" >&2

    if [[ -n "$ref_tip" && -n "$pr_head" && "$ref_tip" == "$pr_head" \
          && -n "$mergeable" && "$mergeable" != "UNKNOWN" ]]; then
      CONVERGED_HEAD="$ref_tip"
      echo "PR #$PR: heads converged at ${CONVERGED_HEAD:0:9} (mergeable=$mergeable)" >&2
      return 0
    fi
  done

  echo "refusing: PR #$PR heads did not converge — ref_tip=${ref_tip:0:9} pr_head=${pr_head:0:9} mergeable=${mergeable:-?}" >&2
  echo "GitHub's PR object is lagging the branch ref or mergeability is UNKNOWN; auto-merge would risk squashing a stale snapshot. Retry once GitHub catches up." >&2
  return 1
}

# Required-check guard (issue #885).
#
# Phase 5's aggregate verdict reviews code CONTENT; it is blind to an
# independently-red REQUIRED non-code gate (spec-drift, issue-link, a CI job).
# Arming squash auto-merge in that window tells the rest of the fleet the PR is
# clean and mergeable while a required check is still FAILURE/pending — exactly
# the ppp #10098 incident (2026-07-06): a self-review armed auto-merge with
# 'Spec-drift' and 'PR issue link' both failing; a second reviewer caught it
# ~10 min later. The head-convergence guard (#288) does NOT cover this: heads
# can be perfectly converged and mergeable != UNKNOWN while a required check is
# red — mergeable reflects conflicts/branch state, not check conclusions.
#
# Before arming auto-merge we hard-check the required-check rollup and REFUSE
# (return 1 → the caller exit 1s: no label swap, no arm) if ANY genuinely-
# required check is not green (bucket is fail/pending/cancel — i.e. FAILURE,
# TIMED_OUT, or still pending). Mirrors await_head_convergence: runs only when
# --auto-merge is requested, and fails the whole `pass` rather than arming
# against a red gate. Fails CLOSED — an unreadable/unparseable rollup refuses
# rather than arming blind; only an explicit "no required checks" no-ops.
# Name of the self-referential branch-protection check owned by the pr-reviewed
# label gate (job name in .github/workflows/require-pr-reviewed-label.yml). It
# only goes green AFTER `pass` applies pr-reviewed — which is exactly the swap
# about to happen — so counting it as a red required check self-deadlocks
# `pass --auto-merge` on every repo where the label gate is required (issue
# #1166). It is excluded from the green guard because it is definitionally red
# pre-swap and is OWNED by the transition being performed; every other check
# keeps its full fail-closed weight.
# Overridable per-repo via SGE_SELF_LABEL_CHECK_NAME (issue #2185): the literal
# job name varies by repo (e.g. ppp's gate job is "PR reviewed merge gate", not
# the historical default) — a hardcoded name never matches there, so the
# self-exclusion silently fails to apply and the gate's own expected-red
# pre-swap state permanently blocks `pass --auto-merge`.
SELF_LABEL_CHECK_NAME="${SGE_SELF_LABEL_CHECK_NAME:-Require pr-reviewed label}"

assert_required_checks_green() {
  local raw rc err errfile
  errfile=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/sge-rcg.$$")
  # --required narrows to genuinely-required checks so an optional red check
  # does not block arming. --json forces machine output; capture regardless of
  # gh's pass/fail/pending exit code so set -euo pipefail does not abort here.
  rc=0
  raw=$(gh pr checks "$PR" --required --json name,state,bucket 2>"$errfile") || rc=$?
  err=$(cat "$errfile" 2>/dev/null)
  rm -f "$errfile"

  # Does the payload parse as a JSON array? (jq -e: exit non-zero on empty/garbage.)
  if [[ "$(jq -e 'type=="array"' <<<"$raw" 2>/dev/null)" == "true" ]]; then
    local total not_green
    total=$(jq 'length' <<<"$raw" 2>/dev/null) || total=0
    if [[ "${total:-0}" -eq 0 ]]; then
      echo "PR #$PR: no required checks reported — required-check guard is a no-op (issue #885)" >&2
      return 0
    fi
    not_green=$(jq -r --arg self "$SELF_LABEL_CHECK_NAME" '[ .[] | select((.name // "") != $self) | select((.bucket // "") as $b | $b != "pass" and $b != "skipping") ] | length' <<<"$raw" 2>/dev/null) \
      || { echo "refusing: PR #$PR — could not parse required-check rollup; required-check guard fails closed (issue #885)" >&2; return 1; }
    if [[ "${not_green:-1}" -gt 0 ]]; then
      echo "refusing: PR #$PR has required check(s) not green — will NOT arm auto-merge (issue #885):" >&2
      jq -r --arg self "$SELF_LABEL_CHECK_NAME" '.[] | select((.name // "") != $self) | select((.bucket // "") as $b | $b != "pass" and $b != "skipping")
             | "  [\(.bucket // "?")] \(.name // "?") (state=\(.state // "?"))"' <<<"$raw" >&2 || true
      echo "A required gate is FAILURE/pending; arming auto-merge would signal the PR is clean while it is not. Fix the red check(s), then re-run pass --auto-merge." >&2
      return 1
    fi
    return 0
  fi

  # Non-array payload. gh emits a 'no checks'/'no required checks' notice (with
  # empty stdout) when nothing is required — a legitimate no-op; arm as before.
  # By this point await_head_convergence has already exercised gh successfully,
  # so auth/network are proven working and an empty-with-that-notice really is
  # "nothing required", not a transient failure.
  if [[ -z "${raw//[[:space:]]/}" ]] && printf '%s' "$err" | grep -qiE 'no (required )?checks'; then
    echo "PR #$PR: no required checks reported — required-check guard is a no-op (issue #885)" >&2
    return 0
  fi

  # Anything else — empty with an unrecognised error, or unparseable output —
  # is unverifiable. Fail CLOSED rather than arm blind. (issue #1147: if this
  # unreadable state IS a rate-limit stall, name it loudly and post the PR
  # comment rather than leaving the operator to guess from a bare "unreadable"
  # message — the fail-closed refusal itself is unchanged either way.)
  if fail_loud_rate_limited "$err"; then
    echo "refusing: PR #$PR — required-check rollup unreadable due to rate-limit exhaustion; required-check guard fails closed (issue #885, loud stall per #1147)" >&2
  else
    echo "refusing: PR #$PR — required-check rollup unreadable (gh rc=$rc); required-check guard fails closed (issue #885)" >&2
    [[ -n "$err" ]] && echo "  gh: $err" >&2
  fi
  return 1
}

# Follow-up preservation gate (issue #859).
#
# A PR that declares a "follow-up" / "deferred" item — in its body or in the
# review's own text — but closes its linked issue via `Fixes #N` auto-close on
# merge silently DESTROYS that follow-up's only durable home. PR #844 (issue
# #802) declared the sourcePaths backfill as a follow-up in its body; the issue
# would have auto-closed on merge and the follow-up would have evaporated — a
# reviewer noticed by luck and filed #847 to preserve it. Nothing in the pass
# path checked that declared follow-ups had somewhere to live before auto-merge
# was armed.
#
# This gate greps the PR body (and any review text the caller feeds via
# SGE_REVIEW_FOLLOWUP_TEXT / SGE_REVIEW_FOLLOWUP_FILE) for follow-up markers and
# REFUSES the pass (return 1 → no label swap, no auto-merge arm) if any marker
# line lacks an issue reference (#N / issues/N / GH-N) within a small lookahead
# window — a heading like "## Follow-ups" immediately above a list of items each
# carrying a #N therefore passes, while a lone prose "…as a follow-up." with no
# nearby number is blocked. The refusal names each unpreserved follow-up and
# tells the reviewer to file the issue first — exactly the manual #847
# remediation. Cheap, mechanical, fits the pr-labels.sh script-extraction
# pattern (#820). --skip-followup-check bypasses it (mirrors --skip-thread-check);
# SGE_FOLLOWUP_MARKERS / SGE_FOLLOWUP_LOOKAHEAD tune the markers and window.
# Fails CLOSED: an unreadable PR body refuses rather than arming blind.
assert_followups_preserved() {
  local body rc extra=""
  rc=0
  # Forgejo path (issue #1239): read PR body via the REST adapter instead of gh.
  if [[ "${_PRL_HOST:-github}" == "forgejo" ]]; then
    body=$("$_PRL_ADAPTER" pr-body "$_PRL_ORIGIN" "$PR" 2>/dev/null) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "refusing: PR #$PR — could not read PR body from Forgejo adapter; follow-up preservation gate fails closed (issue #859, issue #1239)" >&2
      echo "Fix adapter access (token, allow-list, network) and retry, or pass --skip-followup-check if this PR declares no follow-ups." >&2
      return 1
    fi
  else
    body=$(gh pr view "$PR" --json body --jq '.body // ""' 2>/dev/null) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "refusing: PR #$PR — could not read PR body; follow-up preservation gate fails closed (issue #859)" >&2
      echo "Fix gh access (auth, rate limit, network) and retry, or pass --skip-followup-check if this PR declares no follow-ups." >&2
      return 1
    fi
  fi
  # The review's own text, when the caller feeds it (Phase 8 exports it before
  # promoting) — so a follow-up declared only in the review, never in the PR
  # body, is caught too. Both channels are optional; absent = body-only scan.
  [[ -n "${SGE_REVIEW_FOLLOWUP_TEXT:-}" ]] && extra+=$'\n'"${SGE_REVIEW_FOLLOWUP_TEXT}"
  if [[ -n "${SGE_REVIEW_FOLLOWUP_FILE:-}" && -r "${SGE_REVIEW_FOLLOWUP_FILE}" ]]; then
    extra+=$'\n'"$(cat "${SGE_REVIEW_FOLLOWUP_FILE}")"
  fi

  local markers issueref look negations
  # Lowercased ERE (the awk below lowercases each line before matching).
  # "pr" markers require a word boundary after "pr"/"prs" (s?([^a-z]|$)) so
  # they match "future PR"/"separate PR"/"later PR" and their plurals
  # ("later PRs", "separate PRs") but not substrings inside ordinary words
  # like "product" or "print" (issue: false-positive on "separate product"
  # in licence-text PRs sge#2172 / sge-public#44 — awk ERE has no \b, so the
  # boundary is spelled out explicitly). The optional "s" must sit INSIDE the
  # boundary check (prs?(...)), not after it (pr(...)s?) — the latter would
  # silently stop matching plurals entirely (caught in review: the old bare
  # substring match happened to catch "PRs" by accident; a naive boundary fix
  # regressed it to zero plural matches, which is a fail-open detection gap,
  # not just a leftover false positive).
  markers="${SGE_FOLLOWUP_MARKERS:-follow[ -]?up|deferred|future prs?([^a-z]|$)|separate prs?([^a-z]|$)|later prs?([^a-z]|$)|in a follow}"
  issueref='#[0-9]+|issues/[0-9]+|gh-[0-9]+'
  look="${SGE_FOLLOWUP_LOOKAHEAD:-3}"
  [[ "$look" =~ ^[0-9]+$ ]] || look=3
  # Negation cue words (issue #1027): a marker match is NOT a declared
  # follow-up when one of these directly precedes it (within the 3 words
  # immediately before the match, e.g. "no deferred-completion exit path",
  # "not a follow-up", "no separate PR is needed"). Apostrophes are stripped
  # from the prefix BEFORE it is split into words, so contracted negations
  # ("isn't"/"doesn't"/"can't") collapse to their bare forms and match.
  negations="${SGE_FOLLOWUP_NEGATIONS:-no|not|never|isnt|arent|wasnt|werent|doesnt|dont|didnt|hasnt|havent|wont|wouldnt|cannot|cant|without}"

  local report
  report=$(printf '%s\n%s\n' "$body" "$extra" | awk \
      -v markers="$markers" -v issueref="$issueref" -v look="$look" -v negations="$negations" '
    { sub(/\r$/, ""); line[NR] = $0 }
    END {
      n = NR; bad = 0
      negre = "^(" negations ")$"
      for (i = 1; i <= n; i++) {
        lo = tolower(line[i])
        # Walk EVERY marker occurrence on the line (not just the first): a
        # line may both rule out one follow-up AND declare another, so the
        # negation decision is scoped to each occurrence, never the whole
        # line (issue #1027 defect 1: a whole-line skip fails OPEN when a
        # negated marker masks a later genuinely-undeclared one).
        s = lo; base = 0; active = 0
        while (match(s, markers)) {
          occ_start = base + RSTART      # 1-based offset of this match within lo
          mlen = RLENGTH
          # Negation check for THIS occurrence: is one of the (up to) 3 words
          # immediately before it a negation cue? If so this occurrence rules
          # OUT a follow-up — suppress it and keep scanning the rest of the line.
          prefix = substr(lo, 1, occ_start - 1)
          gsub(/'"'"'/, "", prefix)      # strip apostrophes: isn'"'"'t -> isnt
          nw = split(prefix, w, /[^a-z]+/)
          while (nw > 0 && w[nw] == "") nw--
          lo3 = nw - 2; if (lo3 < 1) lo3 = 1
          negated = 0
          for (k = lo3; k <= nw; k++) {
            if (w[k] ~ negre) { negated = 1; break }
          }
          if (!negated) { active = 1; break }   # a real, non-negated marker
          adv = RSTART + mlen; if (adv < 1) adv = 1
          base = base + adv - 1
          s = substr(s, adv)
        }
        if (active) {
          found = 0
          hi = i + look; if (hi > n) hi = n
          for (j = i; j <= hi; j++) {
            if (tolower(line[j]) ~ issueref) { found = 1; break }
          }
          if (!found) {
            bad++
            t = line[i]; sub(/^[[:space:]]+/, "", t)
            printf("UNPRESERVED\t%s\n", substr(t, 1, 120))
          }
        }
      }
      printf("BADCOUNT\t%d\n", bad)
    }')

  local bad
  bad=$(printf '%s\n' "$report" | awk -F'\t' '$1=="BADCOUNT"{print $2}')
  [[ "$bad" =~ ^[0-9]+$ ]] || bad=0
  if [[ "$bad" -gt 0 ]]; then
    echo "refusing: PR #$PR declares $bad follow-up item(s) with no issue reference — will NOT open the $REVIEWED gate or arm auto-merge (issue #859):" >&2
    printf '%s\n' "$report" | awk -F'\t' '$1=="UNPRESERVED"{print "  - " $2}' >&2
    echo "A declared follow-up with no issue number evaporates when the linked issue auto-closes on merge (this happened on PR #844 → salvaged as #847)." >&2
    echo "File a tracking issue for each follow-up first, put its #number beside the follow-up in the PR body (or review text), then re-run pass. Bypass: --skip-followup-check." >&2
    return 1
  fi
  return 0
}

# ── Dedicated auto-merge bot detection (issue #2079) ──────────────────────
# Several WTP repos run their own dedicated "SGD/SGE Auto-Approve & Merge"
# GitHub Actions workflow (pull_request_target, triggered on the pr-reviewed
# label) that mints a proper GitHub App token and does its own full
# approve+merge sequence, attributing the merge to a bot identity. When such
# a workflow exists, this script's own `gh pr merge --squash --auto` (below)
# races it: whichever mechanism actually executes the merge determines the
# audit-trail attribution, and this script's own --auto arm runs under
# whatever `gh` session is invoking it — the operator's own account in an
# interactive session, not a bot. Observed live: adviser-mcp#160 merged as
# the human operator because this script's --auto arm won the race, while
# adviser-mcp#162 (reviewed moments later, same session) merged cleanly via
# the bot. Detecting the dedicated workflow and skipping the local arm in
# that case removes the race at the root; repos without one keep the
# existing --auto fallback unchanged.
_repo_has_dedicated_automerge_bot() {
  local toplevel hit cwd_remote
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  # PR #2081 review follow-up: this function only ever reads the LOCAL
  # working tree, so if GH_REPO names a different repo than the one CWD is
  # actually a clone of — the documented "gh-only, no cd" control-session
  # mode (this skill's own SKILL.md "Target repo" section: "export
  # GH_REPO=owner/repo for gh-only work; every gh call/script honours it")
  # — trusting CWD would answer about the WRONG repo. Both directions are
  # unsafe: a hub session whose own CWD happens to carry the marker
  # (verified live: both `sge` and `wtp-org` do) would falsely report a bot
  # for a bot-less target repo, permanently skipping the local --auto arm
  # and leaving that PR unmerged by anything; the converse falsely reports
  # no bot and reintroduces the #2079 race for a repo that has one. So when
  # GH_REPO is set, confirm CWD's own remote actually names that repo before
  # trusting the local tree; otherwise refuse to answer — fall through to
  # the pre-existing --auto arm, the same safe direction every other failure
  # mode below already falls to. A GH_REPO-only session simply doesn't get
  # this optimisation rather than getting a wrong one; `cd`-based invocation
  # (the documented preferred mode) is unaffected.
  if [ -n "${GH_REPO:-}" ]; then
    cwd_remote="$(git -C "$toplevel" remote get-url origin 2>/dev/null)" || cwd_remote=""
    case "$cwd_remote" in
      *"$GH_REPO"*) : ;;
      *) return 1 ;;
    esac
  fi
  [ -d "$toplevel/.github/workflows" ] || return 1
  # find, not a shell glob loop: a glob pattern that matches nothing (e.g.
  # *.yaml when every workflow here is *.yml) errors out under zsh and any
  # bash with `failglob` set, silently skipping the whole check rather than
  # just that one pattern — find has no such failure mode. Match on the
  # workflow's own self-description, not its filename (which varies:
  # sgd-auto-merge.yml vs sge-auto-merge.yml) — every known instance of this
  # pattern carries this exact marker comment. `-exec … ; -print -quit`
  # stops at the first match; grep -l -q keeps it a pure boolean test.
  hit="$(find "$toplevel/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) \
    -exec grep -lq "Standing automation for WealthTech Pros' Model-B autonomous review loop" {} \; -print -quit 2>/dev/null)"
  [ -n "$hit" ]
}

# ── Forgejo function overrides (issue #1239) ──────────────────────────────
# Redefine the gh-calling label helpers for the Forgejo/Gitea REST adapter path.
# Output contracts (label_status → "reviewing=<bool> reviewed=<bool>",
# fix_claim_status → "fixing=<bool>") and call signatures are preserved exactly.
# The exit-code contract (3/4/5/6/7) is preserved: every guard that inspects
# label state now reads via the adapter, so the same logic fires the same exit.
if [ "$_PRL_HOST" = "forgejo" ]; then
  # All mutating adapter calls in this block need FORGEJO_ADAPTER_ALLOW_WRITE=1.
  export FORGEJO_ADAPTER_ALLOW_WRITE=1

  add_label() {
    "$_PRL_ADAPTER" pr-add-label "$_PRL_ORIGIN" "$PR" "$1" >/dev/null
  }

  remove_label() {
    local _out
    if ! _out=$("$_PRL_ADAPTER" pr-remove-label "$_PRL_ORIGIN" "$PR" "$1" 2>&1); then
      echo "warning: failed to remove label '$1' from PR #$PR (Forgejo): $_out" >&2
    fi
  }

  label_status() {
    local _out _errfile
    _errfile=$(mktemp)
    if _out=$("$_PRL_ADAPTER" pr-label-status "$_PRL_ORIGIN" "$PR" 2>"$_errfile"); then
      rm -f "$_errfile"
      printf '%s\n' "$_out"
      return 0
    fi
    local _err
    _err=$(cat "$_errfile" 2>/dev/null)
    rm -f "$_errfile"
    echo "error: could not read label state for PR #$PR (Forgejo adapter): $_err" >&2
    return 1
  }

  fix_claim_status() {
    local _out _errfile
    _errfile=$(mktemp)
    if _out=$("$_PRL_ADAPTER" pr-fix-claim-status "$_PRL_ORIGIN" "$PR" 2>"$_errfile"); then
      rm -f "$_errfile"
      printf '%s\n' "$_out"
      return 0
    fi
    local _err
    _err=$(cat "$_errfile" 2>/dev/null)
    rm -f "$_errfile"
    echo "error: could not read pr-fixing claim for PR #$PR (Forgejo adapter): $_err" >&2
    return 1
  }

  ensure_labels() {
    "$_PRL_ADAPTER" pr-ensure-label "$_PRL_ORIGIN" \
      "pr-reviewing" "FBCA04" "PR review in progress (SGE)"
    "$_PRL_ADAPTER" pr-ensure-label "$_PRL_ORIGIN" \
      "pr-reviewed"  "0E8A16" "Reviewed via SGE PR-review gate"
  }

  ensure_fixing_label() {
    "$_PRL_ADAPTER" pr-ensure-label "$_PRL_ORIGIN" \
      "pr-fixing" "FBCA04" "CI-fix in progress (SGE pr-fix)"
  }

  is_draft() {
    local _val _errfile
    _errfile=$(mktemp)
    if ! _val=$("$_PRL_ADAPTER" pr-is-draft "$_PRL_ORIGIN" "$PR" 2>"$_errfile"); then
      local _err
      _err=$(cat "$_errfile" 2>/dev/null)
    rm -f "$_errfile"
      echo "error: could not determine draft status for PR #$PR (Forgejo adapter): $_err" >&2
      return 1
    fi
    rm -f "$_errfile"
    [[ "$_val" == "true" ]]
  }
fi

case "$CMD" in
  start-review)
    # Concurrency guard (issue #699 + #1312): pr-reviewing is the claim label.
    # Two independent review passes on the same PR burn a duplicate ~100k+ token
    # specialist fan-out for zero marginal value.
    #
    # Primary check (issue #1312): if a live sge-claim-metadata comment exists
    # (claimedAt + ttl not elapsed), another review agent owns this PR — refuse
    # with exit 3. The comment carries owner identity and an explicit TTL so the
    # check is independent of the label-event timeline API. A stale comment is
    # deleted before proceeding so the new claim starts with clean metadata.
    #
    # Fallback (backward compat, issue #699): if there is no claim comment but
    # the pr-reviewing label is present, fall back to the label-event timestamp
    # check (for claims placed before #1312 was deployed).
    #
    # The guard is advisory and SELF-EXPIRING: a stale claim is taken over, and
    # any failure to determine the claim age degrades to a warning + proceed —
    # it is a back-off hint, never a hard lock that could wedge the pipeline.
    # --force-claim overrides all checks.
    FORCE_CLAIM=false
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --force-claim) FORCE_CLAIM=true; shift ;;
        *) echo "error: unknown option '$1' for start-review" >&2; exit 2 ;;
      esac
    done
    if [[ "$FORCE_CLAIM" != "true" ]]; then
      # Primary: claim comment TTL check (issue #1312).
      _CLAIM_JSON=$(find_claim_comment)
      if [[ -n "$_CLAIM_JSON" ]]; then
        if claim_comment_live "$_CLAIM_JSON"; then
          _CLAIM_OWNER=$(parse_claim_metadata "$_CLAIM_JSON" \
            | jq -r '.owner // "unknown"' 2>/dev/null) || _CLAIM_OWNER="unknown"
          echo "refusing: PR #$PR has a live claim comment (owner=${_CLAIM_OWNER}) — another review is in flight (issue #1312)" >&2
          echo "The claim self-expires after ${CLAIM_COMMENT_TTL}s (SGE_REVIEW_CLAIM_TTL); re-run with --force-claim to take over deliberately." >&2
          exit 3
        fi
        # Stale claim comment — delete it before re-claiming.
        echo "PR #$PR: existing claim comment is stale — deleting before re-claiming (issue #1312)" >&2
        delete_claim_comment
      else
        # Fallback: no claim comment → label-event timestamp check (issue #699,
        # backward compat with old-style claims that predate #1312).
        CUR_STATUS=$(label_status 2>/dev/null) || CUR_STATUS=""
        if [[ "$CUR_STATUS" == *"reviewing=true"* ]]; then
          CLAIM_TTL_MIN="${SGE_REVIEW_CLAIM_TTL_MIN:-30}"
          REPO_FULL="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
          CLAIMED_AT=""
          if [[ -n "$REPO_FULL" ]]; then
            # Most recent `labeled` event for pr-reviewing = when the claim was taken.
            CLAIMED_AT=$(gh api "repos/$REPO_FULL/issues/$PR/timeline" --paginate \
              --jq '.[] | select(.event=="labeled" and .label.name=="pr-reviewing") | .created_at' \
              2>/dev/null | tail -n 1) || CLAIMED_AT=""
          fi
          CLAIMED_EPOCH=""
          if [[ -n "$CLAIMED_AT" && "$CLAIMED_AT" != "null" ]]; then
            # GNU date first (Linux/Git-Bash), BSD date fallback (macOS).
            CLAIMED_EPOCH=$(date -u -d "$CLAIMED_AT" +%s 2>/dev/null \
              || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$CLAIMED_AT" +%s 2>/dev/null) || CLAIMED_EPOCH=""
          fi
          if [[ -n "$CLAIMED_EPOCH" ]]; then
            CLAIM_AGE_MIN=$(( ($(date -u +%s) - CLAIMED_EPOCH) / 60 ))
            if [[ "$CLAIM_AGE_MIN" -lt "$CLAIM_TTL_MIN" ]]; then
              echo "refusing: PR #$PR already carries $REVIEWING — claimed ${CLAIM_AGE_MIN}m ago (< ${CLAIM_TTL_MIN}m TTL); another review pass is likely in flight (issue #699)" >&2
              echo "Back off instead of running a duplicate review. The claim self-expires after ${CLAIM_TTL_MIN}m (SGE_REVIEW_CLAIM_TTL_MIN); re-run with --force-claim to take over deliberately." >&2
              exit 3
            fi
            echo "PR #$PR: existing $REVIEWING claim is stale (${CLAIM_AGE_MIN}m >= ${CLAIM_TTL_MIN}m) — taking over (issue #699)" >&2
          else
            echo "warning: PR #$PR carries $REVIEWING but the claim age could not be determined — proceeding (advisory guard, issue #699)" >&2
          fi
        fi
      fi
    fi
    ensure_labels
    # Reset the #883 attestation ledger — a fresh review pass starts with an
    # empty dispatched-reviewer roster (matches review-lib.sh rl_attest_reset).
    _ATTEST_DIR="${SGE_REVIEW_STATE_DIR:-${TMPDIR:-${TEMP:-/tmp}}}"
    _ATTEST_REPO="${GH_REPO:-local}"; _ATTEST_REPO="${_ATTEST_REPO//[^A-Za-z0-9._-]/_}"
    : > "${_ATTEST_DIR}/sge-review-attest.${_ATTEST_REPO}.${PR}" 2>/dev/null || true
    add_label "$REVIEWING"
    remove_label "$REVIEWED"        # any prior pass is void once a review restarts
    # Post the claim comment alongside the label (issue #1312 AC1). Best-effort —
    # the label is the real mutex; the comment carries owner+TTL metadata.
    post_claim_comment
    STATUS="$(label_status)" || STATUS="(label_status unavailable)"
    echo "PR #$PR: review claimed ($STATUS)"
    ;;

  pass)
    # Advisory-mode mechanical guard (issue #754): when a dispatcher exports
    # SGE_REVIEW_ADVISORY=1, this run is a review-ONLY dispatch — it may post a
    # verdict comment but must never move the merge-gate labels or arm auto-merge.
    # This is the mechanical backstop for the two live incidents where a review
    # agent holding a conflicting operator prompt applied pr-reviewed and armed
    # auto-merge anyway: faithful execution of the loaded skill WAS the violation,
    # and prose restrictions demonstrably failed (2/2). Subagents inherit the
    # parent env, so one exported variable removes the capability — it cannot be
    # talked past. `pass` is also the sole place --auto-merge is armed, so
    # refusing the whole action covers auto-merge arming too. Distinct exit 4.
    if [[ "${SGE_REVIEW_ADVISORY:-}" == "1" ]]; then
      echo "refusing: SGE_REVIEW_ADVISORY=1 — advisory (review-only) dispatch: 'pass' cannot move the $REVIEWED gate or arm auto-merge (issue #754)" >&2
      echo "Post the review verdict as a comment (mode: advisory) instead. To promote the gate, re-run without SGE_REVIEW_ADVISORY set in the environment." >&2
      exit 4
    fi
    # Mechanical subagent-execution gate (issue #883): rl_reviewer_ran is only
    # useful if it is actually consulted — twice a dispatched specialist returned
    # ZERO tool calls and the parent verdict trusted it as a clean pass. The
    # review procedure records each dispatched Layer 2/3 reviewer as PENDING in a
    # per-PR ledger (rl_reviewer_dispatch) and clears it only after it passes
    # rl_reviewer_ran (rl_reviewer_attest). If ANY dispatched reviewer never
    # cleared the guard, refuse the gate here — the same env/state backstop shape
    # as SGE_REVIEW_ADVISORY above (prose-only "call the guard" fails on subagents,
    # #754). No ledger / 0 pending = inline or no-fan-out review = proceeds. This
    # reads the SAME file+format written by review-lib.sh (which pr-labels.sh does
    # not source); keep the two in sync. Distinct exit 5.
    if [[ "${SGE_REVIEW_ATTEST_SKIP:-}" != "1" ]]; then
      _ATTEST_DIR="${SGE_REVIEW_STATE_DIR:-${TMPDIR:-${TEMP:-/tmp}}}"
      _ATTEST_REPO="${GH_REPO:-local}"
      _ATTEST_REPO="${_ATTEST_REPO//[^A-Za-z0-9._-]/_}"
      _ATTEST_FILE="${_ATTEST_DIR}/sge-review-attest.${_ATTEST_REPO}.${PR}"
      _ATTEST_PENDING=0
      if [[ -f "$_ATTEST_FILE" ]]; then
        # A present ledger MUST parse to a count; if awk fails or returns a
        # non-number, fail CLOSED (treat as pending) — never read a parse
        # failure as "0 unresolved" (same posture as the #717 thread gate).
        if _ATTEST_PENDING=$(awk -F'\t' '
              $1=="dispatch" { pend[$2]=1 }
              $1=="attest"   { delete pend[$2] }
              END { n=0; for (a in pend) n++; print n }
            ' "$_ATTEST_FILE"); then
          [[ "$_ATTEST_PENDING" =~ ^[0-9]+$ ]] || _ATTEST_PENDING=1
        else
          _ATTEST_PENDING=1
        fi
      fi
      if [[ "$_ATTEST_PENDING" =~ ^[0-9]+$ && "$_ATTEST_PENDING" -gt 0 ]]; then
        echo "refusing: $_ATTEST_PENDING dispatched reviewer(s) never cleared rl_reviewer_ran (issue #883) — their (non-)result must not be trusted as a clean pass" >&2
        echo "Re-run each unattested Layer 2/3 agent (or do its check inline) and clear it via rl_reviewer_attest before 'pass'. Ledger: $_ATTEST_FILE" >&2
        echo "SGE_REVIEW_ATTEST_SKIP=1 bypasses this only for a genuinely inline review with no dispatched specialists." >&2
        exit 5
      fi
    fi
    if is_draft; then
      echo "refusing: PR #$PR is a DRAFT — drafts never receive $REVIEWED or auto-merge" >&2
      exit 1
    fi
    # Parse options (order-independent): --auto-merge, --expect-head <sha>,
    # --skip-thread-check, --skip-followup-check, --skip-claim-check,
    # --thread-cache <file>, --thread-cache-head <sha>
    AUTO_MERGE=false; EXPECT_HEAD=""; SKIP_THREAD_CHECK=false; SKIP_FOLLOWUP_CHECK=false; SKIP_CLAIM_CHECK=false
    THREAD_CACHE=""; THREAD_CACHE_HEAD=""
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --auto-merge) AUTO_MERGE=true; shift ;;
        --expect-head)
          [[ $# -ge 2 ]] || { echo "error: --expect-head needs a SHA" >&2; exit 2; }
          EXPECT_HEAD="$2"; shift 2 ;;
        --thread-cache)
          [[ $# -ge 2 ]] || { echo "error: --thread-cache needs a file path" >&2; exit 2; }
          THREAD_CACHE="$2"; shift 2 ;;
        --thread-cache-head)
          [[ $# -ge 2 ]] || { echo "error: --thread-cache-head needs a SHA" >&2; exit 2; }
          THREAD_CACHE_HEAD="$2"; shift 2 ;;
        --skip-thread-check) SKIP_THREAD_CHECK=true;
          echo "warning: --skip-thread-check set — thread-resolution gate disabled for PR #$PR" >&2
          shift ;;
        --skip-followup-check) SKIP_FOLLOWUP_CHECK=true;
          echo "warning: --skip-followup-check set — follow-up preservation gate disabled for PR #$PR (issue #859)" >&2
          shift ;;
        --skip-claim-check) SKIP_CLAIM_CHECK=true;
          echo "warning: --skip-claim-check set — claim-check guard disabled for PR #$PR; promoting a PR that never claimed the gate (issue #981)" >&2
          shift ;;
        *) echo "error: unknown option '$1' for pass" >&2; exit 2 ;;
      esac
    done
    # Claim-check guard (issue #981): the pr-reviewing claim label is the FIRST
    # thing a review applies (Phase 2 `start-review`) — the anchor of the #699
    # concurrency guard and the only "review in progress" signal a human or the
    # fleet can see mid-review. In an adapted flow (dispatching review agents
    # directly, then calling `pass` at the end) the start-review claim is easily
    # skipped, so the PR jumps straight from NO label to pr-reviewed with no amber
    # interstitial and the #699 guard never armed. Prose ("run start-review in
    # Phase 2") demonstrably did not hold (the operator caught 3 PRs merged with
    # no pr-reviewing ever applied). Mechanical backstop, mirroring the exit-4
    # (advisory, #754) and exit-5 (attest, #883) gates: refuse to promote a PR
    # that currently carries NEITHER label — the "no label -> pr-reviewed" jump
    # the skip produces. A PR already carrying pr-reviewing (normal claim, applied
    # by start-review) or pr-reviewed (a re-assert / delta re-review of a prior
    # verdict) proceeds untouched. Fails CLOSED: an unreadable label state refuses
    # rather than promoting blind (is_draft already proved gh works by this point).
    # --skip-claim-check is the loud escape hatch for the rare legitimate inline
    # review that deliberately never claimed the gate. Distinct exit 7.
    if [[ "$SKIP_CLAIM_CHECK" != "true" ]]; then
      CLAIM_STATUS=$(label_status 2>/dev/null) || {
        echo "refusing: PR #$PR — could not read label state; claim-check guard fails closed (issue #981)" >&2
        echo "Fix gh access (auth, rate limit, network) and retry, or pass --skip-claim-check for a genuinely inline review that never claimed the gate." >&2
        exit 7
      }
      if [[ "$CLAIM_STATUS" != *"reviewing=true"* && "$CLAIM_STATUS" != *"reviewed=true"* ]]; then
        echo "refusing: PR #$PR carries neither $REVIEWING nor $REVIEWED — a review that never called 'start-review' cannot jump straight to $REVIEWED (issue #981)" >&2
        echo "Claim the gate first: 'pr-labels.sh start-review $PR' (applies $REVIEWING, arms the #699 concurrency guard), then re-run pass." >&2
        echo "Bypass with --skip-claim-check (loud warning) only for a rare legitimate review that deliberately never claimed the gate." >&2
        exit 7
      fi
    fi
    # Forgejo path (issue #1239): the thread-resolution gate is GitHub-specific
    # (GraphQL reviewThreads). Forgejo/Gitea has a different PR review model and
    # no exact equivalent of required_review_thread_resolution. Force-skip the
    # gate on Forgejo — all other guards (claim-check, follow-up, convergence,
    # required-checks, label swap) are preserved on both paths.
    if [[ "$_PRL_HOST" == "forgejo" && "$SKIP_THREAD_CHECK" != "true" ]]; then
      SKIP_THREAD_CHECK=true
      echo "PR #$PR: thread-resolution gate not applicable on Forgejo/Gitea host — skipping (issue #1239)" >&2
    fi
    # Human-hold gate (issue #1393): a `hold` label is a human sign-off
    # requirement applied either explicitly (prose "HOLD:" in the PR body parsed
    # at review start) or automatically by /sge:pr-review when a security
    # specialist returns a MAJOR finding. The gate CANNOT open while hold is
    # present — pr-reviewed must not be applied and auto-merge must not be armed.
    # This is the mechanical backstop that prose-in-the-body cannot provide
    # (incident: co#2393 — hold prose only, label bot merged it). Fails CLOSED:
    # an unreadable hold state refuses rather than promoting blind. The hold is
    # released by the operator removing the label; the next review cycle then
    # promotes normally via the delta fast-path.
    # Callers that produce the `held` verdict should call 'pr-labels.sh held'
    # (not 'pass') so they release pr-reviewing without promoting; this guard
    # also defends against any path that calls 'pass' directly while hold is set.
    # Distinct exit 8.
    # GitHub-only for now (issue #1393 + #1419): the hold mechanism (apply-hold,
    # held, hold_status) is wired against the gh label path; on a Forgejo host the
    # gate is skipped so the adapter's own review model governs — matching how the
    # thread-resolution gate above is host-scoped. `status` likewise keeps its
    # two-field (reviewing/reviewed) output on Forgejo (see the `status` command).
    if [[ "${_PRL_HOST:-github}" != "forgejo" ]]; then
      HOLD_STATUS=$(hold_status 2>/dev/null) || {
        echo "refusing: PR #$PR — could not read hold label state; human-hold gate fails closed (issue #1393)" >&2
        echo "Fix gh access (auth, rate limit, network) and retry." >&2
        echo "To release the pr-reviewing claim without promoting, run: pr-labels.sh held $PR" >&2
        exit 8
      }
      if [[ "$HOLD_STATUS" == *"hold=true"* ]]; then
        echo "refusing: PR #$PR carries the '$HOLD' label — the gate cannot open while a human sign-off is pending (issue #1393)" >&2
        echo "The review verdict has been posted. Remove the '$HOLD' label once sign-off is obtained; the next" >&2
        echo "review cycle will detect the clean prior verdict at the same head and promote normally." >&2
        echo "To release the pr-reviewing claim without promoting, run: pr-labels.sh held $PR" >&2
        exit 8
      fi
    fi
    # Thread resolution gate (issue #652 / ppp#9923):
    # Branch rulesets with required_review_thread_resolution=true block merge
    # until ALL review threads are resolved — including bot-opened ones (Copilot,
    # CI reviewers). The mergeStateStatus and verdict checks are blind to this rule,
    # so a clean `pass` can arm auto-merge and leave the PR permanently BLOCKED.
    # This gate catches unresolved threads before the label swap; the review must
    # fix, reply, or explicitly resolve every thread (Phase 5.5) before calling pass.
    # --skip-thread-check is available for repos that don't enforce this ruleset, but
    # should be used sparingly — leaving threads open is always a review gap.
    if [[ "$SKIP_THREAD_CHECK" != "true" ]]; then
      REPO_FULL="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}"
      if [[ -z "$REPO_FULL" ]]; then
        echo "refusing: cannot determine repo for PR #$PR — set GH_REPO or run from inside a git clone" >&2
        echo "Use --skip-thread-check only if this repo has no required_review_thread_resolution ruleset." >&2
        exit 1
      fi
      _OWNER="${REPO_FULL%/*}"; _REPO="${REPO_FULL#*/}"
      # Cached-count fast path (issue #1157): the review's Phase 5.5 already
      # walked every review thread once (review-lib.sh rl_unresolved_threads) at
      # a known head. Re-walking it here — identical GitHub state seconds later —
      # is pure duplication (up to 40 pages × 50 threads TWICE on a threaded PR).
      # The caller may hand us that already-fetched unresolved list via
      # --thread-cache <file> plus the head it was fetched at via
      # --thread-cache-head <sha>. We trust it ONLY after a single cheap
      # headRefOid query confirms the head has NOT moved since — a late-arriving
      # unresolved comment or a force-push in the Phase 5.5→pass gap changes the
      # thread state, and MUST NOT be waved through. This keeps the gate
      # fail-closed: ANY of {no cache, head moved, head unreadable, cache file
      # unreadable/unparsable} falls straight through to the full pre-check +
      # paginated walk below — the cache is a shortcut, never a weakening.
      _CACHE_TRUSTED=false
      if [[ -n "$THREAD_CACHE" || -n "$THREAD_CACHE_HEAD" ]]; then
        if [[ -z "$THREAD_CACHE" || -z "$THREAD_CACHE_HEAD" ]]; then
          echo "PR #$PR: --thread-cache and --thread-cache-head must be given together — ignoring partial cache, running full walk (fail-closed, issue #1157)" >&2
        elif [[ ! -r "$THREAD_CACHE" ]]; then
          echo "PR #$PR: thread cache file '$THREAD_CACHE' unreadable — running full walk (fail-closed, issue #1157)" >&2
        else
          # Single cheap freshness check: has the head moved since the cache was
          # taken? gh/GraphQL failure here is NOT read as "unchanged" — it forces
          # the full walk (fail-closed).
          if _CACHE_CUR_HEAD=$(gh pr view "$PR" --json headRefOid --jq .headRefOid 2>/dev/null) \
                && [[ -n "$_CACHE_CUR_HEAD" && "$_CACHE_CUR_HEAD" == "$THREAD_CACHE_HEAD" ]]; then
            # Head unchanged — trust the cached list, but only if it parses as a
            # JSON array. A malformed cache is never read as "0 unresolved".
            if _CACHED_UNRESOLVED=$(jq -c 'select(type=="array")' "$THREAD_CACHE" 2>/dev/null) \
                  && [[ -n "$_CACHED_UNRESOLVED" ]]; then
              _CACHE_TRUSTED=true
              echo "PR #$PR: thread cache head-sha guard passed (head ${THREAD_CACHE_HEAD:0:9} unchanged) — reusing Phase 5.5 walk, skipping re-query (issue #1157)" >&2
              _CACHE_COUNT=$(jq 'length' <<<"$_CACHED_UNRESOLVED") \
                || { echo "refusing: could not count cached unresolved threads for PR #$PR — thread gate fails closed (issue #1157)" >&2; exit 1; }
              if [[ "$_CACHE_COUNT" -gt 0 ]]; then
                echo "refusing: PR #$PR has $_CACHE_COUNT unresolved review thread(s) (from Phase 5.5 cache, head verified)" >&2
                echo "Merge is permanently BLOCKED until all threads are resolved (required_review_thread_resolution)." >&2
                echo "" >&2
                jq -r '.[] | "  [\(.id | .[0:20])…] \(.comments.nodes[0].author.login): \(.comments.nodes[0].body | .[0:100] | gsub("\n";" "))"' \
                  <<<"$_CACHED_UNRESOLVED" >&2
                echo "" >&2
                echo "Run Phase 5.5 of /sge:pr-review to address each thread (fix, reply, or resolve)." >&2
                echo "Use --skip-thread-check if this repo has no required_review_thread_resolution ruleset." >&2
                exit 1
              fi
            else
              echo "PR #$PR: thread cache '$THREAD_CACHE' is not a JSON array — running full walk (fail-closed, issue #1157)" >&2
            fi
          else
            echo "PR #$PR: head moved or unreadable since cache (cached ${THREAD_CACHE_HEAD:0:9}, now ${_CACHE_CUR_HEAD:0:9}) — discarding cache, running full walk (fail-closed, issue #1157)" >&2
          fi
        fi
      fi
      if [[ "$_CACHE_TRUSTED" != "true" ]]; then
      # Cheap pre-check (issue #973): most PRs — especially small/low-risk ones —
      # carry zero review threads at all. A single `first:1 { totalCount }` query
      # is ~1 API call vs. the full cursor-paginated walk below; when totalCount
      # is exactly 0 there is nothing to page through, so short-circuit straight
      # to "0 unresolved, proceed". This does NOT weaken the fail-closed rule
      # from #717: if the pre-check itself errors (gh/GraphQL failure, missing
      # field, unparsable response) we fall straight through to the full
      # paginated path below — a failed pre-check is never read as "0 unresolved",
      # only a *successful* query that reports totalCount==0 short-circuits.
      _PRECHECK_QUERY='
        query($owner:String!,$repo:String!,$pr:Int!){
          repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
            reviewThreads(first:1){ totalCount } } } }'
      _RUN_FULL_THREAD_WALK=false
      if _PRECHECK=$(gh api graphql -f query="$_PRECHECK_QUERY" \
            -f owner="$_OWNER" -f repo="$_REPO" -F pr="$PR" \
            --jq '.data.repository.pullRequest.reviewThreads.totalCount' 2>/dev/null); then
        if [[ "$_PRECHECK" =~ ^[0-9]+$ && "$_PRECHECK" -eq 0 ]]; then
          echo "PR #$PR: thread pre-check totalCount=0 — skipping full pagination walk (issue #973)" >&2
        else
          _RUN_FULL_THREAD_WALK=true
        fi
      else
        echo "PR #$PR: thread pre-check query failed — falling through to full paginated path (fail-closed, issue #717/#973)" >&2
        _RUN_FULL_THREAD_WALK=true
      fi
      if [[ "$_RUN_FULL_THREAD_WALK" == "true" ]]; then
      # Cursor-paginate over ALL review threads (issue #717). The old single
      # `first:50` page silently missed unresolved threads past page 1, and its
      # stderr-suppressing empty-array fallback mapped ANY gh/GraphQL failure to
      # "0 unresolved" — a fail-OPEN merge gate. This gate now fails CLOSED:
      # every page must fetch and parse cleanly or the pass is refused.
      _THREADS_QUERY='
        query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
          repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
            reviewThreads(first:50, after:$cursor){
              pageInfo{ hasNextPage endCursor }
              nodes{ id isResolved
                comments(first:1){ nodes{ body author{ login } } } } } } } }'
      UNRESOLVED_JSON='[]'
      _CURSOR=""
      _PAGE_NUM=0
      _MAX_PAGES=40   # 40 × 50 = 2000 threads — refuse (fail closed) beyond this, never loop forever
      while :; do
        _PAGE_NUM=$((_PAGE_NUM + 1))
        if [[ "$_PAGE_NUM" -gt "$_MAX_PAGES" ]]; then
          echo "refusing: PR #$PR has more than $((_MAX_PAGES * 50)) review threads — thread gate fails closed (issue #717)" >&2
          exit 1
        fi
        _PAGE_ARGS=(-f owner="$_OWNER" -f repo="$_REPO" -F pr="$PR")
        [[ -n "$_CURSOR" ]] && _PAGE_ARGS+=(-f cursor="$_CURSOR")
        if ! _PAGE=$(gh api graphql -f query="$_THREADS_QUERY" "${_PAGE_ARGS[@]}" \
              --jq '.data.repository.pullRequest.reviewThreads'); then
          echo "refusing: could not query review threads for PR #$PR (page $_PAGE_NUM) — gh/GraphQL failure" >&2
          echo "The thread-resolution gate fails CLOSED (issue #717): an unverifiable thread state never counts as 0 unresolved." >&2
          echo "Fix API access (auth, rate limit, network) and retry. Use --skip-thread-check only if this repo has no required_review_thread_resolution ruleset." >&2
          exit 1
        fi
        UNRESOLVED_JSON=$(jq -c --argjson acc "$UNRESOLVED_JSON" \
            '$acc + [.nodes[] | select(.isResolved==false)]' <<<"$_PAGE") \
          || { echo "refusing: could not parse review-thread page $_PAGE_NUM for PR #$PR — thread gate fails closed (issue #717)" >&2; exit 1; }
        _HAS_NEXT=$(jq -r '.pageInfo.hasNextPage' <<<"$_PAGE") \
          || { echo "refusing: could not read pageInfo for PR #$PR — thread gate fails closed (issue #717)" >&2; exit 1; }
        [[ "$_HAS_NEXT" == "true" ]] || break
        _CURSOR=$(jq -r '.pageInfo.endCursor' <<<"$_PAGE")
        if [[ -z "$_CURSOR" || "$_CURSOR" == "null" ]]; then
          echo "refusing: hasNextPage=true but endCursor missing for PR #$PR — thread gate fails closed (issue #717)" >&2
          exit 1
        fi
      done
      UNRESOLVED_COUNT=$(jq 'length' <<<"$UNRESOLVED_JSON") \
        || { echo "refusing: could not count unresolved threads for PR #$PR — thread gate fails closed (issue #717)" >&2; exit 1; }
      if [[ "$UNRESOLVED_COUNT" -gt 0 ]]; then
        echo "refusing: PR #$PR has $UNRESOLVED_COUNT unresolved review thread(s)" >&2
        echo "Merge is permanently BLOCKED until all threads are resolved (required_review_thread_resolution)." >&2
        echo "" >&2
        jq -r '.[] | "  [\(.id | .[0:20])…] \(.comments.nodes[0].author.login): \(.comments.nodes[0].body | .[0:100] | gsub("\n";" "))"' \
          <<<"$UNRESOLVED_JSON" >&2
        echo "" >&2
        echo "Run Phase 5.5 of /sge:pr-review to address each thread (fix, reply, or resolve)." >&2
        echo "Use --skip-thread-check if this repo has no required_review_thread_resolution ruleset." >&2
        exit 1
      fi
      fi   # end _RUN_FULL_THREAD_WALK (issue #973 pre-check short-circuit)
      fi   # end _CACHE_TRUSTED fast path (issue #1157)
    fi
    # Follow-up preservation gate (issue #859): before opening the pr-reviewed
    # gate (and therefore before auto-merge can arm), refuse if the PR body or
    # the review text declares a follow-up with no issue reference — such a
    # follow-up's only home is destroyed when the linked issue auto-closes on
    # merge. Runs on EVERY pass (not just --auto-merge): it blocks the label
    # promotion itself, since the promotion is what arms the auto-merge. Distinct
    # exit 6. --skip-followup-check bypasses (a PR that genuinely declares none).
    if [[ "$SKIP_FOLLOWUP_CHECK" != "true" ]]; then
      assert_followups_preserved || exit 6
    fi
    # 3-way head-convergence (issue #288): when promoting to auto-merge, the
    # branch ref tip, the PR-object head, and a resolved (non-UNKNOWN) mergeable
    # state must all agree before we enable squash auto-merge. Otherwise GitHub
    # may squash a cached stale snapshot, silently dropping just-pushed commits.
    # We run this whenever auto-merge is requested or a head was pinned, and use
    # the converged ref tip as the authoritative head for the --expect-head
    # comparison (criterion: compare against the branch ref tip, not solely the
    # PR object head GitHub returns).
    #
    # Forgejo path (issue #1239): Gitea/Forgejo PR objects don't have the async
    # lag that necessitates 3-way convergence polling. A single REST read for the
    # PR head SHA is sufficient. The CONVERGED_HEAD global is still set so the
    # --expect-head race guard works identically on both paths.
    if [[ "$AUTO_MERGE" == "true" || -n "$EXPECT_HEAD" ]]; then
      if [[ "$_PRL_HOST" == "forgejo" ]]; then
        _FJ_HEAD=$("$_PRL_ADAPTER" pr-head-sha "$_PRL_ORIGIN" "$PR" 2>&1) \
          || { echo "error: could not read PR head SHA for PR #$PR (Forgejo): $_FJ_HEAD" >&2; exit 1; }
        CONVERGED_HEAD="$_FJ_HEAD"
        echo "PR #$PR: Forgejo head SHA = ${CONVERGED_HEAD:0:9} (issue #1239)" >&2
      else
        await_head_convergence || exit 1
      fi
    fi
    # Required-check guard (issue #885): before arming auto-merge, refuse if any
    # genuinely-required check is still red/pending. Runs BEFORE the label swap
    # so a red required gate blocks BOTH the pr-reviewed promotion and the arm —
    # the code-content verdict cannot talk past an independently-red required
    # gate (spec-drift, issue-link, CI). Distinct from head-convergence (#288).
    #
    # Forgejo path (issue #1239): use Gitea's combined commit status at the
    # converged head SHA as the required-check proxy. Any failure/error state
    # refuses the promotion — matching the fail-closed posture of the GitHub
    # gate. "success" proceeds; "pending" refuses (CI still running).
    #
    # "none" means the head has NO commit statuses. On a repo with NO CI
    # configured that is a legitimate green ("nothing to wait for"); but on a
    # repo WITH CI it can also mean CI has not registered its first status yet —
    # proceeding then merges before any check runs. Because the adapter cannot
    # distinguish the two, default behaviour treats "none" as proceed (the
    # no-CI-configured assumption) and SGE_FORGEJO_REQUIRE_CI=1 flips it to
    # fail-closed for repos that DO run CI and must never merge on an empty
    # status set. "unknown" (an unrecognised/unresolvable status — see
    # forgejo-adapter.sh pr-commit-status) ALWAYS refuses: it is never a
    # confirmed green.
    if [[ "$AUTO_MERGE" == "true" ]]; then
      if [[ "$_PRL_HOST" == "forgejo" ]]; then
        _FJ_CI_STATUS=$("$_PRL_ADAPTER" pr-commit-status "$_PRL_ORIGIN" "$CONVERGED_HEAD" 2>/dev/null) \
          || _FJ_CI_STATUS="unknown"
        case "$_FJ_CI_STATUS" in
          failure|error)
            echo "refusing: PR #$PR Forgejo commit CI status is '${_FJ_CI_STATUS}' — will NOT merge (issue #885, Forgejo path, issue #1239)" >&2
            exit 1 ;;
          pending)
            echo "refusing: PR #$PR Forgejo commit CI status is 'pending' — will NOT merge while CI is still running (issue #885, Forgejo path, issue #1239)" >&2
            exit 1 ;;
          none)
            if [[ "${SGE_FORGEJO_REQUIRE_CI:-0}" == "1" ]]; then
              echo "refusing: PR #$PR Forgejo commit status is 'none' (no CI statuses on the head) and SGE_FORGEJO_REQUIRE_CI=1 — will NOT merge; a required check may not have registered yet (issue #885, issue #1239)" >&2
              exit 1
            fi
            echo "PR #$PR: Forgejo commit status = 'none' (no CI configured) — proceeding with merge (issue #1239)" >&2 ;;
          success)
            echo "PR #$PR: Forgejo commit status = 'success' — proceeding with merge (issue #1239)" >&2 ;;
          *)
            echo "refusing: PR #$PR Forgejo commit CI status is '${_FJ_CI_STATUS}' (unrecognised — never a confirmed green) — will NOT merge (issue #885, issue #1239)" >&2
            exit 1 ;;
        esac
      else
        assert_required_checks_green || exit 1
      fi
    fi
    # Race guard: a push landing between review and promotion means the gate
    # would open for UNREVIEWED commits — and auto-merge can squash the PR at
    # whatever head it validated, silently dropping later commits (this
    # happened: PR #212 merged at its first commit while a review-required
    # fix sat pushed-but-unmerged). Refuse and demand a delta re-review.
    # CONVERGED_HEAD is always populated here: await_head_convergence || exit 1
    # (line 166) ran before this point whenever EXPECT_HEAD is set, so the
    # fallback expression is unreachable in practice.
    if [[ -n "$EXPECT_HEAD" ]]; then
      ACTUAL_HEAD="$CONVERGED_HEAD"
      # Normalise before comparing (issue #1671): reviewers routinely pin an
      # abbreviated SHA, and a string-wise compare against the full 40-char
      # headRefOid refused identical heads — the truncated refusal then
      # printed two IDENTICAL 9-char strings ("reviewed 86b71074e, now
      # 86b71074e") and sent the caller into a pointless delta re-review.
      # Prefix-match when the supplied pin is shorter, refuse pins under 7
      # hex chars (too short to trust as a head identity), and on a genuine
      # mismatch print BOTH sides at full length so the difference is visible.
      EXPECT_NORM=$(printf '%s' "$EXPECT_HEAD" | tr '[:upper:]' '[:lower:]')
      ACTUAL_NORM=$(printf '%s' "$ACTUAL_HEAD" | tr '[:upper:]' '[:lower:]')
      if [[ ${#EXPECT_NORM} -lt 7 || ! "$EXPECT_NORM" =~ ^[0-9a-f]+$ ]]; then
        echo "refusing: --expect-head '$EXPECT_HEAD' is not a usable SHA pin (need >= 7 hex chars)" >&2
        exit 1
      fi
      if [[ "$ACTUAL_NORM" != "$EXPECT_NORM"* ]]; then
        echo "refusing: PR #$PR head moved since review (reviewed $EXPECT_HEAD, now $ACTUAL_HEAD)" >&2
        echo "run a delta re-review of the new commits, then pass with the new head" >&2
        exit 1
      fi
    fi
    ensure_labels
    # Delete the claim comment before the label swap (issue #1312 AC4).
    # Clearing the metadata first ensures no concurrent agent misreads a stale
    # comment as a live claim once the pr-reviewing label is gone.
    delete_claim_comment
    # Late hold re-check (issue #1393 review finding): the gate's first hold read
    # runs at the top of pass, but the thread gate, follow-up gate, required-check
    # guard, and head-convergence wait all make API round-trips (with sleeps) —
    # a hold applied inside that window would otherwise be missed. One cheap
    # re-read here shrinks the TOCTOU window to a single API round-trip. Same
    # fail-closed semantics as the first check.
    if [[ "${_PRL_HOST:-github}" != "forgejo" ]]; then
      HOLD_STATUS=$(hold_status 2>/dev/null) || {
        echo "refusing: PR #$PR — could not re-verify hold label state before the label swap; human-hold gate fails closed (issue #1393)" >&2
        echo "To release the pr-reviewing claim without promoting, run: pr-labels.sh held $PR" >&2
        exit 8
      }
      if [[ "$HOLD_STATUS" == *"hold=true"* ]]; then
        echo "refusing: PR #$PR — the '$HOLD' label appeared during pass; the gate cannot open (issue #1393)" >&2
        echo "To release the pr-reviewing claim without promoting, run: pr-labels.sh held $PR" >&2
        exit 8
      fi
    fi
    add_label "$REVIEWED"           # open the gate first…
    remove_label "$REVIEWING"       # …then drop the amber label
    # Retry the verify check: GitHub's API can lag a write by a few seconds.
    # The Forgejo adapter writes synchronously (the label mutation has already
    # committed when the POST returns), so the inter-attempt sleep is pure dead
    # time there — skip it. The retry loop still runs (cheap re-read) as a
    # defensive check; only the 2s wait is elided on the Forgejo path.
    STATUS=""
    for attempt in 1 2 3; do
      STATUS="$(label_status)" || { echo "error: could not read label state for PR #$PR after swap" >&2; exit 1; }
      [[ "$STATUS" == "reviewing=false reviewed=true" ]] && break
      [[ $attempt -lt 3 && "$_PRL_HOST" != "forgejo" ]] && sleep 2
    done
    if [[ "$STATUS" != "reviewing=false reviewed=true" ]]; then
      echo "error: label swap did not take on PR #$PR after 3 attempts ($STATUS)" >&2
      exit 1
    fi
    echo "PR #$PR: gate passed ($STATUS)"
    if [[ "$AUTO_MERGE" == "true" ]]; then
      if [[ "$_PRL_HOST" == "forgejo" ]]; then
        # Forgejo path (issue #1239): squash-merge directly via the REST adapter.
        # pr-merge-squash pins the merge to CONVERGED_HEAD via Gitea's
        # head_commit_id, so a push landing between the convergence check above
        # and this POST cannot ride into an unreviewed squash-merge — Gitea
        # refuses if the head moved (TOCTOU close; GitHub's queued --auto gets
        # the same server-side re-check for free, this path did not).
        if merge_out=$(FORGEJO_ADAPTER_ALLOW_WRITE=1 "$_PRL_ADAPTER" \
              pr-merge-squash "$_PRL_ORIGIN" "$PR" "$CONVERGED_HEAD" 2>&1); then
          echo "PR #$PR: merged (squash, Forgejo, pinned to ${CONVERGED_HEAD:0:9})"
        else
          echo "PR #$PR: merge request failed — $merge_out" >&2
          echo "PR #$PR: merge not triggered — leaving merge to be done manually"
        fi
      elif _repo_has_dedicated_automerge_bot; then
        # issue #2079: this repo already runs its own dedicated Auto-Approve
        # & Merge bot workflow, which mints a proper GitHub App token and
        # does its own full approve+merge sequence once pr-reviewed lands.
        # Arming --auto here too would race it under this session's own gh
        # identity — skip and defer entirely to the bot.
        echo "PR #$PR: repo has its own dedicated auto-merge bot workflow (issue #2079) — skipping local --auto arm; the bot will approve+merge once checks are green."
      else
        # --auto queues the merge behind branch protection; it never force-merges.
        # Tolerant: repos without auto-merge fall back to /sge:pr-monitor.
        if merge_out=$(gh pr merge "$PR" --squash --auto 2>&1); then
          echo "PR #$PR: auto-merge enabled (squash)"
        else
          echo "PR #$PR: auto-merge request failed — $merge_out" >&2
          echo "PR #$PR: auto-merge not enabled — leaving merge to /sge:pr-monitor"
        fi
      fi
    fi
    ;;

  fail)
    ensure_labels
    # Delete the claim comment before removing labels (issue #1312 AC4).
    # Clears the metadata so a subsequent start-review sees a clean slate.
    delete_claim_comment
    remove_label "$REVIEWED"        # gate stays closed
    remove_label "$REVIEWING"       # review is over; the findings carry the state
    STATUS="$(label_status)" || STATUS="(label_status unavailable)"
    echo "PR #$PR: gate closed — findings on the PR carry the state ($STATUS)"
    ;;

  held)
    # Human-hold termination path (issue #1393): the review ran cleanly but a
    # `hold` label is present, so the gate cannot open yet. Release pr-reviewing
    # (so the concurrency guard does not block future cycles) without applying
    # pr-reviewed (so auto-merge never arms). The hold label itself is untouched
    # — only the human operator can remove it.
    # When hold is removed, the next cycle's /sge:pr-review dispatch finds a
    # clean prior sge-verdict at the current head and promotes via delta fast-path.
    remove_label "$REVIEWING"       # release the claim so future cycles can run
    # $REVIEWED is intentionally NOT applied while hold is present.
    HOLD_ST="$(hold_status 2>/dev/null)" || HOLD_ST="(hold_status unavailable)"
    echo "PR #$PR: review passed — held for human sign-off ($HOLD_ST)"
    echo "Remove the '$HOLD' label once sign-off is obtained; the next review cycle will promote normally."
    ;;

  apply-hold)
    # Apply the hold label (issue #1393): used by /sge:pr-review when it detects
    # a HOLD: marker in the PR body at review start, or when a security specialist
    # returns a MAJOR finding that requires human sign-off per standing policy.
    # Idempotent — safe to call even if hold is already present.
    ensure_hold_label
    add_label "$HOLD"
    # hold_status is gh-label-specific; keep the confirmation echo GitHub-only,
    # matching the pass/status host-scoping (issues #1393 + #1419).
    if [[ "${_PRL_HOST:-github}" != "forgejo" ]]; then
      HOLD_ST="$(hold_status 2>/dev/null)" || HOLD_ST="(hold_status unavailable)"
    else
      HOLD_ST="(hold_status not wired on Forgejo — #1419)"
    fi
    echo "PR #$PR: '$HOLD' label applied — gate will not open until a human removes it ($HOLD_ST)"
    ;;

  stale)
    # New commits landed after a pass — the prior verdict no longer covers HEAD.
    remove_label "$REVIEWED"
    echo "PR #$PR: $REVIEWED dropped (stale — new commits since last verdict)"
    ;;

  sync-check)
    # Issue #1941: on pull_request:synchronize, strip pr-reviewed when the
    # latest sge-verdict's commit SHA does not match the new head. A label
    # that survived a push but whose verdict was pinned to the OLD head would
    # lie about coverage until someone noticed. The require-pr-reviewed-label
    # workflow already fires on synchronize and would pass (the label IS
    # present) — but it cannot know that the verdict was for a different SHA
    # because it only reads labels, not verdict blocks. This subcommand
    # closes that gap.
    #
    # Reuses the same sge-verdict parsing approach as state_machine.py
    # (reviews first, then issue comments, most-recent first) but in bash+jq
    # rather than reimplementing the Python. The --expect-head normalisation
    # rules from `pass` apply: prefix match >= 7 hex chars, case-insensitive.

    NEW_HEAD="${3:-}"
    [[ -n "$NEW_HEAD" ]] || { echo "error: sync-check requires <pr> <new-head-sha>" >&2; exit 2; }

    # 1) Is pr-reviewed even present? If not, nothing to strip.
    LS="$(label_status 2>/dev/null)" || LS=""
    if [[ "$LS" != *"reviewed=true"* ]]; then
      echo "PR #$PR: sync-check — no $REVIEWED label, nothing to strip"
      exit 0
    fi

    # 2) Find the latest sge-verdict commit SHA from PR reviews + comments.
    #    Search reviews first (where gh pr review posts), then issue comments.
    #    Take the most recent verdict found (reversed order).
    REPO_FULL="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
    VERDICT_SHA=""
    if [[ -n "$REPO_FULL" ]]; then
      # Reviews (PR review API — most reliable, where /sge:pr-review posts).
      # Extract the commit/sha/head field from the last sge-verdict block.
      # Uses jq to parse the verdict block directly — avoids the 3-argument
      # match() which only gawk supports (not BSD/macOS awk).
      # Trusted-author filter (defense-in-depth): the App/Actions bot logins
      # (wtp-sge[bot], github-actions[bot]) OR author_association OWNER/MEMBER/
      # COLLABORATOR — the same trust anchor as verdict_trust.py (#1373/#1444).
      # The association leg is required: WTP is a documented solo-dev org (see
      # SGE_GOVERNANCE_PROFILE=solo in require-pr-reviewed-label.yml) where the
      # PAT/self-review fallback (#862) posts every real sge-verdict under the
      # operator's own MEMBER account, never a bot login (verified empirically
      # against PRs #1980-1994) — without this leg VERDICT_SHA is always empty
      # here and sync-check silently never fires (the "never observed acting"
      # class #1941's own AC warns against; see #1664). An outside, non-
      # collaborator commenter still cannot forge a verdict this way.
      TRUST_FILTER='.user.login == "wtp-sge[bot]" or .user.login == "github-actions[bot]"
           or (((.author_association // "") | ascii_upcase) as $assoc
               | $assoc == "OWNER" or $assoc == "MEMBER" or $assoc == "COLLABORATOR")'
      VERDICT_SHA=$(gh api "repos/$REPO_FULL/pulls/$PR/reviews" --paginate \
        --jq '
          [.[] | select(.body != null)
           | select('"$TRUST_FILTER"')
           | select(.body | test("```sge-verdict"))
           | .body | split("\n")[] | select(test("^\\s*(commit|sha|head)\\s*:"))
           | capture(":\\s*(?<val>\\S+)") | .val
          ] | last // empty' \
        2>/dev/null) || VERDICT_SHA=""

      # Fallback: issue comments (same trusted-author filter)
      if [[ -z "$VERDICT_SHA" ]]; then
        VERDICT_SHA=$(gh api "repos/$REPO_FULL/issues/$PR/comments" --paginate \
          --jq '
            [.[] | select(.body != null)
             | select('"$TRUST_FILTER"')
             | select(.body | test("```sge-verdict"))
             | .body | split("\n")[] | select(test("^\\s*(commit|sha|head)\\s*:"))
             | capture(":\\s*(?<val>\\S+)") | .val
            ] | last // empty' \
          2>/dev/null) || VERDICT_SHA=""
      fi
    fi

    if [[ -z "$VERDICT_SHA" ]]; then
      # No verdict found at all. Cannot prove staleness — do not strip.
      # (Fail closed: the label stays, and the require-pr-reviewed-label
      # workflow's own head-drift check handles the "label present but no
      # verdict" case.)
      echo "PR #$PR: sync-check — no sge-verdict found; cannot determine coverage; label retained"
      exit 0
    fi

    # 3) Compare verdict SHA against new head (prefix match, case-insensitive,
    #    reusing the same normalisation as --expect-head).
    VERDICT_NORM=$(printf '%s' "$VERDICT_SHA" | tr '[:upper:]' '[:lower:]')
    HEAD_NORM=$(printf '%s' "$NEW_HEAD" | tr '[:upper:]' '[:lower:]')
    # Use the shorter of the two as the prefix length (both must be >= 7).
    V_LEN=${#VERDICT_NORM}
    H_LEN=${#HEAD_NORM}
    if [[ "$V_LEN" -lt 7 || "$H_LEN" -lt 7 ]]; then
      echo "PR #$PR: sync-check — SHA too short to compare (verdict=$VERDICT_SHA, head=$NEW_HEAD); label retained" >&2
      exit 0
    fi
    # Hex validation (matches pass's --expect-head guard): a non-hex verdict
    # SHA means the verdict block is malformed — do not act on it.
    if [[ ! "$VERDICT_NORM" =~ ^[0-9a-f]+$ ]]; then
      echo "PR #$PR: sync-check — non-hex verdict SHA '$VERDICT_SHA'; label retained" >&2
      exit 0
    fi
    PREFIX_LEN=$(( V_LEN < H_LEN ? V_LEN : H_LEN ))
    if [[ "${VERDICT_NORM:0:$PREFIX_LEN}" == "${HEAD_NORM:0:$PREFIX_LEN}" ]]; then
      echo "PR #$PR: sync-check — verdict covers head (${VERDICT_SHA:0:12}); $REVIEWED retained"
      exit 0
    fi

    # 4) Stale: strip the label and post a comment.
    remove_label "$REVIEWED"
    echo "PR #$PR: $REVIEWED stripped — verdict was pinned to ${VERDICT_SHA:0:12}, new head is ${NEW_HEAD:0:12} (issue #1941)"

    # Best-effort comment so the author sees WHY the gate reopened.
    COMMENT_BODY="$(printf '**pr-reviewed stripped** (issue #1941)\n\nThe latest `sge-verdict` was pinned to `%s`; the new head after push is `%s`. The label cannot assert a review of a superseded SHA.\n\nA re-review that passes at the new head will restore the label automatically.' \
      "$VERDICT_SHA" "$NEW_HEAD")"
    if [[ -n "$REPO_FULL" ]]; then
      gh api "repos/$REPO_FULL/issues/$PR/comments" -f body="$COMMENT_BODY" >/dev/null 2>&1 \
        || echo "warning: could not post staleness comment on PR #$PR (best-effort)" >&2
    fi
    ;;

  claim-fix)
    # Fix-in-flight mutex (issue #1174): pr-fixing is the claim label owned by
    # /sge:pr-fix, mirroring pr-reviewing's #699 concurrency guard exactly. Two
    # pr-monitor sessions over the same repo classify a red PR as CODE FAIL and
    # each dispatch a /sge:pr-fix agent onto the same branch — racing force-pushes
    # exactly as the racing-reviewers incident pr-reviewing exists to prevent
    # (observed on PRs #1167/#1168, 2026-07-15). If the label is already present
    # and the claim is FRESH (younger than SGE_FIX_CLAIM_TTL_MIN, default 30 min,
    # by the labelled-event timestamp), another live fix agent very likely owns
    # this PR — refuse with exit 3 so the caller backs off. Self-expiring: a stale
    # claim (crashed/abandoned fix session) is taken over, and any failure to
    # determine the claim age degrades to a warning + proceed — a back-off hint,
    # never a hard lock. --force-claim overrides deliberately.
    FORCE_CLAIM=false
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --force-claim) FORCE_CLAIM=true; shift ;;
        *) echo "error: unknown option '$1' for claim-fix" >&2; exit 2 ;;
      esac
    done
    if [[ "$FORCE_CLAIM" != "true" ]]; then
      CUR_STATUS=$(fix_claim_status 2>/dev/null) || CUR_STATUS=""
      if [[ "$CUR_STATUS" == *"fixing=true"* ]]; then
        CLAIM_TTL_MIN="${SGE_FIX_CLAIM_TTL_MIN:-30}"
        REPO_FULL="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
        CLAIMED_AT=""
        if [[ -n "$REPO_FULL" ]]; then
          # Most recent `labeled` event for pr-fixing = when the claim was taken.
          CLAIMED_AT=$(gh api "repos/$REPO_FULL/issues/$PR/timeline" --paginate \
            --jq '.[] | select(.event=="labeled" and .label.name=="pr-fixing") | .created_at' \
            2>/dev/null | tail -n 1) || CLAIMED_AT=""
        fi
        CLAIMED_EPOCH=""
        if [[ -n "$CLAIMED_AT" && "$CLAIMED_AT" != "null" ]]; then
          # GNU date first (Linux/Git-Bash), BSD date fallback (macOS).
          CLAIMED_EPOCH=$(date -u -d "$CLAIMED_AT" +%s 2>/dev/null \
            || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$CLAIMED_AT" +%s 2>/dev/null) || CLAIMED_EPOCH=""
        fi
        if [[ -n "$CLAIMED_EPOCH" ]]; then
          CLAIM_AGE_MIN=$(( ($(date -u +%s) - CLAIMED_EPOCH) / 60 ))
          if [[ "$CLAIM_AGE_MIN" -lt "$CLAIM_TTL_MIN" ]]; then
            echo "refusing: PR #$PR already carries $FIXING — claimed ${CLAIM_AGE_MIN}m ago (< ${CLAIM_TTL_MIN}m TTL); another fix pass is likely in flight (issue #1174)" >&2
            echo "Back off instead of racing a duplicate fix. The claim self-expires after ${CLAIM_TTL_MIN}m (SGE_FIX_CLAIM_TTL_MIN); re-run with --force-claim to take over deliberately." >&2
            exit 3
          fi
          echo "PR #$PR: existing $FIXING claim is stale (${CLAIM_AGE_MIN}m >= ${CLAIM_TTL_MIN}m) — taking over (issue #1174)" >&2
        else
          echo "warning: PR #$PR carries $FIXING but the claim age could not be determined — proceeding (advisory guard, issue #1174)" >&2
        fi
      fi
    fi
    ensure_fixing_label
    add_label "$FIXING"
    STATUS="$(fix_claim_status)" || STATUS="(fix_claim_status unavailable)"
    echo "PR #$PR: fix claimed ($STATUS)"
    ;;

  release-fix)
    # Binding termination contract (issue #1174): /sge:pr-fix MUST call this on
    # exit — success, hand-back, or crash-trap — so the lane frees immediately
    # rather than waiting out the whole lease. Idempotent: remove_label tolerates
    # the label already being absent (released twice, or never claimed).
    remove_label "$FIXING"
    echo "PR #$PR: $FIXING released"
    ;;

  status)
    # Print gate label states. On GitHub: "reviewing=<bool> reviewed=<bool> hold=<bool>"
    # (issue #1393 extends the original reviewing/reviewed pair). On Forgejo the hold
    # mechanism is not wired (issue #1419), so keep the original two-field output
    # ("reviewing=<bool> reviewed=<bool>") — exact-match consumers on that host and
    # pr-labels-forgejo-adapter.test.sh depend on it.
    LS="$(label_status)" || { echo "error: could not read label state for PR #$PR" >&2; exit 1; }
    if [[ "${_PRL_HOST:-github}" == "forgejo" ]]; then
      printf '%s\n' "$LS"
    else
      HS="$(hold_status 2>/dev/null)" || HS="hold=unknown"
      printf '%s %s\n' "$LS" "$HS"
    fi
    ;;

  *)
    usage
    ;;
esac
