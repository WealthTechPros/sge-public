#!/usr/bin/env bash
# intake-check.sh — verify an issue carries a valid human intake approval
# before any agent builds it (SPEC-126, issue #2782).
#
# /sge:issue-intake posts a `## SGE intake` comment, from the approving
# human's own login, carrying one machine-readable marker:
#
#   <!-- sge-intake: {"issue":N,"repo":"owner/repo","mainSha":"<sha>",
#        "decision":"build|rescope|close-done|close-superseded|defer",
#        "scope":"...","acMap":[{"ac":"...","status":"met|partial|absent",
#        "refs":["path/file:LINE",...]}],"govtrace":{...Step-7 verdict...},
#        "approvedAt":"<ISO-8601 UTC>"} -->
#
# PASSES (exit 0, the marker JSON on stdout) only when ALL hold:
#   1. the NEWEST marker comment on the issue — by anyone — is the one judged:
#      a later marker from a bot or non-approver invalidates an earlier build;
#   2. its author is a human (user.type User, no `[bot]` login, not posted via
#      a GitHub App) listed in `intakeApprovers` of .claude/sge.json read from
#      the remote default branch (never the working tree);
#   3. the comment was not edited after posting;
#   4. the marker (the LAST `<!-- sge-intake:` opener in the comment) is
#      well-formed JSON for THIS issue and repo, with an ISO approvedAt no
#      later than the comment's server timestamp (+300 s clock skew);
#   5. decision is `build` or `rescope`;
#   6. the issue body/title was not edited after approval;
#   7. the comment is at most 14 days old;
#   8. mainSha is an ancestor of the freshly fetched default branch, and
#      every acMap ref is a plain repo-relative path that exists at mainSha
#      (`path:L`, `path:L-M`, `path#L` / `#L-L` line suffixes are stripped),
#      and no commit since mainSha touches any of them. An empty acMap, a row
#      without refs, or any other ref shape fails — the record is then not
#      freshness-checkable.
# Anything else fails closed: exit 1, one `intake-check: FAIL <reason>` line on
# stderr. Usage errors exit 2. There are deliberately no env knobs that relax
# any of the above (tests stub `gh` and `date` on PATH instead).
#
# Usage:
#   intake-check.sh <issue-number> [--govtrace-out <file>]
#     --govtrace-out  on a pass, write the marker's `govtrace` object to <file>
#                     (atomically) for sge-implement Phase 0.5 to adopt via
#                     `fork-util.mjs join`, which re-validates it. The file is
#                     removed first and stays absent on failure or when the
#                     marker carries no govtrace (Phase 0.5 then forks).
#
# Env: GH_REPO (optional) must match the checkout's origin (owner/repo).
# GitHub only; run from the target repo checkout (SPEC-057).
set -euo pipefail

MAX_AGE_DAYS=14
SKEW_SECONDS=300

fail() { printf 'intake-check: FAIL %s\n' "$*" >&2; exit 1; }
usage() { printf 'usage: intake-check.sh <issue-number> [--govtrace-out <file>]\n' >&2; exit 2; }
ADOPT='to adopt the intake gate, add "intakeApprovers": ["<github-login>", ...] to .claude/sge.json on the default branch (SPEC-126 DR1)'

N="${1:-}"
case "$N" in ''|*[!0-9]*) usage ;; esac
shift
GT_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --govtrace-out) [ $# -ge 2 ] || usage; GT_OUT="$2"; shift 2 ;;
    *) usage ;;
  esac
done
# A failed or verdict-less check must never leave an earlier verdict behind.
if [ -n "$GT_OUT" ]; then
  rm -f -- "$GT_OUT"
fi

command -v jq >/dev/null 2>&1 || fail "jq is required"
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a git checkout"
cd "$TOP"

# <rev>:<path> arguments are avoided throughout (MSYS rewrites them as path
# lists on Windows); blobs/entries are looked up with ls-tree instead.
tree_entry() { # <rev> <path> -> "<mode> <type> <oid>	<path>" or empty
  git ls-tree --full-tree "$1" -- "$2" 2>/dev/null
}

# Repo identity from the configured origin URL (raw config, not insteadOf-rewritten).
ORIGIN_URL="$(git config --get remote.origin.url)" || fail "no origin remote"
REPO="$(printf '%s' "$ORIGIN_URL" | sed -E 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)##; s#\.git$##')"
case "$REPO" in
  */*) ;;
  *) fail "origin $ORIGIN_URL is not a GitHub owner/repo URL" ;;
esac
if [ -n "${GH_REPO:-}" ]; then
  [ "$(printf '%s' "$GH_REPO" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$REPO" | tr 'A-Z' 'a-z')" ] \
    || fail "GH_REPO=$GH_REPO does not match origin $REPO"
fi

# Default branch, fetched now — staleness is never judged against a stale ref.
DEFAULT="$(git ls-remote --symref origin HEAD 2>/dev/null | sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p')"
[ -n "$DEFAULT" ] || fail "cannot resolve origin's default branch"
git fetch -q origin "refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" 2>/dev/null || fail "cannot fetch origin/$DEFAULT"
BASE="refs/remotes/origin/$DEFAULT"

# Approver allow-list: committed on the default branch only.
CFG_OID="$(tree_entry "$BASE" .claude/sge.json | awk '$2 == "blob" {print $3}')"
[ -n "$CFG_OID" ] || fail "no .claude/sge.json on origin/$DEFAULT — $ADOPT"
CFG="$(git cat-file blob "$CFG_OID")" || fail "cannot read .claude/sge.json on origin/$DEFAULT"
APPROVERS_JSON="$(printf '%s' "$CFG" | jq -c '[.intakeApprovers // [] | if type == "array" then .[] else empty end | strings | ascii_downcase | select(length > 0)]' 2>/dev/null)" \
  || fail "unparseable .claude/sge.json on origin/$DEFAULT"
[ "$(printf '%s' "$APPROVERS_JSON" | jq 'length')" -gt 0 ] \
  || fail "no intakeApprovers in .claude/sge.json on origin/$DEFAULT — $ADOPT"

COMMENTS="$(gh api --paginate "repos/$REPO/issues/$N/comments" \
  --jq '.[] | {login: (.user.login // ""), type: (.user.type // ""), app: .performed_via_github_app, created_at, updated_at, body: (.body // "")}' 2>/dev/null)" \
  || fail "cannot read comments for $REPO#$N"
# Newest marker comment, by anyone.
PICK="$(printf '%s\n' "$COMMENTS" | jq -s 'map(select(.body | contains("<!-- sge-intake:"))) | sort_by(.created_at) | last // empty')"
[ -n "$PICK" ] || fail "no sge-intake marker on $REPO#$N — run /sge:issue-intake $N"

LOGIN="$(printf '%s' "$PICK" | jq -r '.login')"
printf '%s' "$PICK" | jq -e '.type == "User" and .app == null and ((.login | ascii_downcase | endswith("[bot]")) | not)' >/dev/null \
  || fail "newest intake marker is bot- or app-authored ($LOGIN) — an agent cannot approve; a human must re-run /sge:issue-intake $N"
printf '%s' "$PICK" | jq -e --argjson ok "$APPROVERS_JSON" '(.login | ascii_downcase) as $l | $ok | index($l) != null' >/dev/null \
  || fail "newest intake marker author $LOGIN is not on the approver allow-list"
printf '%s' "$PICK" | jq -e '.created_at == .updated_at' >/dev/null \
  || fail "intake comment by $LOGIN was edited after posting — re-run /sge:issue-intake $N"

# The marker is the text after the LAST opener, up to its `-->`.
MARKER="$(printf '%s' "$PICK" | jq -r '.body | split("<!-- sge-intake:") | last | split("-->")[0]')"
printf '%s' "$MARKER" | jq -e --arg n "$N" --arg r "$REPO" --argjson created "$(printf '%s' "$PICK" | jq '.created_at | fromdateiso8601')" --argjson skew "$SKEW_SECONDS" '
  type == "object"
  and (.issue | tostring) == $n
  and ((.repo // "") | ascii_downcase) == ($r | ascii_downcase)
  and ((.mainSha // "") | test("^[0-9a-f]{7,40}$"))
  and ((.decision // "") | type == "string")
  and ((.approvedAt // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and ((.approvedAt | fromdateiso8601) <= ($created + $skew))
' >/dev/null 2>&1 || fail "malformed sge-intake marker (issue/repo mismatch, or bad issue, repo, mainSha, decision, approvedAt)"

DECISION="$(printf '%s' "$MARKER" | jq -r '.decision')"
case "$DECISION" in
  build|rescope) ;;
  *) fail "intake decision is '$DECISION' — only build or rescope may be implemented" ;;
esac

# Bind to the issue content: no body or title edit after approval.
OWNER="${REPO%%/*}"
NAME="${REPO#*/}"
EDITED="$(gh api graphql -F n="$N" -f o="$OWNER" -f r="$NAME" -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){lastEditedAt timelineItems(itemTypes:[RENAMED_TITLE_EVENT],last:1){nodes{... on RenamedTitleEvent{createdAt}}}}}}' \
  --jq '.data.repository.issue | [.lastEditedAt, (.timelineItems.nodes[]?.createdAt)] | map(select(. != null)) | max // ""' 2>/dev/null)" \
  || fail "cannot read edit history for $REPO#$N"
if [ -n "$EDITED" ]; then
  printf '%s' "$MARKER" | jq -e --arg e "$EDITED" '($e | fromdateiso8601) <= (.approvedAt | fromdateiso8601)' >/dev/null 2>&1 \
    || fail "issue $REPO#$N was edited at $EDITED, after approval — re-run /sge:issue-intake $N"
fi

NOW="$(date +%s)"
printf '%s' "$PICK" | jq -e --argjson now "$NOW" --argjson d "$MAX_AGE_DAYS" '(($now - (.created_at | fromdateiso8601)) / 86400) <= $d' >/dev/null 2>&1 \
  || fail "intake comment is older than $MAX_AGE_DAYS days — re-run /sge:issue-intake $N"

SHA="$(printf '%s' "$MARKER" | jq -r '.mainSha')"
git cat-file -e "$SHA^{commit}" 2>/dev/null || fail "mainSha $SHA not found on origin — re-run intake"
git merge-base --is-ancestor "$SHA" "$BASE" 2>/dev/null || fail "mainSha $SHA is not an ancestor of origin/$DEFAULT"

# acMap -> freshness anchor paths. Every row needs >= 1 ref; every ref must be
# a plain repo-relative path (after stripping a line suffix) that exists at mainSha.
REFS="$(printf '%s' "$MARKER" | jq -r '
  if (.acMap | type) != "array" or (.acMap | length) == 0 then error("empty acMap") else . end
  | .acMap[]
  | if type != "object" or ((.status // "") | IN("met", "partial", "absent") | not)
       or ((.refs | type) != "array") or (.refs | length) == 0
    then error("bad acMap row") else . end
  | .refs[]
  | if type != "string" then error("non-string ref") else . end
  | sub("(:L?[0-9]+(-L?[0-9]+)?|#L[0-9]+(-L[0-9]+)?)$"; "")
' 2>/dev/null)" || fail "acMap is not freshness-checkable (needs >= 1 row, each with status met|partial|absent and >= 1 string ref)"
PATHS=()
while IFS= read -r p; do
  p="${p%$'\r'}"
  case "$p" in
    ''|/*|:*|*://*|*\\*|*'*'*|*'?'*|*'['*|..|../*|*/../*|*/..) fail "acMap ref '$p' is not a plain repo-relative path" ;;
  esac
  [ -n "$(tree_entry "$SHA" "$p")" ] || fail "acMap ref '$p' does not exist at mainSha $SHA (name an existing file or directory)"
  PATHS+=("$p")
done <<< "$REFS"
[ "${#PATHS[@]}" -gt 0 ] || fail "acMap yields no freshness paths"
CHANGED="$(GIT_LITERAL_PATHSPECS=1 git log --format=%h "$SHA..$BASE" -- "${PATHS[@]}")" || fail "cannot list commits $SHA..origin/$DEFAULT"
[ -z "$CHANGED" ] || fail "stale intake: $(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ') commit(s) on acMap paths since $SHA — re-run /sge:issue-intake $N"

if [ -n "$GT_OUT" ] && printf '%s' "$MARKER" | jq -e '.govtrace | type == "object"' >/dev/null 2>&1; then
  TMP_GT="$(mktemp "$GT_OUT.XXXXXX")" || fail "cannot create a temp file beside $GT_OUT"
  printf '%s' "$MARKER" | jq '.govtrace' > "$TMP_GT"
  mv -f -- "$TMP_GT" "$GT_OUT"
fi

printf '%s' "$MARKER" | jq -c --arg by "$LOGIN" '. + {approvedBy: $by}'
