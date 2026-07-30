#!/usr/bin/env bash
# resolve-scanner-threads.sh — auto-resolve ONLY benign first-party
# skillspector / github-advanced-security code-scanning review threads on a PR,
# so a PR blocked purely by `required_conversation_resolution` on already-
# adjudicated false positives can merge (issue #1067).
#
# This CLOSES the gap left by the fail-closed thread gate in
# skills/pr-review/pr-labels.sh (#652/#717): that gate correctly REFUSES to
# promote while any thread is unresolved, but nothing clears the adjudicated
# benign scanner threads. This script clears ONLY those, and NOTHING else.
#
# HARD security guardrail (non-negotiable). A thread is auto-resolved ONLY if
# ALL of the following hold — otherwise it is left unresolved and printed as a
# `REFUSED: <reason>` line for a human:
#   1. the thread's FIRST comment author login is exactly the code-scanning bot
#      (`github-advanced-security`) — NEVER a human author.
#   2. the thread `path` is a first-party skill file (matches `skills/**`) —
#      NEVER product/app code, migrations, config, or workflows.
#   3. the finding's rule class is one already ACCEPTED for first-party skills
#      in .github/skillspector-waivers.json (the accepted-rule set is derived
#      FROM that file at runtime — never hardcoded, so it cannot drift).
#   4. an audit-rationale PR comment (path:line, rule, why benign) is posted
#      BEFORE the thread is resolved.
#
# Fail-CLOSED, exactly like the #717 gate: an unreadable / failed thread query
# must NEVER be treated as "0 threads". On any enumeration failure the script
# exits NON-ZERO and resolves nothing.
#
# Usage:
#   resolve-scanner-threads.sh --pr <N> [--dry-run]
#     --pr <N>     the pull request number (required)
#     --dry-run    report what WOULD be resolved / refused; mutate nothing
#
# Repo context (SPEC-057): the target repo is taken from $GH_REPO, else from
# `gh repo view` in the current working directory (run from inside a clone of
# the PR's repo, as the other pr-monitor helpers do). The waiver file is read
# from the target repo working tree ($SKILLSPECTOR_WAIVERS overrides).
#
# Output: a final `resolved=<N> refused=<M>` summary plus the refused list.
# Exit 0 when it resolved what it safely could (refused items are for humans);
# exit NON-ZERO only on a fail-closed condition (unreadable thread state).
#
# Run `bash -n` and skills/tests/pr-monitor-resolve-scanner-threads.test.sh
# after any change.
set -euo pipefail

# The ONLY author login whose threads are eligible — the code-scanning bot.
# Overridable for a differently-named first-party scanner bot, but it ALWAYS
# matches exactly one login and NEVER a human. Default is strict.
SCANNER_BOT="${SGD_SCANNER_BOT_LOGIN:-github-advanced-security}"

PR=""
DRY_RUN=false

usage() {
  sed -n '/^# Usage:/,/^# Repo context/{ /^# Repo context/d; p }' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# ---- argument parsing ------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)
      [[ $# -ge 2 ]] || { echo "error: --pr needs a PR number" >&2; exit 2; }
      PR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[[ -n "$PR" ]] || { echo "error: --pr <N> is required" >&2; usage; }
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "error: --pr must be a number, got '$PR'" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "error: jq is required on PATH" >&2; exit 2; }

# jq built for Windows opens stdout in TEXT mode and appends a carriage return
# to every emitted newline, so `jq -r` scalars arrive as e.g. "P1\r",
# "github-advanced-security\r", "THREAD_OK\r". Left in, that \r silently breaks
# every == comparison, the bot-author guardrail, the rule match, AND the thread
# id passed to the resolve mutation. jqr() strips it so the script behaves
# identically on Linux (no \r) and Windows. Use it for EVERY scalar jq -r read.
jqr() { jq -r "$@" | tr -d '\r'; }

# ---- repo context (SPEC-057) ----------------------------------------------
REPO_FULL="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null | tr -d '\r' || true)}"
if [[ -z "$REPO_FULL" ]]; then
  echo "error: cannot determine repo for PR #$PR — set GH_REPO or run from inside a git clone" >&2
  exit 2
fi
OWNER="${REPO_FULL%/*}"; REPO="${REPO_FULL#*/}"

# ---- accepted-rule set, derived FROM the waiver file at runtime ------------
# The set of rule classes already accepted for FIRST-PARTY skills: distinct
# `rule` values on VALID waiver entries (both `reason` and `added_by` present —
# the file's own rule for a live entry) whose reason marks them first-party /
# trusted / sanctioned AND whose path is a skills/** file. Wildcard rules ("*")
# are excluded — an accepted CLASS must be a concrete rule id. Derived, never
# hardcoded, so the guardrail tracks the audited baseline and cannot drift.
locate_waiver_file() {
  if [[ -n "${SKILLSPECTOR_WAIVERS:-}" ]]; then
    printf '%s\n' "$SKILLSPECTOR_WAIVERS"; return
  fi
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r' || true)"
  if [[ -n "$top" && -f "$top/.github/skillspector-waivers.json" ]]; then
    printf '%s\n' "$top/.github/skillspector-waivers.json"; return
  fi
  printf '%s\n' ".github/skillspector-waivers.json"
}
WAIVER_FILE="$(locate_waiver_file)"

ACCEPTED_RULES=""
if [[ -f "$WAIVER_FILE" ]]; then
  # A parse failure yields an EMPTY set (refuse everything) — never a crash and
  # never an over-broad set: safe by construction.
  ACCEPTED_RULES=$(jqr '
      [ (.waivers // [])[]
        | select(((.reason // "") | length) > 0 and ((.added_by // "") | length) > 0)
        | select(((.reason // "") | ascii_downcase) | test("first.?party|trusted|sanctioned"))
        | select(((.path // "") | test("^skills/")))
        | select((.rule // "*") != "*")
        | .rule ]
      | unique | .[]' "$WAIVER_FILE" 2>/dev/null) || ACCEPTED_RULES=""
fi
if [[ -z "$ACCEPTED_RULES" ]]; then
  echo "warning: no accepted first-party rule classes derived from $WAIVER_FILE — every thread will be REFUSED (nothing resolved)" >&2
fi

# Is $1 (a rule id) in the accepted set? Exact whole-token match.
is_accepted_rule() {
  local r="$1" a
  [[ -n "$r" ]] || return 1
  while IFS= read -r a; do
    [[ -n "$a" && "$a" == "$r" ]] && return 0
  done <<< "$ACCEPTED_RULES"
  return 1
}

# Extract the finding's rule class from a scanner comment body by matching an
# ACCEPTED rule id as a standalone token (bounded by non-alphanumerics). We only
# ever recognise a rule that is ALREADY in the accepted set; an unrecognisable
# rule => empty => the thread is REFUSED (fail-safe: unknown rule is never
# resolved). Prints the matched rule id, or nothing.
extract_accepted_rule() {
  local body="$1" a
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    if printf '%s' "$body" | grep -qE "(^|[^A-Za-z0-9])${a}([^A-Za-z0-9]|\$)"; then
      printf '%s\n' "$a"; return 0
    fi
  done <<< "$ACCEPTED_RULES"
  return 1
}

# ---- enumerate ALL unresolved review threads (paginated, fail CLOSED) ------
# Mirrors the #717 gate: every page must fetch and parse cleanly or the whole
# run is refused (non-zero exit). An unverifiable thread state is NEVER read as
# "0 threads" — the entire point of this script is that it can only ever
# resolve threads it has positively and completely read.
THREADS_QUERY='
  query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
    repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
      reviewThreads(first:50, after:$cursor){
        pageInfo{ hasNextPage endCursor }
        nodes{ id isResolved path line
          comments(first:1){ nodes{ body author{ login } } } } } } } }'

UNRESOLVED_JSON='[]'
CURSOR=""
PAGE_NUM=0
MAX_PAGES=40   # 40 × 50 = 2000 threads — fail closed beyond this, never loop forever
while :; do
  PAGE_NUM=$((PAGE_NUM + 1))
  if [[ "$PAGE_NUM" -gt "$MAX_PAGES" ]]; then
    echo "refusing: PR #$PR has more than $((MAX_PAGES * 50)) review threads — fails closed (issue #1067/#717)" >&2
    exit 1
  fi
  PAGE_ARGS=(-f owner="$OWNER" -f repo="$REPO" -F pr="$PR")
  [[ -n "$CURSOR" ]] && PAGE_ARGS+=(-f cursor="$CURSOR")
  if ! PAGE=$(gh api graphql -f query="$THREADS_QUERY" "${PAGE_ARGS[@]}" \
        --jq '.data.repository.pullRequest.reviewThreads'); then
    echo "refusing: could not query review threads for PR #$PR (page $PAGE_NUM) — gh/GraphQL failure" >&2
    echo "Fails CLOSED (issue #1067/#717): an unverifiable thread state never counts as 0 threads; nothing resolved." >&2
    exit 1
  fi
  UNRESOLVED_JSON=$(jq -c --argjson acc "$UNRESOLVED_JSON" \
      '$acc + [.nodes[] | select(.isResolved==false)]' <<<"$PAGE") \
    || { echo "refusing: could not parse review-thread page $PAGE_NUM for PR #$PR — fails closed (issue #1067/#717)" >&2; exit 1; }
  HAS_NEXT=$(jqr '.pageInfo.hasNextPage' <<<"$PAGE") \
    || { echo "refusing: could not read pageInfo for PR #$PR — fails closed (issue #1067/#717)" >&2; exit 1; }
  [[ "$HAS_NEXT" == "true" ]] || break
  CURSOR=$(jqr '.pageInfo.endCursor' <<<"$PAGE")
  if [[ -z "$CURSOR" || "$CURSOR" == "null" ]]; then
    echo "refusing: hasNextPage=true but endCursor missing for PR #$PR — fails closed (issue #1067/#717)" >&2
    exit 1
  fi
done

UNRESOLVED_COUNT=$(jq 'length' <<<"$UNRESOLVED_JSON" | tr -d '\r') \
  || { echo "refusing: could not count unresolved threads for PR #$PR — fails closed (issue #1067/#717)" >&2; exit 1; }

echo "PR #$PR: $UNRESOLVED_COUNT unresolved review thread(s) to adjudicate (repo $REPO_FULL, dry-run=$DRY_RUN)" >&2

# ---- resolve mutation ------------------------------------------------------
RESOLVE_MUTATION='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }'

resolve_thread() {   # <thread-id> -> 0 iff GitHub reports isResolved==true
  local tid="$1" out
  out=$(gh api graphql -f query="$RESOLVE_MUTATION" -f id="$tid" \
        --jq '.data.resolveReviewThread.thread.isResolved' 2>/dev/null | tr -d '\r') || return 1
  [[ "$out" == "true" ]]
}

post_audit_comment() {   # <path> <line> <rule>
  local path="$1" line="$2" rule="$3" loc body
  loc="$path"; [[ -n "$line" && "$line" != "null" ]] && loc="$path:$line"
  body=$(cat <<EOF
🤖 **pr-monitor: auto-resolving a benign first-party code-scanning thread** (issue #1067)

- **location:** \`$loc\`
- **rule:** \`$rule\`
- **why benign:** \`github-advanced-security\` code-scanning finding on a first-party \`skills/**\` file. Rule class \`$rule\` is in the audited accepted-for-first-party set in \`.github/skillspector-waivers.json\` — the same benign class already waived at the SkillSpector gate (SPEC-059). The detector fires on this skill's own documented agent behaviour, not on injected/untrusted content.
- **action:** resolving this review thread to unblock \`required_conversation_resolution\`. Human review threads, non-\`skills/**\` paths, and rules outside the accepted set are left untouched for a human.
EOF
)
  gh pr comment "$PR" --body "$body" >/dev/null 2>&1
}

RESOLVED=0
REFUSED=0
REFUSED_LINES=()

refuse() {   # <thread-id> <path> <reason>
  REFUSED=$((REFUSED + 1))
  REFUSED_LINES+=("REFUSED: thread ${1:0:20}… path=${2:-?} — $3")
  echo "REFUSED: thread ${1:0:20}… path=${2:-?} — $3" >&2
}

# Iterate unresolved threads. jq emits one compact JSON object per line; read
# each and adjudicate it against the HARD guardrail.
while IFS= read -r thread; do
  [[ -n "$thread" ]] || continue
  tid=$(jqr '.id // ""' <<<"$thread")
  tpath=$(jqr '.path // ""' <<<"$thread")
  tline=$(jqr '.line // ""' <<<"$thread")
  author=$(jqr '.comments.nodes[0].author.login // ""' <<<"$thread")
  cbody=$(jqr '.comments.nodes[0].body // ""' <<<"$thread")

  # Guardrail 1 — author MUST be the code-scanning bot, NEVER a human.
  if [[ "$author" != "$SCANNER_BOT" ]]; then
    refuse "$tid" "$tpath" "author '${author:-unknown}' is not the code-scanning bot ($SCANNER_BOT) — never touch human/other threads"
    continue
  fi
  # Guardrail 2 — path MUST be a first-party skills/** file.
  if [[ "$tpath" != skills/* ]]; then
    refuse "$tid" "$tpath" "path is not a first-party skills/** file — never resolve on product/app/config/workflow code"
    continue
  fi
  # Guardrail 3 — rule class MUST be in the accepted first-party set.
  rule=$(extract_accepted_rule "$cbody" || true)
  if [[ -z "$rule" ]] || ! is_accepted_rule "$rule"; then
    refuse "$tid" "$tpath" "finding rule class not in the accepted first-party set (from $WAIVER_FILE) — cannot confirm benign; left for a human"
    continue
  fi

  loc="$tpath"; [[ -n "$tline" && "$tline" != "null" ]] && loc="$tpath:$tline"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "WOULD-RESOLVE: thread ${tid:0:20}… $loc rule=$rule (author=$author)" >&2
    RESOLVED=$((RESOLVED + 1))
    continue
  fi

  # Guardrail 4 — post the audit rationale BEFORE resolving.
  if ! post_audit_comment "$tpath" "$tline" "$rule"; then
    refuse "$tid" "$tpath" "could not post the required audit-rationale comment — refusing to resolve without an audit trail"
    continue
  fi
  if resolve_thread "$tid"; then
    RESOLVED=$((RESOLVED + 1))
    echo "RESOLVED: thread ${tid:0:20}… $loc rule=$rule" >&2
  else
    refuse "$tid" "$tpath" "resolveReviewThread mutation did not confirm isResolved=true — left for a human"
  fi
done < <(jq -c '.[]' <<<"$UNRESOLVED_JSON")

# ---- summary ---------------------------------------------------------------
echo "resolved=$RESOLVED refused=$REFUSED"
if [[ "$REFUSED" -gt 0 ]]; then
  echo "refused threads (left for a human):" >&2
  printf '%s\n' "${REFUSED_LINES[@]}" >&2
fi
# Exit 0: we resolved what we safely could. Refused items are deliberate,
# human-facing outcomes — not errors. Only a fail-closed unreadable thread
# state (handled above) exits non-zero.
exit 0
