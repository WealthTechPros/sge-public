#!/usr/bin/env bash
# gate-labels.sh — HEAD-SCOPED verdict gate labels: the ONE rule for "does this
# gate label still describe the PR as it is now?" (wtp-org#992 item 4).
#
# A verdict label (`pr-reviewed`, `changes-requested`, `agent-reviewed`) records
# a judgement of ONE commit: the `commit:` of the latest trusted `sge-verdict`
# block. Once the PR head moves, that judgement is about a superseded commit and
# the label must not be read as current. Before this, stale labels outlived the
# head they judged (a `pr-reviewed` kept a PR out of review selection; a
# `changes-requested` kept reading as "waiting on the author" after the author
# pushed), because each reader decided currency its own way or not at all.
#
# One rule, three consumers, deliberately different safe directions:
#   * MERGE GATES (`current`; sge-auto-merge.yml) treat a label as present only
#     when `classify` says `current`. `stale` and `unproven` (no verdict /
#     malformed SHA / unreadable API) read as ABSENT -- fail closed: a label that
#     cannot prove it judged this head never opens a merge.
#   * The WRITER (`pr-labels.sh sync-check`, on every push) strips a label only
#     when `classify` says `stale` -- provably superseded. A missing or
#     unreadable verdict never deletes state; the merge gates already ignore it.
#   * The DAEMON's review selection (gate_labels.is_stale) re-selects a PR whose
#     `pr-reviewed` is provably `stale`; an `unproven` one keeps excluding it, so
#     a verdict the poll cannot see never becomes a re-review-every-cycle loop.
#
# Human holds (`hold`, `do-not-merge`, `needs-human`, `blocked`) are NOT verdict
# labels and are never head-scoped here: a hold is released by a person (or by a
# delegated order), never by a push.
#
# The Python twin (services/review-daemon-poc/gate_labels.py) implements the
# same `classify`; skills/tests/gate-labels-parity.test.sh runs both over the
# shared fixture table skills/pr-review/gate-labels.fixtures.tsv so they cannot
# drift.
#
# Usage:
#   gate-labels.sh list                              the verdict label set, one per line
#   gate-labels.sh classify <label> <verdict> <head> current|stale|unproven|not-verdict-label
#   gate-labels.sh verdict-sha <pr>                  latest trusted sge-verdict commit (empty if none; exit 3 on API error)
#   gate-labels.sh current <pr> <label> [<head>]     exit 0 iff <label> is ON the PR and current at head
# END_USAGE
#
# Sourceable: `source gate-labels.sh` defines the gl_* functions without running
# the CLI (pr-labels.sh sync-check uses them).

GL_VERDICT_LABELS=("pr-reviewed" "changes-requested" "agent-reviewed")

# gl_is_verdict_label <label>
gl_is_verdict_label() {
  local l
  for l in "${GL_VERDICT_LABELS[@]}"; do
    [[ "$l" == "$1" ]] && return 0
  done
  return 1
}

# gl_norm_sha <sha> -- lower-case; prints nothing (and returns 1) unless >= 7 hex chars.
gl_norm_sha() {
  local s
  s=$(printf '%s' "${1:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  [[ ${#s} -ge 7 && "$s" =~ ^[0-9a-f]+$ ]] || return 1
  printf '%s' "$s"
}

# gl_classify <label> <verdict-sha> <head-sha>
# Prints current | stale | unproven | not-verdict-label. Prefix match over the
# shorter SHA (both >= 7 hex), case-insensitive -- the same normalisation as
# `pr-labels.sh pass --expect-head`.
gl_classify() {
  local label="$1" verdict head v h n
  gl_is_verdict_label "$label" || { echo "not-verdict-label"; return 0; }
  h=$(gl_norm_sha "${3:-}") || { echo "unproven"; return 0; }
  v=$(gl_norm_sha "${2:-}") || { echo "unproven"; return 0; }
  n=$(( ${#v} < ${#h} ? ${#v} : ${#h} ))
  if [[ "${v:0:$n}" == "${h:0:$n}" ]]; then
    echo "current"
  else
    echo "stale"
  fi
}

# The trusted-author filter for sge-verdict blocks: the App/Actions bot logins
# or an OWNER/MEMBER/COLLABORATOR association (solo-profile operators post under
# their own account) -- the same trust anchor as verdict_trust.py (#1373/#1444)
# and the one sync-check has always used (#1941).
GL_TRUST_FILTER='.user.login == "wtp-sge[bot]" or .user.login == "github-actions[bot]"
     or (((.author_association // "") | ascii_upcase) as $assoc
         | $assoc == "OWNER" or $assoc == "MEMBER" or $assoc == "COLLABORATOR")'
# A DISMISSED (withdrawn) or PENDING (unsubmitted) review is not a verdict --
# the same exclusion as the Python twin's _latest_verdict_commit. Issue
# comments carry no .state, so they pass through the state filter.
GL_VERDICT_JQ='
    [.[] | select(.body != null)
     | select(((.state // "") | ascii_upcase) as $st | $st != "DISMISSED" and $st != "PENDING")
     | select('"$GL_TRUST_FILTER"')
     | select(.body | test("```sge-verdict"))
     | .body | split("\n")[] | select(test("^\\s*(commit|sha|head)\\s*:"))
     | capture(":\\s*(?<val>\\S+)") | .val
    ] | last // empty'

# gl_repo -- owner/name from GH_REPO, else `gh repo view`.
gl_repo() {
  if [[ -n "${GH_REPO:-}" ]]; then
    printf '%s' "$GH_REPO"
  else
    gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null
  fi
}

# gl_latest_verdict_sha <pr> -- the commit of the latest trusted sge-verdict:
# PR reviews first (where /sge:pr-review posts), then issue comments. Prints ""
# when there is none. Returns 3 when the API could not be read (callers must
# not mistake an outage for "no verdict").
gl_latest_verdict_sha() {
  local pr="$1" repo sha
  repo=$(gl_repo) || repo=""
  [[ -n "$repo" ]] || return 3
  sha=$(gh api "repos/$repo/pulls/$pr/reviews" --paginate --jq "$GL_VERDICT_JQ" 2>/dev/null) || return 3
  sha=$(printf '%s\n' "$sha" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n 1)
  if [[ -z "$sha" ]]; then
    sha=$(gh api "repos/$repo/issues/$pr/comments" --paginate --jq "$GL_VERDICT_JQ" 2>/dev/null) || return 3
    sha=$(printf '%s\n' "$sha" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n 1)
  fi
  printf '%s' "$sha"
}

# gl_current_labels <pr> -- the PR's labels NOW (API read, never an event payload).
gl_current_labels() {
  gh pr view "$1" --json labels --jq '.labels[].name' 2>/dev/null
}

gl_main() {
  local cmd="${1:-}"
  case "$cmd" in
    list)
      printf '%s\n' "${GL_VERDICT_LABELS[@]}"
      ;;
    classify)
      [[ $# -ge 4 ]] || { echo "usage: gate-labels.sh classify <label> <verdict-sha> <head-sha>" >&2; return 2; }
      gl_classify "$2" "$3" "$4"
      ;;
    verdict-sha)
      [[ -n "${2:-}" ]] || { echo "usage: gate-labels.sh verdict-sha <pr>" >&2; return 2; }
      gl_latest_verdict_sha "$2" || { echo "gate-labels: could not read verdicts for PR #$2" >&2; return 3; }
      echo
      ;;
    current)
      local pr="${2:-}" label="${3:-}" head="${4:-}" labels verdict state
      [[ -n "$pr" && -n "$label" ]] || { echo "usage: gate-labels.sh current <pr> <label> [<head>]" >&2; return 2; }
      if [[ -z "$head" ]]; then
        head=$(gh pr view "$pr" --json headRefOid --jq .headRefOid 2>/dev/null) || head=""
      fi
      labels=$(gl_current_labels "$pr") || { echo "PR #$pr: $label unreadable (labels API) -- treated as absent" >&2; return 1; }
      if ! printf '%s\n' "$labels" | grep -qxF "$label"; then
        echo "PR #$pr: $label absent"
        return 1
      fi
      verdict=$(gl_latest_verdict_sha "$pr") || { echo "PR #$pr: $label present but verdicts unreadable -- treated as absent (fail closed)"; return 1; }
      state=$(gl_classify "$label" "$verdict" "$head")
      case "$state" in
        current)
          echo "PR #$pr: $label current (verdict ${verdict:0:12} covers head ${head:0:12})"
          return 0 ;;
        not-verdict-label)
          echo "PR #$pr: $label is not a verdict label -- presence is all that counts"
          return 0 ;;
        *)
          echo "PR #$pr: $label $state (verdict '${verdict:0:12}', head '${head:0:12}') -- treated as absent (head-scoped, wtp-org#992)"
          return 1 ;;
      esac
      ;;
    ""|-h|--help|help)
      awk '/^# END_USAGE/{exit} f{sub(/^# ?/,""); print} /^# Usage:/{f=1; sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"
      return 2
      ;;
    *)
      echo "gate-labels.sh: unknown command '$cmd'" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  gl_main "$@"
  exit $?
fi
