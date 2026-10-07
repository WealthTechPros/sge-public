#!/usr/bin/env bash
# linked-prs.sh — the one "is this issue already done or in flight?" check (#2915).
#
# Lists the pull requests that reference an issue, so a caller can stop before
# opening a duplicate lane. Callers: sge-implement Step 0, available-issues'
# in_flight, issue-intake Step 1.2 and team-pipeline's queue build (four copies
# of this check were folded into this one script in #2915).
#
# Usage:
#   linked-prs.sh <N> [--state open|merged|closed|all] [--repo owner/repo]
#
# A PR counts as linked when:
#   - via=body   its body says `Part of #N`, `Closes #N`, `Fixes #N` or
#                `Resolves #N` (case-insensitive, and not #N0…). `Part of` is
#                what /sge:sge-implement writes on every draft PR, so searching
#                only the closing keywords misses most in-flight work (#2241).
#   - via=branch (open PRs only) its head branch is named for the issue:
#                `<prefix>/<N>-…`, `<prefix>/issue-<N>…`, `<prefix>/sge-<N>…`.
#
# GitHub does not index `#`, so `in:body "Part of #N"` matches any PR whose body
# holds the words "part", "of" and the number anywhere. Every search hit is
# re-checked client-side against the real reference before it is reported, so
# a false positive can never block an unrelated issue.
#
# Output: a JSON array on stdout, one object per PR, deduplicated by number:
#   {number, title, headRefName, url, state, isDraft, via}
# PR bodies are dropped: they are untrusted text and the caller does not need them.
#
# Exit: 0 = at least one linked PR · 1 = none · 2 = bad arguments or a gh
# failure. Treat 2 as "unknown" and fail closed (never as "not in flight").
#
# Test seam: SGE_LINKED_PRS_GH names the gh binary (skills/tests/linked-prs.test.sh).
set -uo pipefail

GH="${SGE_LINKED_PRS_GH:-gh}"
N="" STATE="open" REPO_ARGS=()

usage() { echo "usage: linked-prs.sh <N> [--state open|merged|closed|all] [--repo owner/repo]" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --state) [ $# -ge 2 ] || usage; STATE="$2"; shift 2 ;;
    --repo)  [ $# -ge 2 ] || usage; REPO_ARGS=(--repo "$2"); shift 2 ;;
    -h|--help) usage ;;
    -*) echo "linked-prs.sh: unknown flag $1" >&2; usage ;;
    *) [ -z "$N" ] || usage; N="$1"; shift ;;
  esac
done

[[ "$N" =~ ^[0-9]+$ ]] || { echo "linked-prs.sh: issue number must be numeric" >&2; usage; }
case "$STATE" in open|merged|closed|all) ;; *) echo "linked-prs.sh: bad --state $STATE" >&2; usage ;; esac
command -v jq >/dev/null 2>&1 || { echo "linked-prs.sh: jq is required" >&2; exit 2; }

FIELDS="number,title,headRefName,url,state,isDraft,body"
HITS="[]"

add() { # add <via> <json-array>
  HITS="$(jq -c --arg via "$1" --argjson new "$2" '. + [$new[] | . + {via: $via}]' <<<"$HITS")" || exit 2
}

# One --search per keyword: a single "A OR B" string is one loose free-text
# query on GitHub and misses matches.
for kw in "Part of" "Closes" "Fixes" "Resolves"; do
  out="$("$GH" pr list ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --state "$STATE" --limit 100 \
    --search "in:body \"$kw #$N\"" --json "$FIELDS")" || { echo "linked-prs.sh: gh pr list failed" >&2; exit 2; }
  real="$(jq -c --arg n "$N" '[.[] | select((.body // "") |
    test("(Part[[:space:]]+of|Closes|Fixes|Resolves)[[:space:]]*#" + $n + "([^0-9]|$)"; "i"))]' <<<"$out")" \
    || { echo "linked-prs.sh: unreadable gh output" >&2; exit 2; }
  add body "$real"
done

# Branch-name convention (open work only). `--head` does not prefix-match, so
# list open PRs and filter client-side.
if [ "$STATE" = "open" ] || [ "$STATE" = "all" ]; then
  out="$("$GH" pr list ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} --state open --limit 200 --json "$FIELDS")" \
    || { echo "linked-prs.sh: gh pr list failed" >&2; exit 2; }
  real="$(jq -c --arg n "$N" '[.[] | select((.headRefName // "") |
    test("(^|/)(issue-|sge-)?0*" + $n + "(-|_|$)"))]' <<<"$out")" \
    || { echo "linked-prs.sh: unreadable gh output" >&2; exit 2; }
  add branch "$real"
fi

RESULT="$(jq -c 'group_by(.number) | map(.[0] | del(.body))' <<<"$HITS")" || exit 2
printf '%s\n' "$RESULT"
[ "$(jq 'length' <<<"$RESULT")" -gt 0 ] && exit 0 || exit 1
