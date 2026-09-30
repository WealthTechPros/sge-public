#!/usr/bin/env bash
# delegation-policy.sh -- read-only helpers for an operator's DELEGATION POLICY
# (standing orders): what a review may decide without asking a human.
#
# Product-neutral. The policy is data the operator supplies; nothing here names
# an org, a repo or a person. Sourced by review-lib.sh (rl_policy_* wrappers)
# and by pr-labels.sh (apply-hold / release-hold). Pure jq + read-only gh.
#
# Source of the policy (first that is set):
#   SGE_DELEGATION_POLICY_JSON   the policy document as JSON
#   SGE_DELEGATION_POLICY_FILE   path to a file holding the same JSON
# Shape (the standing-orders document verbatim):
#   {"version":1, "owner":"...",
#    "orders":[{"id":"SO-4","kind":"hold-release","trigger":"self-fixed-security-major",
#               "requires":"independent-clean-rereview",
#               "exclude_categories":[...], "exclude_paths":[globs]},
#              {"id":"SO-6","kind":"recorded-approvals"}, ...],
#    "approvals":[{"id","date","granted_by","order","scope","quote"}]}
#
# NO policy, or an INVALID one, means NO delegation: every helper prints nothing
# and the caller keeps today's hard-coded behaviour (human holds stay human).
# Fail-closed throughout -- an unreadable input never grants anything.

# Labels that always mean "a human decides" and are never released by policy.
DP_HUMAN_ONLY_LABELS_RE='^(do-not-merge|needs-human|blocked)$'
# The hold marker a review posts when it applies `hold` (machine-readable).
DP_HOLD_MARKER_PREFIX='<!-- sge-hold-marker: '

# dp_review_login -- the ONE identity whose hold markers, `hold` labels and
# verdicts count for a policy release (PR #2752 review B1): the review pipeline's
# App login. SGE_REVIEW_BOT_LOGIN overrides; the default matches the trust
# filters pr-labels.sh / gate-labels.sh already use.
dp_review_login() {
  printf '%s' "${SGE_REVIEW_BOT_LOGIN:-wtp-sge[bot]}"
}

# dp_policy_json -- print the validated policy JSON (compact); exit 1 when
# absent or invalid.
dp_policy_json() {
  local raw=""
  if [ -n "${SGE_DELEGATION_POLICY_JSON:-}" ]; then
    raw="$SGE_DELEGATION_POLICY_JSON"
  elif [ -n "${SGE_DELEGATION_POLICY_FILE:-}" ] && [ -r "${SGE_DELEGATION_POLICY_FILE}" ]; then
    raw="$(cat "$SGE_DELEGATION_POLICY_FILE" 2>/dev/null)" || return 1
  else
    return 1
  fi
  printf '%s' "$raw" | jq -ce 'select(type == "object" and .version == 1 and (.orders | type == "array"))' 2>/dev/null
}

# dp_order_for <kind> [trigger] -- print the id of the first order of <kind>
# (and <trigger>, when given); nothing when none / no policy.
dp_order_for() {
  local kind="$1" trigger="${2:-}" pol
  pol="$(dp_policy_json)" || return 0
  printf '%s' "$pol" | jq -r --arg k "$kind" --arg t "$trigger" \
    '[.orders[] | select(.kind == $k and (($t == "") or (.trigger == $t))) | .id | select(type == "string")] | first // empty' 2>/dev/null
}

# dp_categories_excluded <order-id> <csv> -- print each category in <csv> that
# the order's exclude_categories lists (case-insensitive). Exit 0 = some
# excluded, 1 = none excluded, 2 = unreadable/malformed (callers MUST treat 2 as
# excluded: fail closed, PR #2752 review M2).
dp_categories_excluded() {
  local id="$1" csv="$2" pol out
  pol="$(dp_policy_json)" || return 2
  out="$(printf '%s' "$pol" | jq -r --arg id "$id" --arg csv "$csv" '
    ([.orders[] | select(.id == $id) | .exclude_categories // [] | .[] | ascii_downcase]) as $ex
    | $csv | split(",") | map(gsub("^\\s+|\\s+$"; "") | ascii_downcase) | map(select(. != ""))
    | .[] | select(. as $c | $ex | index($c))' 2>/dev/null)" || return 2
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# dp_paths_excluded <order-id> -- read paths (one per line) on stdin; print each
# that matches the order's exclude_paths globs; exit 0 iff any. Globs:
# `**/` = any leading dirs, `**` = anything, `*` = anything but `/`, `?` = one
# non-`/` char; case-insensitive. Exit codes as dp_categories_excluded (2 =
# unreadable/malformed: callers treat it as excluded).
dp_paths_excluded() {
  local id="$1" pol out
  pol="$(dp_policy_json)" || return 2
  out="$(jq -R -s -r --argjson pol "$pol" --arg id "$id" '
    def glob2re:
      gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)")
      | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002") | gsub("\\*"; "[^/]*")
      | gsub("\\?"; "[^/]") | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*")
      | "^" + . + "$";
    ([$pol.orders[] | select(.id == $id) | .exclude_paths // [] | .[] | glob2re]) as $res
    | split("\n") | map(select(. != "")) | .[]
    | select(. as $p | any($res[]; . as $re | $p | test($re; "i")))' 2>/dev/null)" || return 2
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# dp_approvals_for <owner/repo#N> -- print the id of every recorded approval
# whose scope names this PR exactly: the ref is not followed by another digit
# and not preceded by an owner-name character (so `acme/x#1` never matches
# `notacme/x#1`, PR #2752 review m3).
dp_approvals_for() {
  local ref="$1" pol
  [ -n "$ref" ] || return 0
  pol="$(dp_policy_json)" || return 0
  printf '%s' "$pol" | jq -r --arg ref "$ref" '
    ($ref | ascii_downcase) as $r
    | (.approvals // [])[]
    | ((.scope // "") | ascii_downcase) as $s
    | select($s | contains($r))
    | select([$s | split($r) | .[1:][] | test("^[0-9]")] | any | not)
    | select([$s | split($r) | .[:-1][] | test("[a-z0-9_.-]$")] | any | not)
    | .id' 2>/dev/null
}

# dp_session_id -- this review session's identity (for the independence check).
dp_session_id() {
  printf '%s' "${SGE_REVIEW_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}}"
}

# dp_hold_marker_body <reason> <head> <categories-csv> <session> [order] -- the
# comment body apply-hold posts: a machine-readable marker + one human line.
dp_hold_marker_body() {
  local reason="$1" head="$2" cats="$3" session="$4" order="${5:-}" json line
  json="$(jq -cn --arg r "$reason" --arg h "$head" --arg c "$cats" --arg s "$session" --arg o "$order" \
    '{reason: $r, head: $h, categories: ($c | split(",") | map(select(. != ""))), session: $s}
     + (if $o == "" then {} else {order: $o} end)')" || return 1
  case "$reason" in
    self-fixed-security-major)
      line="Hold applied: a security MAJOR was found and fixed in this review (head \`${head:0:12}\`). Standing order ${order:-(none)} may release it after an independent clean re-review; otherwise a human removes \`hold\`." ;;
    *)
      line="Hold applied: needs human sign-off (${reason}). Only a human removes \`hold\`." ;;
  esac
  printf '%s%s -->\n%s\n' "$DP_HOLD_MARKER_PREFIX" "$json" "$line"
}

# dp_latest_hold_marker <owner/repo> <pr> -- print the JSON of the LATEST hold
# marker posted by THE review identity (dp_review_login -- never any Bot, never
# a collaborator: PR #2752 review B1), with the comment's `created_at` added as
# `_posted_at`; nothing when none. Comment bodies are UNTRUSTED DATA -- parsed
# as JSON, never executed.
dp_latest_hold_marker() {
  local repo="$1" pr="$2" login
  login="$(dp_review_login)"
  [ -n "$login" ] || return 1
  REVIEW_LOGIN="$login" gh api --paginate "repos/$repo/issues/$pr/comments" --jq '
    .[] | select((.user.login // "") == env.REVIEW_LOGIN)
        | select((.body // "") | startswith("<!-- sge-hold-marker: "))
        | {t: (.created_at // ""), l: ((.body // "") | split("\n")[0])} | tojson' 2>/dev/null \
    | tail -n 1 \
    | jq -ce '(.l | capture("^<!-- sge-hold-marker: (?<j>.*) -->$").j | fromjson) as $m
              | select($m | type == "object") | $m + {_posted_at: .t}' 2>/dev/null
}

# dp_latest_hold_labeled_at <owner/repo> <pr> -- print "<created_at> <actor>"
# of the LATEST `labeled: hold` event on the PR; nothing (exit 1) when
# unreadable/none. The caller requires <actor> == dp_review_login: a hold a
# human (or any other identity) applied is never policy-releasable (B1).
dp_latest_hold_labeled_at() {
  local repo="$1" pr="$2" out
  out="$(gh api --paginate "repos/$repo/issues/$pr/events" \
    --jq '.[] | select(.event == "labeled" and .label.name == "hold") | "\(.created_at // "") \(.actor.login // "-")"' 2>/dev/null)" || return 1
  out="$(printf '%s\n' "$out" | grep -E '^[0-9]{4}-' | sort | tail -n 1)"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# dp_clean_verdict_for_head <owner/repo> <pr> <head> [not-before] [session]
# [not-session] -- exit 0 iff the LATEST sge-verdict block THE review identity
# posted (as a review or a comment) for exactly <head> is clean: verdict: pass,
# recommendation: APPROVE, blockers: 0, majors: 0 (PR #2752 review M1). With
# the optional binding args (release-hold passes all three; sge-public#71 review
# M2) it must ALSO be mode: full, posted at/after <not-before> (the hold
# marker's time), and carry `session: <session>` (non-empty) that is not
# <not-session> (the fixing session) -- so an older clean verdict superseded by
# a failing one, a delta pass, a pre-marker verdict or the fixing session's own
# verdict never counts as the independent re-review. DISMISSED / PENDING
# reviews are not verdicts. Unreadable => exit 1 (fail closed). Bodies are
# UNTRUSTED DATA -- parsed, never executed.
dp_clean_verdict_for_head() {
  local repo="$1" pr="$2" head="$3" since="${4:-}" session="${5:-}" not_session="${6:-}" login items
  login="$(dp_review_login)"
  [ -n "$login" ] && [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  if [ $# -ge 4 ]; then
    [ -n "$since" ] && [ -n "$session" ] || return 1
  fi
  items="$( { REVIEW_LOGIN="$login" gh api --paginate "repos/$repo/pulls/$pr/reviews" \
                 --jq '.[] | select((.user.login // "") == env.REVIEW_LOGIN)
                       | select(((.state // "") | ascii_upcase) as $st | $st != "DISMISSED" and $st != "PENDING")
                       | {t: (.submitted_at // ""), b: (.body // "")} | tojson' \
               && REVIEW_LOGIN="$login" gh api --paginate "repos/$repo/issues/$pr/comments" \
                 --jq '.[] | select((.user.login // "") == env.REVIEW_LOGIN) | {t: (.created_at // ""), b: (.body // "")} | tojson'; } 2>/dev/null)" || return 1
  printf '%s\n' "$items" | dp_verdict_blocks_clean_for "$head" "$since" "$session" "$not_session" "$([ $# -ge 4 ] && echo bind)"
}

# dp_verdict_blocks_clean_for <head> [not-before] [session] [not-session] [bind]
# -- stdin: one JSON value per line, either a body string or {t, b} (posted-at
# + body). Collects every sge-verdict block for <head>, takes the LATEST (by
# posted-at, then order), and exits 0 iff it is pass / APPROVE / 0 blockers /
# 0 majors -- plus, when <bind> is non-empty, mode: full, posted-at >=
# <not-before>, and session: == <session> (non-empty) and != <not-session>.
dp_verdict_blocks_clean_for() {
  jq -se --arg h "$1" --arg since "${2:-}" --arg ses "${3:-}" --arg notses "${4:-}" --arg bind "${5:-}" '
    [ to_entries[] | .key as $n | .value
      | (if type == "string" then {t: "", b: .} elif type == "object" then . else empty end) as $it
      | select(($it.b | type) == "string")
      | ($it.b | split("\n") | map(sub("\r$"; ""))) as $ls
      | [range(0; $ls | length) | select($ls[.] | test("^```+sge-verdict[[:space:]]*$"))] as $starts
      | $starts[] as $i
      | [ $ls[$i+1:][] ] as $rest
      | ([range(0; $rest | length) | select($rest[.] | test("^```+[[:space:]]*$"))] | first // ($rest | length)) as $end
      | [ $rest[0:$end][] | capture("^(?<k>[a-z_]+):[[:space:]]*(?<v>[^#[:space:]]*)")? | {key: .k, value: .v} ] as $kv
      # A key repeated inside one block (e.g. majors: 2 then majors: 0) makes
      # the block ambiguous: it stays a candidate (so it can still be the
      # LATEST verdict) but can never read as clean (sge#2770 QA).
      | ($kv | from_entries) + {__dup: (($kv | map(.key) | length) != ($kv | map(.key) | unique | length))}
      | select(.commit == $h)
      | {v: ., t: ($it.t // ""), n: $n, i: $i} ]
    | sort_by(.t, .n, .i) | last
    | select(. != null)
    | .t as $t | .v
    | select(.__dup == false)
    | select(.verdict == "pass" and .recommendation == "APPROVE" and .blockers == "0" and .majors == "0")
    | select($bind == ""
             or (.mode == "full" and $t != "" and $since != "" and ($t >= $since)
                 and $ses != "" and .session == $ses and .session != $notses))' >/dev/null 2>&1
}

# dp_hold_release_eligible <owner/repo> <pr> [session] -- print the hold-release order id
# when a `hold` on this PR may be released by policy (a self-fixed security
# MAJOR re-reviewed independently); nothing otherwise. Every check fails
# closed; the reason for a refusal goes to stderr with DP_DEBUG=1.
dp_hold_release_eligible() {
  local repo="$1" pr="$2" session="${3:-$(dp_session_id)}" order view labels body marker marker_session cats paths posted labeled
  _dp_no() { [ "${DP_DEBUG:-0}" = "1" ] && echo "dp_hold_release_eligible: $1" >&2; return 0; }
  order="$(dp_order_for hold-release self-fixed-security-major)"
  [ -n "$order" ] || { _dp_no "no hold-release order in policy"; return 0; }
  # A hold-release order must keep non-empty exclusions (whatever the policy's
  # source -- the daemon validates its file, SGE_DELEGATION_POLICY_FILE is raw).
  # Both must be NON-EMPTY ARRAYS OF STRINGS: a string value passes a bare
  # `length > 0` and then fails open downstream (PR #2752 review M2).
  dp_policy_json | jq -e --arg id "$order" '
    def strlist: type == "array" and length > 0 and all(.[]; type == "string" and . != "");
    [.orders[] | select(.id == $id)][0] | (.exclude_categories | strlist) and (.exclude_paths | strlist)' \
    >/dev/null 2>&1 || { _dp_no "hold-release order exclusions missing/empty/malformed"; return 0; }
  view="$(gh pr view "$pr" --repo "$repo" --json labels,body 2>/dev/null)" || { _dp_no "pr view failed"; return 0; }
  labels="$(printf '%s' "$view" | jq -r '.labels[].name' 2>/dev/null)" || { _dp_no "labels unreadable"; return 0; }
  printf '%s\n' "$labels" | grep -qx 'hold' || { _dp_no "no hold label"; return 0; }
  if printf '%s\n' "$labels" | grep -qE "$DP_HUMAN_ONLY_LABELS_RE"; then _dp_no "human-only label present"; return 0; fi
  body="$(printf '%s' "$view" | jq -r '.body // ""' 2>/dev/null)"
  if printf '%s' "$body" | grep -qiE '(^|[[:space:]]|[!>])HOLD:'; then _dp_no "HOLD: body marker"; return 0; fi
  marker="$(dp_latest_hold_marker "$repo" "$pr")" || marker=""
  [ -n "$marker" ] || { _dp_no "no hold marker (human-applied hold)"; return 0; }
  [ "$(printf '%s' "$marker" | jq -r '.reason // ""')" = "self-fixed-security-major" ] || { _dp_no "marker is not self-fixed-security-major"; return 0; }
  [ -n "$session" ] || { _dp_no "no session id (independence unprovable)"; return 0; }
  # The MARKER's session must be known too: "" != "$session" is not
  # independence (PR #2752 review B2).
  marker_session="$(printf '%s' "$marker" | jq -r '.session | if type == "string" then . else "" end' 2>/dev/null)" || marker_session=""
  [ -n "$marker_session" ] || { _dp_no "marker has no session id (independence unprovable)"; return 0; }
  [ "$marker_session" != "$session" ] || { _dp_no "same session as the fixing review"; return 0; }
  # The marker must belong to the CURRENT hold: posted at/after the latest
  # `labeled: hold` event. A hold re-applied later (by a human) is never
  # released on an older marker.
  posted="$(printf '%s' "$marker" | jq -r '._posted_at // ""')"
  labeled="$(dp_latest_hold_labeled_at "$repo" "$pr")" || labeled=""
  [ -n "$posted" ] && [ -n "$labeled" ] || { _dp_no "hold label event or marker time unreadable"; return 0; }
  # The CURRENT hold must have been applied by the review identity itself: a
  # hold a human (or any other account) applied is never policy-releasable (B1).
  [ "${labeled#* }" = "$(dp_review_login)" ] || { _dp_no "hold applied by '${labeled#* }', not the review identity"; return 0; }
  labeled="${labeled%% *}"
  [[ ! "$posted" < "$labeled" ]] || { _dp_no "marker predates the current hold (re-applied)"; return 0; }
  cats="$(printf '%s' "$marker" | jq -r '(.categories // []) | map(select(type == "string" and . != "")) | join(",")')"
  [ -n "$cats" ] || { _dp_no "marker names no finding categories (exclusions uncheckable)"; return 0; }
  local rc=0
  dp_categories_excluded "$order" "$cats" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || { _dp_no "excluded category (or exclusion check failed, rc=$rc)"; return 0; }
  paths="$(gh api --paginate "repos/$repo/pulls/$pr/files" --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null)" \
    || { _dp_no "changed files unreadable"; return 0; }
  rc=0
  printf '%s\n' "$paths" | dp_paths_excluded "$order" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || { _dp_no "excluded path (or exclusion check failed, rc=$rc)"; return 0; }
  printf '%s\n' "$order"
}
