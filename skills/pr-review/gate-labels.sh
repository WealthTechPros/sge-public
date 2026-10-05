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
#     when `classify` says `current` AND the verdict SHA is the full 40-hex head
#     from a trusted author other than the PR's own (sge-public#71 review M3),
#     and -- for `pr-reviewed` -- the verdict is a pass (sge#2729 item 6).
#     `stale` and `unproven` (no verdict / malformed SHA / unreadable API,
#     or a non-pass verdict for `pr-reviewed`) read as ABSENT -- fail closed: a label that
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
# same `classify`, verdict extraction and author trust;
# skills/tests/gate-labels-parity.test.sh runs both over the shared fixture
# tables skills/pr-review/gate-labels.fixtures.tsv (classify) and
# skills/pr-review/gate-labels.verdict-fixtures.json (extraction + trust,
# sge#2729) so they cannot drift.
#
# Usage:
#   gate-labels.sh list                              the verdict label set, one per line
#   gate-labels.sh classify <label> <verdict> <head> current|stale|unproven|not-verdict-label
#   gate-labels.sh verdict-sha <pr>                  latest trusted sge-verdict commit (empty if none; exit 3 on API error)
#   gate-labels.sh latest-verdict <pr>               "<sha><TAB><verdict>" of the newest trusted sge-verdict (exit 3 on API error)
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

# The trusted-author filter for sge-verdict blocks -- the REVIEW identity only,
# the same rule as the Python twin's gate_labels.verdict_author_trusted
# (sge#2729 item 4, sge#2808):
#   * REVIEW_DAEMON_TRUSTED_VERDICT_AUTHORS set (comma list): the allow-list is
#     the SOLE authority, exactly as verdict_trust.py treats it (#1444 item 3);
#   * unset: only the wtp-sge App (`wtp-sge[bot]`).
# github-actions[bot] and OWNER/MEMBER/COLLABORATOR association are NOT
# verdict sources (sge#2808): any repo workflow posts as github-actions[bot],
# and qa-audit reports and fix-lane comments post under the operator's own
# account, so either could echo a forged fence.
# Logins compare case-insensitively. Entries are trimmed of ASCII space/tab
# ONLY -- never `\s`, which jq (Oniguruma), gojq (RE2) and Python read
# differently (NBSP) -- the same rule as verdict_trust.trusted_verdict_authors.
# An empty or whitespace-only value (an unset Actions `vars.` expands to "")
# is no allow-list at all, so the wtp-sge[bot] default applies; entries
# compare by exact equality (no globs), so no value widens trust past the
# logins it lists (PR #2800 review).
GL_TRUST_FILTER='(((env.REVIEW_DAEMON_TRUSTED_VERDICT_AUTHORS // "") | ascii_downcase | split(",")
       | map(gsub("^[ \\t]+|[ \\t]+$"; "")) | map(select(. != ""))) as $allow
     | ((.user.login // "") | ascii_downcase) as $login
     | if ($allow | length) > 0 then ($login != "" and ($allow | any(. == $login)))
       else $login == "wtp-sge[bot]"
       end)'
# The marker /sge:pr-review puts on a verdict it posts as an ISSUE COMMENT
# (rl_post_verdict_comment: advisory, draft and hold routes). An issue comment
# is a verdict only when this is its FIRST line, where rl_verdict_mark_body
# writes it -- a marker echoed further down never marks a comment; a formal PR
# review needs no marker (sge#2808, PR #2800 skeptic review). GL_VERDICT_JQ
# spells the same literal; gate_labels.REVIEW_VERDICT_MARKER is its twin.
GL_REVIEW_VERDICT_MARKER='<!-- sge-review-verdict -->'
# GL_COMMENT_MARKER_FILTER: the jq predicate (on one node) that the comment's
# FIRST line is exactly GL_REVIEW_VERDICT_MARKER (trailing space/tab allowed,
# CRLF tolerated). The ONE definition of "this issue comment is a verdict
# node": GL_VERDICT_JQ applies it to comment nodes, and
# .github/scripts/verify-merge-base.sh sources it for its comment anchors, so
# a trusted comment that merely quotes a verdict fence anchors neither
# (sge#2861 review M-B).
GL_COMMENT_MARKER_FILTER='(((.body // "") | split("\n") | map(sub("\r$"; ""))) as $ls
     | (($ls[0] // "") | test("^<!-- sge-review-verdict -->[ \t]*$")))'
# GL_VERDICT_JQ: one "<ts>\t<sha>\t<verdict>" row per trusted verdict node
# ("-" for an empty field) -- the extraction rule shared with
# gate_labels.node_verdict / verdict_block (sge#2729 item 7, sge#2808, PR #2800
# skeptic review; parity-tested over
# skills/pr-review/gate-labels.verdict-fixtures.json):
#   * a PENDING (unsubmitted) review is not a verdict; issue comments carry no
#     .state, so they pass the state filter. A DISMISSED review is a WITHDRAWN
#     verdict: it yields its own SHA with the verdict "dismissed" -- never a
#     pass and never skipped, so dismissing the newest trusted FAIL cannot
#     resurface an older PASS at the same head, while a dismissed verdict at an
#     old head still classifies `stale` (PR #2800 skeptic review, round 2);
#   * GL_NODE_SOURCE=review marks the nodes as formal PR reviews; anything else
#     (unset included -- fail closed) is read as issue comments;
#   * WHICH nodes are verdict nodes: a comment only when its FIRST line is
#     GL_REVIEW_VERDICT_MARKER (where rl_verdict_mark_body writes it; a marker
#     echoed further down never marks a comment); a review only when some line
#     looks like an sge-verdict opener (``` or ~~~, then `sge-verdict` later
#     on the line);
#   * a verdict node that does not parse CLEANLY yields the BLOCKING row
#     "<ts>\t-\tmalformed": no SHA, so it classifies `unproven` and, as the
#     newest verdict, shuts every merge gate. It is never skipped -- skipping
#     would let echoed text erase a newer FAIL and resurface an older PASS;
#   * CLEAN means all of: exactly ONE opener-shaped line in the whole body,
#     and it opens the one TOP-LEVEL sge-verdict fence; fences walked
#     CommonMark-style (docs/schemas/sge-verdict-block.md) -- an opener or
#     closer is indented by 0-3 SPACES (a tab, \f or \v is not fence
#     indentation), a closer is a run of the opener's character at least as
#     long (compared by LENGTH: gojq's RE2 rejects a `{N,}` count above 1000)
#     followed only by spaces/tabs, the info string is `sge-verdict` (ASCII
#     case-insensitive, padded only by spaces/tabs), and a fence inside another
#     fence, an indented code block, an HTML comment or a
#     <pre>/<script>/<style>/<textarea> block is content; the body ends at top
#     level (no fence, HTML comment or raw block left open); only blank lines
#     follow the fence's closer; the fence holds no ``` or ~~~ and at most one
#     `verdict:`, `commit:`, `sha:` and `head:` line each; the node -- comment
#     OR review -- was never edited (no lastEditedAt; for a REST-shaped node
#     also updated_at == created_at: gl_latest_verdict reads both sources
#     through GraphQL, because REST /pulls/N/reviews carries no edit stamp at
#     all and REST updated_at is second-precision -- PR #2800 skeptic review
#     round 2, #2803 item 1); and a CHANGES_REQUESTED review's fence
#     does not say `pass`. Every pattern uses explicit ASCII classes, never
#     `\s` or the "i" flag, so jq (Oniguruma), gojq (RE2) and Python agree;
#   * fields are read ONLY from inside the fence (sge-public#71 review M3); the
#     SHA is the first `commit:`, else `sha:`, else `head:` (the schema's
#     precedence); a clean fence with none yields an empty SHA (`unproven`);
#   * when GL_PR_AUTHOR is set (the merge-gate `current` reader sets it), that
#     login's own verdicts never count: a PR author cannot attest its own head.
# <ts> is submitted_at (reviews) or created_at (comments), so rows from both
# sources sort into one timeline (sge#2729 item 2).
GL_VERDICT_JQ='
    def gl_raw_tag: "([pP][rR][eE]|[sS][cC][rR][iI][pP][tT]|[sS][tT][yY][lL][eE]|[tT][eE][xX][tT][aA][rR][eE][aA])";
    .[] | select(.body != null)
     | select(((.state // "") | ascii_upcase) != "PENDING")
     | select('"$GL_TRUST_FILTER"')
     | select(((env.GL_PR_AUTHOR // "") == "")
              or (((.user.login // "") | ascii_downcase) != (env.GL_PR_AUTHOR | ascii_downcase)))
     | (.submitted_at // .created_at // "") as $ts
     | ((env.GL_NODE_SOURCE // "") != "review") as $isc
     | (.body | split("\n") | map(sub("\r$"; ""))) as $ls
     | ([$ls[] | select(test("(```|~~~).*[sS][gG][eE]-[vV][eE][rR][dD][iI][cC][tT]"))] | length) as $hits
     | select(if $isc then ('"$GL_COMMENT_MARKER_FILTER"') else $hits > 0 end)
     | (((.lastEditedAt // "") != "")
        or ((.created_at // "") != "" and (.updated_at // "") != "" and .created_at != .updated_at)) as $edited
     | (reduce range(0; $ls | length) as $i
          ({mode: "", fc: "", fn: 0, sv: false, starts: [], ends: []};
          $ls[$i] as $l
          | if .mode == "fence" then
              ([$l | capture("^ {0,3}(?<r>`+|~+)[ \t]*$")] | first) as $c
              | (if $c != null and ($c.r[0:1] == .fc) and (($c.r | length) >= .fn) then
                   (if .sv then .ends += [$i] else . end) | .mode = "" | .fc = "" | .fn = 0 | .sv = false
                 else . end)
            elif .mode == "comment" then (if ($l | contains("-->")) then .mode = "" else . end)
            elif .mode == "raw" then
              (if ($l | test("</" + gl_raw_tag + ">")) then .mode = "" else . end)
            else
              ([$l | capture("^ {0,3}(?<f>```+|~~~+)(?<info>.*)$")] | first) as $m
              | if $m != null and (($m.f[0:1] != "`") or ($m.info | test("`") | not)) then
                  .mode = "fence" | .fc = $m.f[0:1] | .fn = ($m.f | length)
                  | .sv = ($m.info | sub("^[ \t]+"; "") | sub("[ \t]+$"; "")
                           | test("^[sS][gG][eE]-[vV][eE][rR][dD][iI][cC][tT]$"))
                  | (if .sv then .starts += [$i] else . end)
                elif ($l | test("^ {0,3}<!--")) then
                  (if ($l | contains("-->")) then . else .mode = "comment" end)
                elif ($l | test("^ {0,3}<" + gl_raw_tag + "([ \t>]|$)")) then
                  (if ($l | test("</" + gl_raw_tag + ">")) then . else .mode = "raw" end)
                else . end
            end)) as $fs
     | (if $fs.mode == "" and $hits == 1 and ($fs.starts | length) == 1 and ($fs.ends | length) == 1
          and ([$ls[$fs.ends[0]+1:][] | select(test("^[ \t]*$") | not)] | length) == 0
        then $ls[$fs.starts[0]+1:$fs.ends[0]] else null end) as $b0
     | (if $b0 != null
          and ([$b0[] | select(test("```|~~~"))] | length) == 0
          and ([("verdict", "commit", "sha", "head") as $k
                | [$b0[] | select(test("^[ \t]*" + $k + "[ \t]*:"))] | length | select(. > 1)] | length) == 0
        then $b0 else null end) as $blk
     | def kv($k): [($blk // [])[] | capture("^[ \t]*" + $k + "[ \t]*:[ \t]*(?<v>[^ \t]*)") | .v] | first // "";
       (kv("commit") | if . == "" then kv("sha") else . end | if . == "" then kv("head") else . end) as $sha
     | (kv("verdict") | ascii_downcase) as $v
     | (if $edited or $blk == null then ["", "malformed"]
        elif ($isc | not) and ((.state // "") | ascii_upcase) == "CHANGES_REQUESTED" and $v == "pass" then ["", "malformed"]
        elif ($isc | not) and ((.state // "") | ascii_upcase) == "DISMISSED" then [$sha, "dismissed"]
        else [$sha, $v] end) as $r
     | [(if $ts == "" then "-" else $ts end), (if $r[0] == "" then "-" else $r[0] end), (if $r[1] == "" then "-" else $r[1] end)]
     | @tsv'

# gl_latest_verdict reads reviews and issue comments through GraphQL, the only
# API that says whether a node was edited (`lastEditedAt`: null until an edit,
# whenever it happens). GL_GQL_REST maps each GraphQL node onto the REST field
# names GL_VERDICT_JQ reads (a Bot author `wtp-sge` becomes `wtp-sge[bot]`, as
# REST names it), so the fixtures and the Python twin keep one node shape. A
# missing PR (`pullRequest: null`) makes `map` error -> exit 3, fail closed.
GL_GQL_REST='def gl_gql_rest: {body, state, submitted_at: .submittedAt, created_at: .createdAt,
      lastEditedAt,
      user: {login: (.author as $a
        | if $a == null then ""
          elif $a.__typename == "Bot" and (($a.login // "") | endswith("[bot]") | not) then ($a.login // "") + "[bot]"
          else ($a.login // "") end)}};'
GL_GQL_REVIEWS='query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) { pullRequest(number: $pr) {
    reviews(first: 100, after: $endCursor) { pageInfo { hasNextPage endCursor }
      nodes { body state submittedAt lastEditedAt author { login __typename } } } } } }'
GL_GQL_COMMENTS='query($owner: String!, $name: String!, $pr: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) { pullRequest(number: $pr) {
    comments(first: 100, after: $endCursor) { pageInfo { hasNextPage endCursor }
      nodes { body createdAt lastEditedAt author { login __typename } } } } } }'

# gl_repo -- owner/name from GH_REPO, else `gh repo view`.
gl_repo() {
  if [[ -n "${GH_REPO:-}" ]]; then
    printf '%s' "$GH_REPO"
  else
    gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null
  fi
}

# gl_latest_verdict <pr> -- "<sha>\t<verdict>" of the NEWEST trusted
# sge-verdict across PR reviews AND issue comments (sge#2729 item 2: a newer
# verdict posted as a comment -- the self-review fallback -- is never hidden by
# an older review). Either field may be empty; prints a lone tab when there is
# no verdict. Returns 3 when the API could not be read (callers must not
# mistake an outage for "no verdict").
gl_latest_verdict() {
  local pr="$1" repo rows more last sha v
  repo=$(gl_repo) || repo=""
  [[ -n "$repo" ]] || return 3
  [[ "$repo" == */* && "$pr" =~ ^[0-9]+$ ]] || return 3
  rows=$(GL_NODE_SOURCE=review gh api graphql --paginate -f owner="${repo%%/*}" -f name="${repo#*/}" -F pr="$pr" \
    -f query="$GL_GQL_REVIEWS" \
    --jq "$GL_GQL_REST .data.repository.pullRequest.reviews.nodes | map(gl_gql_rest) | $GL_VERDICT_JQ" 2>/dev/null) || return 3
  more=$(GL_NODE_SOURCE=comment gh api graphql --paginate -f owner="${repo%%/*}" -f name="${repo#*/}" -F pr="$pr" \
    -f query="$GL_GQL_COMMENTS" \
    --jq "$GL_GQL_REST .data.repository.pullRequest.comments.nodes | map(gl_gql_rest) | $GL_VERDICT_JQ" 2>/dev/null) || return 3
  # Stable sort on the timestamp: equal stamps keep reviews before comments.
  last=$(printf '%s\n%s\n' "$rows" "$more" | tr -d '\r' | grep -v '^[[:space:]]*$' \
    | LC_ALL=C sort -s -t $'\t' -k1,1 | tail -n 1)
  sha=$(printf '%s' "$last" | cut -f2)
  v=$(printf '%s' "$last" | cut -f3)
  [[ "$sha" == "-" ]] && sha=""
  [[ "$v" == "-" ]] && v=""
  printf '%s\t%s' "$sha" "$v"
}

# gl_latest_verdict_sha <pr> -- the commit of the newest trusted sge-verdict
# ("" if none; 3 on API error).
gl_latest_verdict_sha() {
  local out
  out=$(gl_latest_verdict "$1") || return 3
  printf '%s' "${out%%$'\t'*}"
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
    latest-verdict)
      [[ -n "${2:-}" ]] || { echo "usage: gate-labels.sh latest-verdict <pr>" >&2; return 2; }
      gl_latest_verdict "$2" || { echo "gate-labels: could not read verdicts for PR #$2" >&2; return 3; }
      echo
      ;;
    current)
      local pr="${2:-}" label="${3:-}" head="${4:-}" labels verdict outcome latest state author
      [[ -n "$pr" && -n "$label" ]] || { echo "usage: gate-labels.sh current <pr> <label> [<head>]" >&2; return 2; }
      if [[ -z "$head" ]]; then
        head=$(gh pr view "$pr" --json headRefOid --jq .headRefOid 2>/dev/null) || head=""
      fi
      labels=$(gl_current_labels "$pr") || { echo "PR #$pr: $label unreadable (labels API) -- treated as absent" >&2; return 1; }
      if ! printf '%s\n' "$labels" | grep -qxF "$label"; then
        echo "PR #$pr: $label absent"
        return 1
      fi
      # The PR author never attests its own head (sge-public#71 review M3):
      # an unreadable author is unverifiable -- fail closed.
      author=$(gh pr view "$pr" --json author --jq .author.login 2>/dev/null) || author=""
      [[ -n "$author" ]] || { echo "PR #$pr: $label present but the PR author is unreadable -- treated as absent (fail closed)"; return 1; }
      # `gh pr view` names an App author `app/<slug>`; REST comments name it
      # `<slug>[bot]` -- normalise so an App-authored PR is excluded too (sge#2770 review).
      [[ "$author" == app/* ]] && author="${author#app/}[bot]"
      latest=$(GL_PR_AUTHOR="$author" gl_latest_verdict "$pr") || { echo "PR #$pr: $label present but verdicts unreadable -- treated as absent (fail closed)"; return 1; }
      verdict="${latest%%$'\t'*}"
      outcome="${latest#*$'\t'}"
      state=$(gl_classify "$label" "$verdict" "$head")
      # The merge gate needs an EXACT, full 40-hex match (sge-public#71 review
      # M3). gl_classify's >= 7-hex prefix tolerance is for the strip-only
      # writer and the daemon's selection; a short or colliding prefix must
      # never open a merge.
      if [[ "$state" == "current" ]]; then
        local vn hn
        vn=$(gl_norm_sha "$verdict") || vn=""
        hn=$(gl_norm_sha "$head") || hn=""
        [[ ${#vn} -eq 40 && "$vn" == "$hn" ]] || state="unproven"
      fi
      # pr-reviewed asserts a PASS (sge#2729 item 6): a label re-applied by hand
      # over a trusted `verdict: fail` at this head is not current.
      if [[ "$state" == "current" && "$label" == "pr-reviewed" && "$outcome" != "pass" ]]; then
        echo "PR #$pr: $label present but the latest verdict at head is '${outcome:-none}', not a pass -- treated as absent"
        return 1
      fi
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
