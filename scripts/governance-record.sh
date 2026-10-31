#!/usr/bin/env bash
# governance-record.sh — write the governance record the enforced profile's
# governance-record gate looks for (SPEC-128, sge#3254).
#
# A governance record is an ordinary issue comment carrying one marker:
#   <!-- sge-governance: {"issue":N,"repo":"owner/repo","verdict":"<verdict>",
#        "matchedSpec":null,"mainSha":"<hex>","at":"<ISO-8601 Z>"} -->
# It is the governance-trace Step-7 verdict (issue and repo echo, verdict,
# matchedSpec) plus the default-branch sha it was classified against and a
# timestamp. It is EVIDENCE that the change was classified, not an approval:
# nothing is required to START a build, and a human still reviews at merge.
#
# Usage:
#   governance-record.sh build <verdict.json|-> [--main-sha <hex>]
#       Print the comment body (a short heading plus the marker).
#   governance-record.sh post <issueRef> <verdict.json|-> [--main-sha <hex>]
#       Post it as an ordinary comment through scripts/issue-write.sh (the ALM
#       write seam: GitHub, Azure DevOps, Jira), through $SGE_AUTHOR_WRAPPER when
#       the org's CLAUDE.md names one (an agent's comment is the agent App's).
#       Idempotent: when the issue already carries a record with the same fields
#       (everything but `at`), nothing is posted. If the existing comments
#       cannot be read it refuses, rather than risk a duplicate.
#
# The verdict must be a fresh classification: a cache-reused verdict, the
# NO_TARGET_ISSUE refusal, an unknown verdict, or a missing issue/repo echo is
# refused. Run from the target repo's checkout (SPEC-057), e.g.
#   "$SGE_ROOT/scripts/with-repo-cwd.sh" assert-repo owner/repo -- \
#     bash "$SGE_ROOT/scripts/governance-record.sh" post <N> <verdict.json>
#
# Test hooks: SGE_ISSUE_READ / SGE_ISSUE_WRITE name the seam scripts,
# SGE_RECORD_NOW pins the timestamp.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READ="${SGE_ISSUE_READ:-$HERE/issue-read.sh}"
WRITE="${SGE_ISSUE_WRITE:-$HERE/issue-write.sh}"
SHAPE="${SGE_RECORD_SHAPE:-$HERE/governance-record-shape.jq}"
VERDICTS='["MATCHES_EXISTING","MATCHES_EXISTING_MODIFIED","NEEDS_NEW_SPEC","NO_SPEC_WARRANTED","NOT_SGE_SCOPE","NOT_ONBOARDED"]'

err() { printf 'governance-record: %s\n' "$*" >&2; }
usage() { sed -n '/^# Usage:/,/^# The verdict/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { err "jq not found"; exit 1; }

# build_marker <verdict.json|-> <main-sha|''>  ->  the marker JSON, one line
build_marker() {
  local src="$1" sha="$2" raw at
  if [ "$src" = "-" ]; then raw="$(cat)"; else raw="$(cat "$src")" || { err "cannot read $src"; return 1; }; fi
  # The default branch tip, never this checkout's HEAD (a feature branch would record the wrong sha).
  if [ -z "$sha" ]; then sha="$(git rev-parse origin/HEAD 2>/dev/null || true)"; fi
  [[ "$sha" =~ ^[0-9a-f]{7,64}$ ]] || { err "cannot determine the default-branch sha (no origin/HEAD here); pass --main-sha <hex>"; return 1; }
  at="${SGE_RECORD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  local marker
  marker="$(printf '%s' "$raw" | jq -ce --arg sha "$sha" --arg at "$at" --argjson verdicts "$VERDICTS" '
    if type != "object" then error("not an object")
    elif .cacheReused == true then error("cache-reused verdict: a record needs a fresh classification")
    elif ((.issue // null) == null) then error("no issue echo")
    elif ((.repo // "") == "") then error("no repo echo")
    elif (.verdict | IN($verdicts[]) | not) then error("verdict is not a classification")
    else {issue, repo, verdict, matchedSpec: (.matchedSpec // null), mainSha: $sha, at: $at} end' 2>&1)" || true
  case "$marker" in '{'*) ;; *) err "refusing the verdict: ${marker#jq: error*: }"; return 1 ;; esac
  validate_marker "$marker" "$at" || return 1
  printf '%s\n' "$marker"
}

# validate_marker <marker-json> <at>: the record must pass the SAME shape rules the CI gate applies
# (scripts/governance-record-shape.jq: matchedSpec, mainSha, timestamp, verdict, echoes), and its
# repo echo must be this repo, so this script never posts a record the gate would reject.
validate_marker() {
  local m="$1" at="$2" repo issue expected shaped
  [ -f "$SHAPE" ] || { err "the shape rules (scripts/governance-record-shape.jq) are missing; refusing to post an unchecked record"; return 1; }
  repo="$(printf '%s' "$m" | jq -r '.repo | tostring')"; issue="$(printf '%s' "$m" | jq -r '.issue | tostring')"
  [[ "$repo" =~ ^[^/[:space:]]+(/[^/[:space:]]+)+$ ]] || { err "the repo echo '$repo' is not owner/name; refusing"; return 1; }
  expected="${SGE_REPO:-${GITHUB_REPOSITORY:-${GH_REPO:-}}}"
  if [ -n "$expected" ] && [ "$(printf '%s' "$repo" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$expected" | tr 'A-Z' 'a-z')" ]; then
    err "the verdict is for $repo but this checkout is $expected; the gate would reject the record, refusing"; return 1
  fi
  shaped="$(jq -n --arg b "<!-- sge-governance: $m -->" '[{body: $b, createdAt: ""}]' \
    | jq -c --arg ref "$issue" --arg repo "$repo" --arg today "${at%%T*}" --argjson verdicts "$VERDICTS" -f "$SHAPE" 2>/dev/null)" || shaped=""
  [ -n "$shaped" ] || { err "the record would fail the gate's shape rules (matchedSpec, mainSha, timestamp or verdict); refusing to post it"; return 1; }
}

# body <marker-json>
body() {
  local v s
  v="$(printf '%s' "$1" | jq -r .verdict)"; s="$(printf '%s' "$1" | jq -r '.matchedSpec // "none"')"
  printf '## Governance record\n\nVerdict: **%s** (matched spec: %s).\n\nThis records that the change was classified against the repo'"'"'s governance artefacts. It is evidence, not an approval: nothing needs it to start work, a pull request that closes this issue is checked for it (SPEC-128), and a human still reviews at merge.\n\n<!-- sge-governance: %s -->\n' "$v" "$s" "$1"
}

cmd="${1:-}"
case "$cmd" in
  build)
    [ -n "${2:-}" ] || usage
    sha=""; [ "${3:-}" = "--main-sha" ] && sha="${4:-}"
    m="$(build_marker "$2" "$sha")" || exit 1
    body "$m"
    ;;
  post)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || usage
    ref="$2"; sha=""; [ "${4:-}" = "--main-sha" ] && sha="${5:-}"
    m="$(build_marker "$3" "$sha")" || exit 1
    [ "$(printf '%s' "$m" | jq -r '.issue | tostring')" = "$ref" ] \
      || { err "issue $ref differs from the verdict's issue echo ($(printf '%s' "$m" | jq -r .issue)); refusing"; exit 1; }
    existing="$(bash "$READ" comments "$ref")" || { err "cannot read the comments of $ref to check for an existing record; not posting"; exit 1; }
    if printf '%s' "$existing" | jq -e --argjson m "$m" '
         [ .[] | (.body // "") | scan("<!--[[:space:]]*sge-governance:[[:space:]]*(\\{[^\\n]*?\\})[[:space:]]*-->") | .[0] | fromjson? | del(.at) ]
         | any(. == ($m | del(.at)))' >/dev/null 2>&1; then
      echo "governance-record: already recorded on $ref (identical record), nothing posted"; exit 0
    fi
    # shellcheck disable=SC2086  # the wrapper is one path, or empty
    ${SGE_AUTHOR_WRAPPER:+"$SGE_AUTHOR_WRAPPER"} bash "$WRITE" comment "$ref" "$(body "$m")"
    echo "governance-record: posted on $ref ($(printf '%s' "$m" | jq -r .verdict))"
    ;;
  -h|--help|help|'') usage ;;
  *) err "unknown command '$cmd'"; exit 2 ;;
esac
