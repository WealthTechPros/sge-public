#!/usr/bin/env bash
# detect-admin-bypass.sh — fail-loud detection (not prevention) of `gh pr
# merge --admin` bypass merges (issue #2384, admin-bypass half of #2209).
#
# `gh pr merge --admin` cannot be prevented at the GitHub API level — branch
# protection has no "except when I say so" audit hook. What CAN be done is
# make a bypass merge detectably different from a routine one: check whether
# a merged PR's required contexts were all SUCCESS on its head SHA at merge
# time. If any required context was FAILURE/PENDING/missing, the merge could
# only have happened via an admin override — surface it visibly rather than
# let it look like a routine clean merge (per the 2026-08-19 decision on
# #2209: "any `gh pr merge --admin` bypass should be detectably logged — not
# indistinguishable from a routine merge").
#
# This pairs with #2219's declared-exception model: an admin bypass should
# always be an explicit, recorded exception, never a silent default path.
#
# Detection method:
#   1. Read the repo's required status-check contexts from branch protection
#      (`repos/{owner}/{repo}/branches/{base}/protection`).
#   2. For a merged PR, fetch check-runs for its HEAD sha (the commit that
#      carried the required-context verdicts pre-merge — the merge commit
#      itself has no check-run history of its own).
#   3. Collapse to the LATEST conclusion per check name (a check can have
#      been rerun; only the last run before merge matters) — check-runs are
#      returned newest-first by the API, so first-seen-per-name wins.
#   4. Any required context absent from that set, or present with a
#      conclusion other than "success", means the PR merged while that gate
#      was not green — i.e. only an admin override could have merged it.
#   5. Report via a rolling NDJSON log line and, unless --no-comment, an
#      idempotent (marker-keyed) PR comment.
#
# Usage:
#   detect-admin-bypass.sh --pr <N> [--base <branch>] [--no-comment] [--log <path>]
#   detect-admin-bypass.sh --scan [--since <ISO8601>] [--base <branch>] [--no-comment] [--log <path>]
#     --pr <N>       check one specific (already-merged) PR
#     --scan         check all recently-merged PRs (paginated, newest first,
#                     stops at the first PR merged before --since)
#     --since <ISO>  only used with --scan; default: 24 hours ago
#     --base <b>     base branch for required-context resolution (default:
#                     the repo's default branch)
#     --no-comment   skip posting the PR comment; log line only
#     --log <path>   rolling NDJSON log (default: $ADMIN_BYPASS_LOG or
#                     /tmp/admin-bypass.ndjson)
#
# Repo context: $GH_REPO if set, else `gh repo view` in the cwd clone.
#
# Output: one NDJSON line per merged PR examined (bypass or clean) appended
# to the log, and `bypass=<N> clean=<M>` summary on stdout. Exit 0 always —
# this is detection, not a gate; a merge already happened, there is nothing
# left to block. A PR flagged bypass=true is the actionable signal.
set -euo pipefail

MODE=""
PR=""
SINCE=""
BASE=""
POST_COMMENT=true
LOG="${ADMIN_BYPASS_LOG:-/tmp/admin-bypass.ndjson}"

usage() {
  sed -n '/^# Usage:/,/^# Repo context/{ /^# Repo context/d; p }' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pr) MODE="pr"; PR="$2"; shift 2 ;;
    --scan) MODE="scan"; shift ;;
    --since) SINCE="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --no-comment) POST_COMMENT=false; shift ;;
    --log) LOG="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
[ -n "$MODE" ] || usage

REPO="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"
if [ -z "$REPO" ]; then
  echo "detect-admin-bypass.sh: could not resolve target repo (set GH_REPO or cd into a clone)" >&2
  exit 1
fi

if [ -z "$BASE" ]; then
  BASE=$(gh api "repos/$REPO" --jq '.default_branch' 2>/dev/null) || BASE="main"
fi

if [ -z "$SINCE" ]; then
  SINCE=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)
fi

# Required context names for $BASE. Empty list -> nothing to compare against;
# treat as "no required contexts configured" (skip, not a false positive).
required_contexts() {
  gh api "repos/$REPO/branches/$BASE/protection" \
    --jq '.required_status_checks.contexts // [] | .[]' 2>/dev/null || true
}

# Latest conclusion per named check-run on a sha, one "name<TAB>conclusion"
# per line. check-runs are returned newest-first, so `!seen[name]++` keeps
# only the first (latest) occurrence of each name.
latest_check_conclusions() {
  local sha="$1"
  gh api --paginate "repos/$REPO/commits/$sha/check-runs" \
    --jq '.check_runs[] | [.name, (.conclusion // "pending")] | @tsv' 2>/dev/null \
    | awk -F'\t' '!seen[$1]++'
}

# Also fold in legacy commit statuses (some repos use the Statuses API
# instead of / alongside Checks) keyed the same way, latest-first per
# `commits/{sha}/statuses` semantics (also newest-first).
latest_commit_statuses() {
  local sha="$1"
  gh api --paginate "repos/$REPO/commits/$sha/statuses" \
    --jq '.[] | [.context, .state] | @tsv' 2>/dev/null \
    | awk -F'\t' '!seen[$1]++'
}

# Examine one merged PR. Prints "bypass" or "clean" on stdout; appends the
# NDJSON record; posts the comment (unless --no-comment) when bypass.
examine_pr() {
  local pr="$1"
  local merged_at head_sha merge_commit_sha
  read -r merged_at head_sha merge_commit_sha <<<"$(
    gh api "repos/$REPO/pulls/$pr" \
      --jq '[.merged_at // "", .head.sha // "", .merge_commit_sha // ""] | join(" ")' \
      2>/dev/null
  )"
  if [ -z "$merged_at" ] || [ "$merged_at" = "null" ]; then
    return 0   # not merged (or unreadable) — nothing to examine
  fi

  local req_ctx
  req_ctx=$(required_contexts)
  if [ -z "$req_ctx" ]; then
    echo "clean"
    return 0   # no required contexts configured for $BASE — nothing to violate
  fi

  local conclusions
  conclusions=$( { latest_check_conclusions "$head_sha"; latest_commit_statuses "$head_sha"; } \
    | awk -F'\t' '!seen[$1]++' )

  local bad_contexts=()
  local ctx state
  while IFS= read -r ctx; do
    [ -z "$ctx" ] && continue
    state=$(printf '%s\n' "$conclusions" | awk -F'\t' -v c="$ctx" '$1==c{print $2; exit}')
    # GitHub branch protection treats "success", "neutral" and "skipped"
    # (e.g. a path-filtered job that legitimately didn't run) as satisfying
    # a required check — only failure/cancelled/timed_out/action_required/
    # stale/pending/missing actually block a normal merge and therefore
    # signal a bypass when the PR merged anyway.
    case "${state:-missing}" in
      success|neutral|skipped) : ;;
      *) bad_contexts+=("$ctx=${state:-missing}") ;;
    esac
  done <<<"$req_ctx"

  local ts marker
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ "${#bad_contexts[@]}" -eq 0 ]; then
    printf '{"ts":"%s","repo":"%s","pr":%s,"merged_at":"%s","bypass":false}\n' \
      "$ts" "$REPO" "$pr" "$merged_at" >> "$LOG"
    echo "clean"
    return 0
  fi

  local bad_json
  bad_json=$(printf '%s\n' "${bad_contexts[@]}" | jq -R . | jq -s -c .)
  printf '{"ts":"%s","repo":"%s","pr":%s,"merged_at":"%s","head_sha":"%s","bypass":true,"bad_contexts":%s}\n' \
    "$ts" "$REPO" "$pr" "$merged_at" "$head_sha" "$bad_json" >> "$LOG"
  echo "bypass"

  if [ "$POST_COMMENT" = true ]; then
    marker="<!-- sge:admin-bypass-detected ${head_sha} -->"
    local existing
    existing=$(gh api --paginate "repos/$REPO/issues/$pr/comments" \
      --jq "[.[] | select(.body | contains(\"$marker\"))] | length" 2>/dev/null \
      | awk '{s+=$1} END{print s+0}')
    if [ "${existing:-0}" -eq 0 ]; then
      local reasons body
      reasons=$(printf '%s\n' "${bad_contexts[@]}" | sed 's/^/- `/; s/$/`/')
      body=$(printf '**Admin-bypass merge detected.**\n\nThis PR merged at `%s` while the following required context(s) were not green on the merge head (`%s`):\n\n%s\n\nOnly a `gh pr merge --admin` override can merge past a red required context — branch protection has no other path. Recorded here per the fail-loud detection policy (#2209, #2384): a bypass merge should never be silently indistinguishable from a routine one. If this was a declared, justified exception, note the reason in a follow-up comment; if not, treat the missing/failing gate(s) above as still owed.\n%s\n' \
        "$merged_at" "$head_sha" "$reasons" "$marker")
      gh pr comment "$pr" --body "$body" >/dev/null 2>&1 || true
    fi
  fi
}

BYPASS_COUNT=0
CLEAN_COUNT=0

if [ "$MODE" = "pr" ]; then
  [ -n "$PR" ] || usage
  result=$(examine_pr "$PR")
  case "$result" in
    bypass) BYPASS_COUNT=1 ;;
    clean) CLEAN_COUNT=1 ;;
  esac
else
  # --scan: newest-first merged PRs, stop once we pass $SINCE.
  since_epoch=$(date -u -d "$SINCE" +%s 2>/dev/null || date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$SINCE" +%s)
  page=1
  while :; do
    prs=$(gh api "repos/$REPO/pulls?state=closed&sort=updated&direction=desc&per_page=50&page=$page" \
      --jq '[.[] | select(.merged_at != null)] | .[] | [.number, .merged_at] | @tsv' 2>/dev/null)
    [ -z "$prs" ] && break
    stop=false
    while IFS=$'\t' read -r pr merged_at; do
      [ -z "$pr" ] && continue
      m_epoch=$(date -u -d "$merged_at" +%s 2>/dev/null || date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$merged_at" +%s)
      if [ "$m_epoch" -lt "$since_epoch" ]; then
        stop=true
        break
      fi
      result=$(examine_pr "$pr")
      case "$result" in
        bypass) BYPASS_COUNT=$((BYPASS_COUNT+1)) ;;
        clean) CLEAN_COUNT=$((CLEAN_COUNT+1)) ;;
      esac
    done <<<"$prs"
    [ "$stop" = true ] && break
    page=$((page+1))
  done
fi

echo "bypass=$BYPASS_COUNT clean=$CLEAN_COUNT"
