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
#   6. the issue title was not renamed after approval, and the body was not
#      edited after approval except to tick/untick task-list checkboxes
#      (closure-integrity ticks, #2829) — the approved body is rebuilt from
#      the issue's edit history; a history that cannot rebuild it fails closed;
#   7. the comment is at most 14 days old;
#   8. mainSha is an ancestor of the freshly fetched default branch, and
#      every acMap ref is a plain repo-relative path that exists at mainSha
#      (`path:L`, `path:L-M`, `path#L` / `#L-L` line suffixes are stripped),
#      and no commit since mainSha that touches any of them references this
#      issue (`#N` in its message) — that is how a cited acceptance criterion
#      changes status; an unrelated commit sharing a file does not (#2829).
#      An empty acMap, a row
#      without refs, or any other ref shape fails — the record is then not
#      freshness-checkable;
#   9. no PR whose body says `Part of #N` merged after approvedAt (#2796): a
#      merged slice stales the record whichever paths it touched, so an issue
#      reconcile-worklist.mjs lists under partial[] needs a fresh intake. A
#      failed or incomplete search fails closed.
# Anything else fails closed: exit 1, one `intake-check: FAIL <reason>` line on
# stderr. Usage errors exit 2. There are deliberately no env knobs that relax
# any of the above (tests stub `gh` and `date` on PATH instead).
#
# What a pass proves (issue #2913): the newest marker was posted, unedited, by
# an allow-listed approver's own non-bot, non-App GitHub account. It does NOT
# prove a human typed it: an agent session holding that approver's `gh` login
# would pass. Unattended sessions (SGE_UNATTENDED=1) are blocked from posting a
# marker by hooks/intake-marker-guard.sh; an ATTENDED agent session using a
# human's login is kept out by policy (agents write as the agentBotLogin App), not by
# this check (SPEC-126 Known limits). The guard arms only when SGE_UNATTENDED
# is exactly "1" in the hook process's own environment: an export inside a
# Bash call or an orchestrator's environment does not reach a dispatched
# lane's hooks (docs/unattended-mode.md section 6), so a lane launched without
# it is not covered.
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
# Run from the target repo checkout (SPEC-057).
#
# ALM (SPEC-126 §3, issue #2985): GitHub Issues (SGE_ALM_BACKEND unset/github)
# and Azure DevOps Boards (SGE_ALM_BACKEND=azdo); any other ALM fails closed.
# On Boards, <issue-number> is the work-item id and every read goes through
# scripts/azdo-adapter.sh (SPEC-110 §2.5 boundary: SGE_AZDO_TOKEN,
# SGE_AZDO_HOSTS, SGE_AZDO_ORG, SGE_AZDO_PROJECT). The same rules apply with
# Boards primitives:
#   1. newest marker among the work item's comments (item-comments);
#   2. author must be a human Azure DevOps identity — descriptor `aad.` or
#      `msa.`; a service principal (`aadsp.`), build service / service
#      identity (`svc.`) or any other subject type is rejected — and listed in
#      intakeApprovers by descriptor or by unique name (an entry containing
#      `@`, so a GitHub login can never match an ADO identity);
#   3. the comment was never edited (version 1, modifiedDate == createdDate)
#      and is not deleted;
#   6. no System.Title change after approval, and System.Description at
#      approval (rebuilt from item-updates) equals today's up to checkbox ticks;
#   9. no linked PR artefact (native ArtifactLink, DR6) completed after
#      approval.
# repo in the marker is owner/repo for a GitHub origin, org/project/repo for an
# Azure Repos origin.
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
# ALM backend (SPEC-126 §3): github or azdo; anything else fails closed.
SGE_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALM="$(bash "$SGE_SCRIPTS/with-repo-cwd.sh" alm 2>/dev/null | tr -d '\r\n')" || fail "cannot resolve the ALM backend (SGE_ALM_BACKEND) — refusing"
case "$ALM" in
  github|azdo) ;;
  *) fail "ALM backend '$ALM' is not supported by the intake gate (GitHub and Azure DevOps Boards only, SPEC-126 §3)" ;;
esac
AA="$SGE_SCRIPTS/azdo-adapter.sh"
if [ "$ALM" = azdo ] && [ "$(bash "$SGE_SCRIPTS/with-repo-cwd.sh" host 2>/dev/null | tr -d '\r\n')" = azdo ]; then
  REPO="$(bash "$AA" repo-id "$ORIGIN_URL" 2>/dev/null | tr -d '\r')" || fail "origin is not a parseable Azure Repos URL"
else
REPO="$(printf '%s' "$ORIGIN_URL" | sed -E 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)##; s#\.git$##')"
fi
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

if [ "$ALM" = azdo ]; then
# ── Azure DevOps Boards (rules 1-3) ──────────────────────────────────────────
# ADO dates carry fractional seconds; jq's fromdateiso8601 does not, so every
# timestamp is normalised to whole seconds before it is compared.
RAW_COMMENTS="$(bash "$AA" item-comments "$N")" || fail "cannot read comments for work item $N"
PICK="$(printf '%s' "$RAW_COMMENTS" | jq -c '
  def iso: (. // "") | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z");
  def unhtml: gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&quot;"; "\"") | gsub("&#39;"; "\u0027") | gsub("&amp;"; "&");
  [ .[] | select((.isDeleted // false) | not)
    | ((.text // "") | if contains("&lt;!-- sge-intake:") then unhtml else . end) as $t
    | select($t | contains("<!-- sge-intake:"))
    | { login: (.createdBy.uniqueName // ""), descriptor: (.createdBy.descriptor // ""),
        display: (.createdBy.displayName // ""), version: (.version // 0),
        created_at: (.createdDate | iso), updated_at: ((.modifiedDate // .createdDate) | iso), body: $t } ]
  | sort_by(.created_at) | last // empty' 2>/dev/null)" || fail "cannot read comments for work item $N"
[ -n "$PICK" ] || fail "no sge-intake marker on work item $N — run /sge:issue-intake $N"
LOGIN="$(printf '%s' "$PICK" | jq -r '.login')"
# Human identity only: an AAD or MSA user descriptor. Service principals
# (aadsp.), build service and other service identities (svc.), and every other
# subject type fail closed, as does a display name of a build service.
printf '%s' "$PICK" | jq -e '(.descriptor | test("\\A(aad|msa)\\.[A-Za-z0-9_=-]+\\z")) and ((.display | test("build service"; "i")) | not)' >/dev/null \
  || fail "newest intake marker on work item $N is authored by a service identity ($LOGIN) — only an approver's own human Azure DevOps account counts; the approver must re-run /sge:issue-intake $N from their own session"
printf '%s' "$PICK" | jq -e --argjson ok "$APPROVERS_JSON" '
  ((.descriptor | ascii_downcase) as $d | $ok | index($d) != null)
  or ((.login | ascii_downcase) as $u | ($u | contains("@")) and ($ok | index($u) != null))' >/dev/null \
  || fail "newest intake marker author $LOGIN is not on the approver allow-list"
printf '%s' "$PICK" | jq -e '.version == 1 and .created_at == .updated_at' >/dev/null \
  || fail "intake comment by $LOGIN was edited after posting — re-run /sge:issue-intake $N"
else
COMMENTS="$(gh api --paginate "repos/$REPO/issues/$N/comments" \
  --jq '.[] | {login: (.user.login // ""), type: (.user.type // ""), app: .performed_via_github_app, created_at, updated_at, body: (.body // "")}' 2>/dev/null)" \
  || fail "cannot read comments for $REPO#$N"
# Newest marker comment, by anyone.
PICK="$(printf '%s\n' "$COMMENTS" | jq -s 'map(select(.body | contains("<!-- sge-intake:"))) | sort_by(.created_at) | last // empty')"
[ -n "$PICK" ] || fail "no sge-intake marker on $REPO#$N — run /sge:issue-intake $N"

LOGIN="$(printf '%s' "$PICK" | jq -r '.login')"
printf '%s' "$PICK" | jq -e '.type == "User" and .app == null and ((.login | ascii_downcase | endswith("[bot]")) | not)' >/dev/null \
  || fail "newest intake marker is bot- or app-authored ($LOGIN) — only an approver's own non-bot GitHub account counts; the approver must re-run /sge:issue-intake $N from their own session"
printf '%s' "$PICK" | jq -e --argjson ok "$APPROVERS_JSON" '(.login | ascii_downcase) as $l | $ok | index($l) != null' >/dev/null \
  || fail "newest intake marker author $LOGIN is not on the approver allow-list"
printf '%s' "$PICK" | jq -e '.created_at == .updated_at' >/dev/null \
  || fail "intake comment by $LOGIN was edited after posting — re-run /sge:issue-intake $N"
fi

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

# Bind to the issue content: no title rename and no body edit after approval,
# except task-list checkbox ticks (closure-integrity, #2829), optionally with
# trailing-whitespace or trailing-newline differences (#2935). Each
# userContentEdits[].diff holds the full body as of that revision; the newest
# revision at or before approvedAt is the approved body. A history that cannot
# reconstruct it fails closed.
APPROVED_AT="$(printf '%s' "$MARKER" | jq -r '.approvedAt')"
after_approval() { # <iso-ts> -> exit 0 when strictly after approvedAt
  ! jq -en --arg e "$1" --arg at "$APPROVED_AT" '($e | fromdateiso8601) <= ($at | fromdateiso8601)' >/dev/null 2>&1
}
if [ "$ALM" = azdo ]; then
# ── Boards content binding (rule 6) ─────────────────────────────────────────
UPDATES="$(bash "$AA" item-updates "$N")" || fail "cannot read edit history for work item $N"
CUR_FILE="$(mktemp)" || fail "mktemp failed"
bash "$AA" view-item "$N" > "$CUR_FILE" || { rm -f "$CUR_FILE"; fail "cannot read work item $N"; }
printf '%s' "$UPDATES" | jq -e --arg at "$APPROVED_AT" '
  def iso: (. // "") | sub("\\.[0-9]+"; "");
  ($at | fromdateiso8601) as $a
  | [ .[] | select(.fields["System.Title"] != null) ]
  | all(.[]; (.fields["System.ChangedDate"].newValue // "") as $t
             | $t != "" and (($t | iso | fromdateiso8601) <= $a))' >/dev/null 2>&1 \
  || { rm -f "$CUR_FILE"; fail "work item $N title was changed after approval (or its change time is unreadable) — re-run /sge:issue-intake $N"; }
printf '%s' "$UPDATES" | jq -e --arg at "$APPROVED_AT" --slurpfile curs "$CUR_FILE" '
  def iso: (. // "") | sub("\\.[0-9]+"; "");
  def norm: gsub("\r"; "") | split("\n")
    | map(sub("^(?<p>[ \t]*(?:[-*+]|[0-9]+[.)])[ \t]+)\\[[xX ]\\]"; "\(.p)[ ]") | sub("[ \t]+\\z"; ""))
    | join("\n") | sub("\n+\\z"; "");
  ($curs[0]) as $cur
  | ($at | fromdateiso8601) as $a
  | [ .[] | select(.fields["System.Description"] != null) ] as $d
  | if any($d[]; (.fields["System.ChangedDate"].newValue // "") == "") then false
    else ([ $d[] | select((.fields["System.ChangedDate"].newValue | iso | fromdateiso8601) <= $a) ] | last
          | (.fields["System.Description"].newValue // "")) as $before
      | (($cur.fields["System.Description"] // "") | norm) == ($before | norm) end' >/dev/null 2>&1 \
  || { rm -f "$CUR_FILE"; fail "work item $N was edited after approval (beyond checkbox ticks) — re-run /sge:issue-intake $N"; }
rm -f "$CUR_FILE"
else
OWNER="${REPO%%/*}"
NAME="${REPO#*/}"
ISSUE_J="$(gh api graphql -F n="$N" -f o="$OWNER" -f r="$NAME" -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){body lastEditedAt userContentEdits(first:100){nodes{editedAt diff}} timelineItems(itemTypes:[RENAMED_TITLE_EVENT],last:1){nodes{... on RenamedTitleEvent{createdAt}}}}}}' \
  --jq '.data.repository.issue' 2>/dev/null)" \
  || fail "cannot read edit history for $REPO#$N"
printf '%s' "$ISSUE_J" | jq -e 'type == "object"' >/dev/null 2>&1 || fail "cannot read edit history for $REPO#$N"
RENAMED="$(printf '%s' "$ISSUE_J" | jq -r '[.timelineItems.nodes[]?.createdAt | select(. != null)] | max // ""')"
if [ -n "$RENAMED" ] && after_approval "$RENAMED"; then
  fail "issue $REPO#$N title was renamed at $RENAMED, after approval — re-run /sge:issue-intake $N"
fi
EDITED="$(printf '%s' "$ISSUE_J" | jq -r '.lastEditedAt // ""')"
if [ -n "$EDITED" ] && after_approval "$EDITED"; then
  # shellcheck disable=SC2016  # jq program, not shell expansion
  printf '%s' "$ISSUE_J" | jq -e --arg at "$APPROVED_AT" '
    def norm: gsub("\r"; "") | split("\n")
      | map(sub("^(?<p>[ \t]*(?:[-*+]|[0-9]+[.)])[ \t]+)\\[[xX ]\\]"; "\(.p)[ ]") | sub("[ \t]+\\z"; ""))
      | join("\n") | sub("\n+\\z"; "");
    ($at | fromdateiso8601) as $a
    | ([.userContentEdits.nodes[]? | select(.editedAt != null and (.editedAt | fromdateiso8601) <= $a)]
       | sort_by(.editedAt | fromdateiso8601) | last | .diff) as $before
    | $before != null and ((.body // "") | norm) == ($before | norm)' >/dev/null 2>&1 \
    || fail "issue $REPO#$N was edited at $EDITED, after approval (beyond checkbox ticks) — re-run /sge:issue-intake $N"
fi
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
# Staleness (#2829): only a commit on a cited path whose message references
# THIS issue can change a cited acceptance criterion's status; an unrelated
# commit that merely shares a file does not. `#N` must not be a prefix of a
# longer number (#70 never matches #7).
CHANGED="$(GIT_LITERAL_PATHSPECS=1 git log -E --grep="(^|[^[:alnum:]_])#$N([^[:digit:]]|\$)" --format=%h "$SHA..$BASE" -- "${PATHS[@]}")" || fail "cannot list commits $SHA..origin/$DEFAULT"
[ -z "$CHANGED" ] || fail "stale intake: $(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ') commit(s) referencing #$N on acMap paths since $SHA (an acceptance criterion may have changed status) — re-run /sge:issue-intake $N"

if [ "$ALM" = azdo ]; then
# Rule 9 on Boards: a natively linked PR (DR6) completed after approval.
LINKED="$(bash "$AA" item-linked-prs "$N")" || fail "cannot read linked PRs of work item $N"
LATE="$(printf '%s' "$LINKED" | jq -r --arg at "$APPROVED_AT" '
  .[] | select(.status == "completed" and .closedDate != ""
               and ((.closedDate | sub("\\.[0-9]+"; "") | fromdateiso8601) > ($at | fromdateiso8601)))
  | "PR \(.id)"' 2>/dev/null)" || fail "cannot read linked PRs of work item $N (malformed)"
[ -z "$LATE" ] || fail "stale intake: linked $(printf '%s' "$LATE" | tr '\n' ' ' | sed 's/ $//') completed after approval — re-run /sge:issue-intake $N for the remainder"
else
# Merged `Part of #N` slices after approval (rule 9). The search is a
# candidate list only; the body match and merge time are re-checked here.
PARTOF="$(gh api -X GET search/issues -f q="repo:$REPO is:pr is:merged in:body \"Part of #$N\"" -f per_page=100 \
  --jq '{incomplete: .incomplete_results, items: [.items[] | {number, body: (.body // ""), merged_at: (.pull_request.merged_at // "")}]}' 2>/dev/null)" \
  || fail "cannot search merged Part-of PRs for $REPO#$N"
LATE="$(printf '%s' "$PARTOF" | jq -r --arg n "$N" --arg at "$(printf '%s' "$MARKER" | jq -r '.approvedAt')" '
  if .incomplete != false or (.items | type) != "array" then error("incomplete") else . end
  | .items[]
  | select(.body | test("part of #" + $n + "([^0-9]|$)"; "i"))
  | select(.merged_at != "" and ((.merged_at | fromdateiso8601) > ($at | fromdateiso8601)))
  | "#\(.number)"' 2>/dev/null)" \
  || fail "cannot search merged Part-of PRs for $REPO#$N (incomplete or malformed result)"
[ -z "$LATE" ] || fail "stale intake: Part-of PR(s) $(printf '%s' "$LATE" | tr '\n' ' ' | sed 's/ $//') merged after approval — re-run /sge:issue-intake $N for the remainder"
fi

if [ -n "$GT_OUT" ] && printf '%s' "$MARKER" | jq -e '.govtrace | type == "object"' >/dev/null 2>&1; then
  TMP_GT="$(mktemp "$GT_OUT.XXXXXX")" || fail "cannot create a temp file beside $GT_OUT"
  printf '%s' "$MARKER" | jq '.govtrace' > "$TMP_GT"
  mv -f -- "$TMP_GT" "$GT_OUT"
fi

printf '%s' "$MARKER" | jq -c --arg by "$LOGIN" '. + {approvedBy: $by}'
