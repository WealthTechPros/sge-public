#!/usr/bin/env bash
# azdo-adapter.sh — Azure DevOps backend for the ALM-adapter port (SPEC-110 S1).
#
# S1 scope:
#   - Read verbs: P1 list-dispatchable, P2 view-item, P7 item-dependencies,
#                 P9 dispatch-label-config, P10 search-items.
#   - Repos read (issue #2946, early SPEC-110 S4): list-prs, the active-PR
#     head branches tidy-worktrees needs. Read-only and fail-closed.
#   - Claim core: P3 claim-item, P4 release-item via rev-guarded JSON-Patch.
#   - Security boundary: credential from env, host allow-list before auth,
#     redirect pinning, and read-only-vs-mutating boundary checked first.
#
# Usage:
#   azdo-adapter.sh dispatch-label-config
#   azdo-adapter.sh view-item <work-item-id>
#   azdo-adapter.sh item-dependencies <work-item-id>
#   azdo-adapter.sh search-items <project> <text> [open|closed|all]
#   azdo-adapter.sh list-dispatchable <project> [<dispatch-label>]
#   azdo-adapter.sh claim-item <work-item-id>
#   azdo-adapter.sh release-item <work-item-id>
#   azdo-adapter.sh list-prs <origin-url>
#       Active pull requests of the Azure Repos repo named by <origin-url>, as
#       a JSON array of {"number":N,"headRefName":"<branch>"} (refs/heads/
#       stripped). Paginated by $top/$skip: SGE_AZDO_PR_PAGE_SIZE (default
#       100) x SGE_AZDO_PR_MAX_PAGES (default 10). Exits non-zero on an
#       auth/API error, a malformed payload, or a full last page (possible
#       truncation), so a caller never mistakes a partial list for the set.
#
#   azdo-adapter.sh list-completed-prs <origin-url> <branch>
#       Completed (status=completed) PRs whose source branch is <branch>, as a
#       JSON array of {number, headRefName, headRefOid, closedAt}; headRefOid
#       is lastMergeSourceCommit (issue #3027, tidy-worktrees' squash-merge
#       cross-check). Same pagination/caps as list-prs; exits non-zero on an
#       auth/API error, a malformed page, or a full last page. "[]" means a
#       confirmed zero completed PRs, never an unknown set.
#
#   Boards writes (SPEC-110 S3, issue #2985) — MUTATING, AZDO_ADAPTER_ALLOW_WRITE=1:
#   azdo-adapter.sh comment-item <work-item-id> <body>                       (P5)
#   azdo-adapter.sh create-item <title> [<description>]                      (P6)
#       Also needs AZDO_ADAPTER_ALLOW_CREATE=1 (DP3: excluded from the default
#       scope). Type: SGE_AZDO_WORK_ITEM_TYPE (default Task). Prints the item.
#   azdo-adapter.sh link-close-on-merge <work-item-id> <azure-repos-pr-url>  (P8)
#       Native ArtifactLink from the item to the PR (DR6); ADO closes the item
#       when the PR completes with transitionWorkItems (pr-merge).
#   Text values are JSON-encoded at construction; JSON-Patch PATHS must be on
#   SGE_AZDO_PATCH_PATH_ALLOWLIST (§2.6) or the op is refused with no request.
#   comment-item / create-item / item-comments need SGE_AZDO_PROJECT.
#
#   Azure Repos PR reads (SPEC-110 S4, issue #2985) — gh-shaped output:
#   azdo-adapter.sh repo-id    <origin-url>        org/project/repo (pure, no network)
#   azdo-adapter.sh list-prs   <origin-url> --gh   active PRs as gh `pr list` objects
#   azdo-adapter.sh get-pr     <origin-url> <pr>   one PR as a gh `pr view` object
#   azdo-adapter.sh pr-files   <origin-url> <pr>   changed paths of the latest iteration
#   azdo-adapter.sh pr-diff    <origin-url> <pr>   unified diff base...head (git fetch
#                                                  via the cwd's origin; head-pinned)
#   azdo-adapter.sh pr-commits <origin-url> <pr>   [{oid, committedDate}], oldest first
#   azdo-adapter.sh pr-threads <origin-url> <pr>   unresolved threads, GitHub node shape
#   azdo-adapter.sh pr-ci      <origin-url> <pr>   DP5 CI-green reduction (see _AA_DP5_JQ)
#   azdo-adapter.sh ci-reduce                      DP5 over a JSON object on stdin (pure)
#
#   Azure Repos PR writes — MUTATING, AZDO_ADAPTER_ALLOW_WRITE=1:
#   azdo-adapter.sh pr-add-label|pr-remove-label <origin-url> <pr> <label>
#       PR labels are PR tags; removing an absent tag is not an error.
#   azdo-adapter.sh pr-claim <origin-url> <pr> <reviewing|fixing|work> [--force | --handoff <owner>]
#       Race-safe claim: a generation-numbered git ref created by compare-and-
#       swap (see _aa_pr_claim). Exit 3 = claim lost / already claimed.
#       --handoff <owner>: a live claim recorded for exactly <owner> (the daemon's
#       pre-claim) is taken over as the next generation; any other owner, or a
#       record with no owner field, is exit 3. TRUST MODEL: this is string equality
#       on an owner id that anyone who can read the PR can read, NOT an
#       authenticated binding; the same write credential already has --force. It is
#       therefore AUDITED by exactly one record: the new claim's own metadata thread
#       carries handoffFrom (the previous owner), owner, head and generation, and is
#       written only after the CAS won; if it cannot be posted the takeover is
#       rolled back and the call fails.
#   azdo-adapter.sh pr-claim-heartbeat <origin-url> <pr> <kind>
#       Prove a long review is alive (extends the TTL, capped by
#       SGE_AZDO_CLAIM_MAX_LIFETIME, default 14400s). Exit 7 = claim not held.
#   azdo-adapter.sh pr-comment <origin-url> <pr> <body-file>
#       A plain comment as a CLOSED thread (never an unresolved thread); prints
#       the new thread's numeric id.
#   azdo-adapter.sh pr-comments <origin-url> <pr>                      (read)
#       Every comment as a JSON array in the GitHub issue-comment shape
#       ({id, comment_id, body, user:{login,id}, created_at}).
#   azdo-adapter.sh pr-release-claim <origin-url> <pr> <kind> [--force]
#   azdo-adapter.sh pr-claim-status <origin-url> <pr> <kind>          (read)
#       "claimed=<b> gen=<k> owner=<o> live=<l> mine=<b>"; mine = this agent
#       (SGE_AGENT_ID, else hostname) owns the CURRENT generation.
#   azdo-adapter.sh pr-verdict <origin-url> <pr> <approve|wait|reject> <expected-head> <body-file>
#       Thread + reviewer vote (10 / -5 / -10) bound to the head; exit 6 when
#       the head moved (the vote is reset to 0 if it moved mid-call).
#   azdo-adapter.sh pr-merge <origin-url> <pr> <expected-head>
#       Squash-complete pinned to the head, transitionWorkItems=true (P8).
#   azdo-adapter.sh pr-auto-complete <origin-url> <pr> <expected-head>
#       Arm ADO auto-complete (squash, work items transitioned, policies never
#       bypassed) PINNED to the full 40-hex head judged: exit 6 when the head moved
#       (before the call, or during it, in which case auto-complete is cleared
#       again) or when the target branch lacks a blocking minimum-reviewers policy
#       with resetOnSourcePush=true, creatorVoteCounts=false and
#       blockLastPusherVote=true (ADO would not cancel it on a later push, and the
#       author could approve their own unreviewed head).
#   azdo-adapter.sh pr-auto-complete-clear <origin-url> <pr> <judged-head|none>
#       Clear auto-complete if set and the PR's current head is not the judged one.
#   azdo-adapter.sh create-pr <origin-url> <source> <target> <title> <body-file> [--draft] [<work-item-id>...]
#   azdo-adapter.sh pr-verdict-status <origin-url> <pr>                (read)
#       Newest verdict artefact by the token identity: "<verdict> <sha>" | none.
#   azdo-adapter.sh pr-votes <origin-url> <pr>                         (read)
#       Every reviewer's vote as a JSON array [{id, vote}] (vote 10 / 5 / 0 / -5 /
#       -10), the token identity's own included. A payload without a numeric vote
#       per reviewer is an error, never "no votes".
#   azdo-adapter.sh pr-work-items <origin-url> <pr>                    (read)
#   azdo-adapter.sh item-linked-prs <work-item-id>                     (read)
#
#   Boards comment read (backs issue-read.sh comments, SPEC-128):
#   azdo-adapter.sh item-comments <work-item-id>   all comments, JSON array
#       Paginates and fails closed on a malformed page or the page cap.
# END_USAGE

# SGD_ fallback: remove in SGD rename Phase 6
# shellcheck source=sge-env-compat.sh
. "$(dirname "${BASH_SOURCE[0]}")/sge-env-compat.sh"
sge_env_compat DISPATCH_LABEL JIRA_PROJECT JIRA_BASE_URL JIRA_HOSTS JIRA_BEARER JIRA_EMAIL JIRA_API_TOKEN JIRA_CLAIM_TRANSITION_ID JIRA_RELEASE_TRANSITION_ID JIRA_CLAIM_STATUS JIRA_ISSUETYPE JIRA_CLOSE_TRANSITION_ID
_AA_SELF="${BASH_SOURCE[0]}"
{ set +x; } 2>/dev/null

_aa_err() { printf 'azdo-adapter: error: %s\n' "$*" >&2; }
_aa_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

_aa_json_str() { # <raw> -> JSON string literal
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -Rs .
    return
  fi
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

_aa_urlencode() { # <raw>
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -sRr '@uri'
    return
  fi
  local s="$1" i c out=''
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    case "$c" in
      [A-Za-z0-9.~_-]) out="$out$c" ;;
      *) out="$out$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

_aa_wiql_escape() { # <raw>
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  printf '%s' "$s"
}

_aa_require_work_item_id() {
  case "$1" in
    ''|*[!0-9]*) _aa_err "invalid work-item id '$1' — must be a positive integer"; return 1 ;;
    0) _aa_err "invalid work-item id '$1' — must be a positive integer"; return 1 ;;
  esac
}

_aa_require_project_name() {
  case "$1" in
    ''|*[!A-Za-z0-9._\ -]*) _aa_err "invalid project '$1' — must match [A-Za-z0-9._ -]+"; return 1 ;;
  esac
}

_aa_require_label_name() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) _aa_err "invalid dispatch label '$1' — must match [A-Za-z0-9._-]+"; return 1 ;;
  esac
}

_aa_require_org_slug() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) _aa_err "invalid SGE_AZDO_ORG '$1' — must match [A-Za-z0-9._-]+"; return 1 ;;
  esac
}

_aa_api_base() {
  local org="${SGE_AZDO_ORG:-}" root="${SGE_AZDO_BASE_URL:-https://dev.azure.com}" hostport
  [ -n "$org" ] || { _aa_err "no Azure DevOps org — set SGE_AZDO_ORG"; return 1; }
  _aa_require_org_slug "$org" || return 1
  case "$root" in
    https://*) : ;;
    *) _aa_err "SGE_AZDO_BASE_URL must be https:// (got '$root')"; return 1 ;;
  esac
  hostport="${root#https://}"
  hostport="${hostport%%/*}"
  case "$hostport" in
    ''|*[!A-Za-z0-9.:-]*) _aa_err "SGE_AZDO_BASE_URL host '$hostport' contains invalid characters"; return 1 ;;
  esac
  # A port, when present, is digits only: `dev.azure.com:443.evil.example`
  # would otherwise pass the allow-list on its `dev.azure.com` prefix.
  case "$hostport" in
    *:*:*|*:) _aa_err "SGE_AZDO_BASE_URL host '$hostport' has a malformed port"; return 1 ;;
    *:*) case "${hostport#*:}" in *[!0-9]*) _aa_err "SGE_AZDO_BASE_URL host '$hostport' has a malformed port"; return 1 ;; esac ;;
  esac
  _AA_HOSTPORT="$hostport"
  _AA_API_BASE="https://${hostport}/$org"
}

_aa_default_hosts() {
  printf '%s' 'dev.azure.com;vssps.dev.azure.com;vsrm.dev.azure.com;vstmr.dev.azure.com'
}

_aa_require_allowed_host() {
  local host entry h hosts_raw
  host="$(_aa_lower "${_AA_HOSTPORT%%:*}")"
  hosts_raw="${SGE_AZDO_HOSTS:-$(_aa_default_hosts)}"
  local hosts=()
  IFS=';' read -r -a hosts <<< "$(_aa_lower "$hosts_raw")"
  for entry in "${hosts[@]}"; do
    h="${entry%%:*}"
    [ -n "$h" ] && [ "$host" = "$h" ] && return 0
  done
  _aa_err "refusing authenticated call to host '${_AA_HOSTPORT}' — not in SGE_AZDO_HOSTS allow-list; no credential is attached"
  return 1
}

_aa_credential() {
  local -
  { set +x; } 2>/dev/null
  [ -n "${SGE_AZDO_TOKEN:-}" ] || {
    _aa_err "no Azure DevOps credential — set SGE_AZDO_TOKEN (PAT/Entra token)"
    return 1
  }
  command -v base64 >/dev/null 2>&1 || { _aa_err "base64 not found — required for PAT header assembly"; return 1; }
  local basic
  basic="$(printf ':%s' "${SGE_AZDO_TOKEN}" | base64 | tr -d '\r\n')" || return 1
  printf 'header = "Authorization: Basic %s"\n' "$basic"
}

_aa_require_write() {
  if [ "${AZDO_ADAPTER_ALLOW_WRITE:-}" != "1" ]; then
    _aa_err "refusing mutating op '$1': set AZDO_ADAPTER_ALLOW_WRITE=1 to permit writes (read-only-vs-mutating boundary)"
    return 1
  fi
}

_aa_require_patch_path_allowlisted() { # <path>
  local allow="${SGE_AZDO_PATCH_PATH_ALLOWLIST:-/fields/System.AssignedTo;/fields/System.Tags}" entry
  local paths=()
  IFS=';' read -r -a paths <<< "$allow"
  for entry in "${paths[@]}"; do
    [ "$entry" = "$1" ] && return 0
  done
  _aa_err "patch path '$1' is not allow-listed by SGE_AZDO_PATCH_PATH_ALLOWLIST; refusing with no request"
  return 1
}

_aa_scrub() {
  local -
  { set +x; } 2>/dev/null   # never trace the token or its base64 form
  local txt="$1"
  if [ -n "${SGE_AZDO_TOKEN:-}" ]; then
    txt="${txt//${SGE_AZDO_TOKEN}/******}"
    # The header carries base64(":<token>"); an echoed header value without
    # its "Authorization:" prefix must not survive either.
    local b64
    b64="$(printf ':%s' "$SGE_AZDO_TOKEN" | base64 2>/dev/null | tr -d '\r\n')"
    [ -z "$b64" ] || txt="${txt//${b64}/******}"
  fi
  printf '%s' "$txt" | sed -E 's/[Aa]uthorization:[[:space:]]*[^,;]+/Authorization: ******/g'
}

_aa_mktemp() {
  mktemp "${TMPDIR:-/tmp}/azdo-adapter.XXXXXX" 2>/dev/null \
    || { _aa_err "mktemp failed — cannot buffer REST response body"; return 1; }
}

_aa_api_get() { # <path>
  local -
  { set +x; } 2>/dev/null
  _aa_api_base || return 1
  _aa_require_allowed_host || return 1
  local authcfg
  authcfg="$(_aa_credential)" || return 1
  command -v curl >/dev/null 2>&1 || { _aa_err "curl not found — required for REST calls"; return 1; }
  printf '%s' "$authcfg" | \
    curl -K - -fsS --proto '=https' --proto-redir '=https' --max-redirs 0 \
    -H "Accept: application/json" \
    "${_AA_API_BASE}$1"
}

_aa_api_post_status() { # <path> <json-body> [<body-out-file>]
  local -
  { set +x; } 2>/dev/null
  _aa_api_base || return 1
  _aa_require_allowed_host || return 1
  local authcfg
  authcfg="$(_aa_credential)" || return 1
  command -v curl >/dev/null 2>&1 || { _aa_err "curl not found — required for REST calls"; return 1; }
  printf '%s' "$authcfg" | \
    curl -K - -sS --proto '=https' --proto-redir '=https' --max-redirs 0 -X POST \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    -d "$2" -o "${3:-/dev/null}" -w '%{http_code}' \
    "${_AA_API_BASE}$1"
}

_aa_api_patch_status() { # <path> <json-patch-body> [<body-out-file>]
  local -
  { set +x; } 2>/dev/null
  _aa_api_base || return 1
  _aa_require_allowed_host || return 1
  local authcfg
  authcfg="$(_aa_credential)" || return 1
  command -v curl >/dev/null 2>&1 || { _aa_err "curl not found — required for REST calls"; return 1; }
  printf '%s' "$authcfg" | \
    curl -K - -sS --proto '=https' --proto-redir '=https' --max-redirs 0 -X PATCH \
    -H "Content-Type: application/json-patch+json" -H "Accept: application/json" \
    -d "$2" -o "${3:-/dev/null}" -w '%{http_code}' \
    "${_AA_API_BASE}$1"
}

# Generic authenticated request (SPEC-110 S2-S4). Same boundary as the helpers
# above: base URL + host allow-list checked before the credential is built,
# redirects pinned, token only via `curl -K -` (stdin, never argv). The request
# body goes through a temp FILE (--data-binary @file), never argv, so a large
# review thread cannot hit Windows' command-line limit. Prints the HTTP code.
_aa_api_req() { # <method> <path> <body-file-or-empty> <out-file> <content-type> [<header-dump-file>]
  local -
  { set +x; } 2>/dev/null
  _aa_api_base || return 1
  _aa_require_allowed_host || return 1
  local authcfg
  authcfg="$(_aa_credential)" || return 1
  command -v curl >/dev/null 2>&1 || { _aa_err "curl not found — required for REST calls"; return 1; }
  local dump=(-D "${6:-/dev/null}")   # response headers (Retry-After, DR9)
  if [ -n "$3" ]; then
    printf '%s' "$authcfg" | \
      curl -K - -sS --proto '=https' --proto-redir '=https' --max-redirs 0 -X "$1" -H "Content-Type: $5" -H "Accept: application/json" --data-binary "@$3" "${dump[@]}" -o "$4" -w '%{http_code}' "${_AA_API_BASE}$2"
  else
    printf '%s' "$authcfg" | \
      curl -K - -sS --proto '=https' --proto-redir '=https' --max-redirs 0 -X "$1" -H "Accept: application/json" "${dump[@]}" -o "$4" -w '%{http_code}' "${_AA_API_BASE}$2"
  fi
}

# DR9 (SPEC-110): HTTP 429 honours Retry-After, BOUNDED. At most
# _AA_429_MAX_RETRIES retries per call, each sleeping the server's Retry-After
# (whole seconds, never less than 1) when that is <= _AA_429_SLEEP_CAP; so the
# worst case is 3 x 30s. A missing / non-numeric / over-cap Retry-After, or an
# exhausted budget, fails loud (exit 1) - never a busy-retry, never a silent
# retry past the bound. 429 means the request was rejected unprocessed, so a
# retry is safe for every method.
_AA_429_MAX_RETRIES=3
_AA_429_SLEEP_CAP=30

_aa_retry_after() { # <header-file> -> whole seconds (>=1) on stdout; non-zero when absent/unusable
  local v
  v="$(tr -d '\r' < "$1" 2>/dev/null | awk 'tolower($1)=="retry-after:"{print $2; exit}')"
  [[ "$v" =~ ^[0-9]{1,6}$ ]] || return 1
  v=$((10#$v))
  [ "$v" -ge 1 ] || v=1
  printf '%s' "$v"
}

# _aa_call <op> <method> <path> [<body>] [<content-type>]
# Prints the response body on a 2xx. Otherwise fails loud with a SCRUBBED
# snippet (a 3xx names only the host, never the URL) and returns
#   4 on 404, 5 on 409/412 (a lost compare-and-swap), 1 on anything else.
_aa_call() {
  local op="$1" method="$2" path="$3" body="${4:-}" ctype="${5:-application/json}" tmp bodyf="" hdrf status snip rc retries=0 delay=""
  # Resolve the base here too, so _AA_HOSTPORT is set in THIS shell for the
  # redirect-refusal message (the request itself runs in a subshell).
  _aa_api_base || return 1
  tmp="$(_aa_mktemp)" || return 1
  hdrf="$(_aa_mktemp)" || { rm -f "$tmp"; return 1; }
  if [ -n "$body" ]; then
    bodyf="$(_aa_mktemp)" || { rm -f "$tmp" "$hdrf"; return 1; }
    printf '%s' "$body" > "$bodyf"
  fi
  while :; do
    rc=0
    status="$(_aa_api_req "$method" "$path" "$bodyf" "$tmp" "$ctype" "$hdrf")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      rm -f "$tmp" "$hdrf"; [ -z "$bodyf" ] || rm -f "$bodyf"
      _aa_err "$op: request not completed (transport or boundary error)"
      return 1
    fi
    if [ "$status" = 429 ] && [ "$retries" -lt "$_AA_429_MAX_RETRIES" ] \
       && delay="$(_aa_retry_after "$hdrf")" && [ "$delay" -le "$_AA_429_SLEEP_CAP" ]; then
      retries=$((retries + 1))
      _aa_err "$op: throttled (HTTP 429) - honouring Retry-After: waiting ${delay}s (retry $retries/$_AA_429_MAX_RETRIES)"
      sleep "$delay"
      continue
    fi
    break
  done
  [ -z "$bodyf" ] || rm -f "$bodyf"
  case "$status" in
    2[0-9][0-9]) cat "$tmp"; rm -f "$tmp" "$hdrf"; return 0 ;;
    3[0-9][0-9])
      rm -f "$tmp" "$hdrf"
      _aa_err "$op: refused redirect (HTTP $status) from host '${_AA_HOSTPORT%%:*}' — not followed, no credential re-sent"
      return 1
      ;;
  esac
  snip="$(head -c 300 "$tmp" 2>/dev/null | tr '\n' ' ')"
  if [ "$status" = 429 ]; then
    if [ "$retries" -ge "$_AA_429_MAX_RETRIES" ]; then
      snip="gave up after $retries Retry-After waits (DR9 bound); $snip"
    else
      snip="no usable Retry-After (whole seconds <= ${_AA_429_SLEEP_CAP}s) - not retried (DR9); $snip"
    fi
  fi
  rm -f "$tmp" "$hdrf"
  _aa_err "$op failed (HTTP $status)${snip:+; response: $(_aa_scrub "$snip")}"
  case "$status" in
    404) return 4 ;;
    409|412) return 5 ;;
  esac
  return 1
}

_aa_require_create() {
  if [ "${AZDO_ADAPTER_ALLOW_CREATE:-}" != "1" ]; then
    _aa_err "refusing create-item: set AZDO_ADAPTER_ALLOW_CREATE=1 to permit work-item creation — P6 is EXCLUDED from the default token scope (SPEC-110 DP3)"
    return 1
  fi
}

_aa_project() { # -> validated SGE_AZDO_PROJECT on stdout
  local p="${SGE_AZDO_PROJECT:-}"
  [ -n "$p" ] || { _aa_err "no Azure DevOps project — set SGE_AZDO_PROJECT"; return 1; }
  _aa_require_project_name "$p" || return 1
  printf '%s' "$p"
}

# Default JSON-Patch path allow-list (§2.6): the claim marker fields plus the
# fields P6 writes and the relation P8 appends. SGE_AZDO_PATCH_PATH_ALLOWLIST
# replaces it wholesale — a path missing from the configured list is refused.
_AA_DEFAULT_PATCH_PATHS='/fields/System.AssignedTo;/fields/System.Tags;/fields/System.Title;/fields/System.Description;/relations/-'

# --- P5 comment-item ---------------------------------------------------------
_aa_comment_item() { # <id> <body>
  local project
  _aa_require_work_item_id "$1" || return 1
  project="$(_aa_project)" || return 1
  _aa_call "comment-item" POST \
    "/$(_aa_urlencode "$project")/_apis/wit/workItems/$1/comments?format=markdown&api-version=7.1-preview.4" \
    "{\"text\":$(_aa_json_str "$2")}" >/dev/null
}

# --- P6 create-item (DP3 scope-gated) ----------------------------------------
_aa_create_item() { # <title> [<description>]
  local project type p patch
  project="$(_aa_project)" || return 1
  type="${SGE_AZDO_WORK_ITEM_TYPE:-Task}"
  case "$type" in
    ''|*[!A-Za-z0-9\ ]*) _aa_err "invalid SGE_AZDO_WORK_ITEM_TYPE '$type' — must match [A-Za-z0-9 ]+"; return 1 ;;
  esac
  for p in /fields/System.Title /fields/System.Description; do
    SGE_AZDO_PATCH_PATH_ALLOWLIST="${SGE_AZDO_PATCH_PATH_ALLOWLIST:-$_AA_DEFAULT_PATCH_PATHS}" \
      _aa_require_patch_path_allowlisted "$p" || return 1
  done
  patch="[{\"op\":\"add\",\"path\":\"/fields/System.Title\",\"value\":$(_aa_json_str "$1")},{\"op\":\"add\",\"path\":\"/fields/System.Description\",\"value\":$(_aa_json_str "${2:-}")}]"
  _aa_call "create-item" POST \
    "/$(_aa_urlencode "$project")/_apis/wit/workitems/\$$(_aa_urlencode "$type")?api-version=7.1" \
    "$patch" "application/json-patch+json"
}

# Parse an Azure Repos PR web URL into _AA_U_ORG/_AA_U_PROJECT/_AA_U_REPO/_AA_U_PR.
#   https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<n>
_aa_parse_pr_url() {
  local u="$1" rest segs=()
  case "$u" in https://dev.azure.com/*) ;; *) _aa_err "not an Azure Repos pull-request URL: '$(_aa_redact_origin "$u")'"; return 1 ;; esac
  rest="${u#https://dev.azure.com/}"
  rest="${rest%%[?#]*}"
  IFS='/' read -r -a segs <<< "$rest"
  [ "${#segs[@]}" -eq 6 ] && [ "${segs[2]}" = "_git" ] && [ "$(_aa_lower "${segs[4]}")" = "pullrequest" ] \
    || { _aa_err "expected https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<n>, got '$(_aa_redact_origin "$u")'"; return 1; }
  _AA_U_ORG="${segs[0]}"
  _AA_U_PROJECT="$(_aa_pct_decode "${segs[1]}")" || { _aa_err "unsupported encoding in project"; return 1; }
  _AA_U_REPO="$(_aa_pct_decode "${segs[3]}")" || { _aa_err "unsupported encoding in repo"; return 1; }
  _AA_U_PR="${segs[5]}"
  _aa_require_org_slug "$_AA_U_ORG" || return 1
  _aa_require_project_name "$_AA_U_PROJECT" || return 1
  case "$_AA_U_REPO" in ''|*[!A-Za-z0-9._\ -]*) _aa_err "invalid repo '$_AA_U_REPO'"; return 1 ;; esac
  _aa_require_work_item_id "$_AA_U_PR" || return 1
}

_aa_org_matches() { # <org> — one credential, one org
  # A write (AZDO_ADAPTER_ALLOW_WRITE=1) needs SGE_AZDO_ORG set explicitly: an
  # origin or URL must never choose which org a write with this token lands in.
  if [ "${AZDO_ADAPTER_ALLOW_WRITE:-}" = "1" ] && [ -z "${SGE_AZDO_ORG:-}" ]; then
    _aa_err "set SGE_AZDO_ORG for Azure DevOps writes — refusing to let '$1' (from the origin/URL) pick the org"
    return 1
  fi
  if [ -n "${SGE_AZDO_ORG:-}" ] && [ "$(_aa_lower "$SGE_AZDO_ORG")" != "$(_aa_lower "$1")" ]; then
    _aa_err "SGE_AZDO_ORG '$SGE_AZDO_ORG' does not match org '$1' — refusing"
    return 1
  fi
  SGE_AZDO_ORG="$1"
}

# --- P8 link-close-on-merge --------------------------------------------------
# Native artefact link (DR6): an ArtifactLink relation from the work item to
# the PR. ADO itself closes the item when the PR completes with
# transitionWorkItems (see pr-merge), so nothing here parses `Closes #N`.
_aa_link_close_on_merge() { # <id> <pr-url>
  local pr_json proj_id repo_id repo_name url patch
  _aa_require_work_item_id "$1" || return 1
  _aa_parse_pr_url "$2" || return 1
  _aa_org_matches "$_AA_U_ORG" || return 1
  SGE_AZDO_PATCH_PATH_ALLOWLIST="${SGE_AZDO_PATCH_PATH_ALLOWLIST:-$_AA_DEFAULT_PATCH_PATHS}" \
    _aa_require_patch_path_allowlisted "/relations/-" || return 1
  command -v jq >/dev/null 2>&1 || { _aa_err "jq not found — required for link-close-on-merge"; return 1; }
  pr_json="$(_aa_call "link-close-on-merge (read PR)" GET "/_apis/git/pullrequests/$_AA_U_PR?api-version=7.1")" || return 1
  proj_id="$(printf '%s' "$pr_json" | jq -r '.repository.project.id // empty' | tr -d '\r')"
  repo_id="$(printf '%s' "$pr_json" | jq -r '.repository.id // empty' | tr -d '\r')"
  repo_name="$(printf '%s' "$pr_json" | jq -r '.repository.name // empty' | tr -d '\r')"
  local proj_name
  proj_name="$(printf '%s' "$pr_json" | jq -r '.repository.project.name // empty' | tr -d '\r')"
  [ "$(_aa_lower "$proj_name")" = "$(_aa_lower "$_AA_U_PROJECT")" ] \
    || { _aa_err "link-close-on-merge: PR $_AA_U_PR belongs to project '$proj_name', not '$_AA_U_PROJECT' — refusing"; return 1; }
  case "$proj_id$repo_id" in ''|*[!0-9a-fA-F-]*) _aa_err "link-close-on-merge: PR $_AA_U_PR returned no valid project/repository id"; return 1 ;; esac
  [ "$(_aa_lower "$repo_name")" = "$(_aa_lower "$_AA_U_REPO")" ] \
    || { _aa_err "link-close-on-merge: PR $_AA_U_PR belongs to repo '$repo_name', not '$_AA_U_REPO' — refusing"; return 1; }
  url="vstfs:///Git/PullRequestId/${proj_id}%2F${repo_id}%2F${_AA_U_PR}"
  patch="[{\"op\":\"add\",\"path\":\"/relations/-\",\"value\":{\"rel\":\"ArtifactLink\",\"url\":$(_aa_json_str "$url"),\"attributes\":{\"name\":\"Pull Request\"}}}]"
  _aa_call "link-close-on-merge" PATCH "/_apis/wit/workitems/$1?api-version=7.1" "$patch" "application/json-patch+json" >/dev/null
}

# --- comment read (issue-read.sh comments, SPEC-128) ---------------------------------------
# item-comments: every comment (createdBy identity, createdDate, modifiedDate,
# version, text) as ONE JSON array, following continuationToken. A full page
# at the page cap fails closed (the newest marker could be on a page not read).
_aa_item_comments() { # <id>
  local project route token="" raw page all='[]' n p
  _aa_require_work_item_id "$1" || return 1
  project="$(_aa_project)" || return 1
  command -v jq >/dev/null 2>&1 || { _aa_err "jq not found — required for item-comments"; return 1; }
  route="/$(_aa_urlencode "$project")/_apis/wit/workItems/$1/comments?\$top=200&api-version=7.1-preview.4"
  for (( p=0; p<20; p++ )); do
    raw="$(_aa_call "item-comments" GET "${route}${token:+&continuationToken=$(_aa_urlencode "$token")}")" || return 1
    page="$(printf '%s' "$raw" | jq -c 'if type == "object" and (.comments | type) == "array" then .comments else error("malformed") end' 2>/dev/null)" \
      || { _aa_err "item-comments: malformed comments payload"; return 1; }
    all="$(printf '%s\n%s\n' "$all" "$page" | jq -cs '
      if length == 2 then .[0] + .[1] else error("malformed pagination arrays") end')" || return 1
    token="$(printf '%s' "$raw" | jq -r '.continuationToken // empty' | tr -d '\r')"
    if [ -z "$token" ]; then printf '%s\n' "$all"; return 0; fi
  done
  _aa_err "item-comments: page cap reached — comment set may be truncated; refusing"
  return 1
}

_aa_usage() {
  if [ -n "${1:-}" ]; then _aa_err "$1"; fi
  awk '/^# END_USAGE/{exit} f{sub(/^# ?/,""); print} /^# Usage:/{f=1; sub(/^# ?/,""); print}' "$_AA_SELF" >&2
  exit 2
}

_aa_wiql_query() { # <project> <wiql>
  _aa_api_post_status "/$(_aa_urlencode "$1")/_apis/wit/wiql?api-version=7.1" \
    "{\"query\":$(_aa_json_str "$2")}" "$3"
}

_aa_hydrate_ids() { # <ids-csv>
  _aa_api_get "/_apis/wit/workitems?ids=$1&\$expand=relations&api-version=7.1"
}

_aa_list_or_search() { # <project> <wiql>
  command -v jq >/dev/null 2>&1 || { _aa_err "jq not found — required for WIQL result hydration"; return 1; }
  local tmp status ids
  tmp="$(_aa_mktemp)" || return 1
  trap 'rm -f "$tmp"; trap - INT TERM' INT TERM
  status="$(_aa_wiql_query "$1" "$2" "$tmp")" || { rm -f "$tmp"; trap - INT TERM; return 1; }
  case "$status" in
    2[0-9][0-9]) : ;;
    *)
      local snip
      snip="$(head -c 300 "$tmp" 2>/dev/null | tr '\n' ' ')"
      rm -f "$tmp"; trap - INT TERM
      _aa_err "WIQL query failed (HTTP $status)${snip:+; response: $(_aa_scrub "$snip")}"
      return 1
      ;;
  esac
  ids="$(jq -r '.workItems[]?.id' "$tmp" 2>/dev/null | paste -sd, -)"
  rm -f "$tmp"; trap - INT TERM
  if [ -z "$ids" ]; then
    printf '{"count":0,"value":[]}\n'
    return 0
  fi
  _aa_hydrate_ids "$ids"
}

_aa_claim_or_release() { # <op-name> <id> <claim|release>
  local op="$1" id="$2" mode="$3" field rev_json rev patch status tmp snip claim_value release_mode
  _aa_require_work_item_id "$id" || return 1
  field="${SGE_AZDO_CLAIM_FIELD:-}"
  [ -n "$field" ] || { _aa_err "$op refused: set SGE_AZDO_CLAIM_FIELD (rev-guarded claim marker path)"; return 1; }
  _aa_require_patch_path_allowlisted "$field" || return 1
  rev_json="$(_aa_api_get "/_apis/wit/workitems/$id?api-version=7.1")" || return 1
  command -v jq >/dev/null 2>&1 || { _aa_err "jq not found — required for rev-guarded claim"; return 1; }
  rev="$(printf '%s' "$rev_json" | jq -r '.rev // empty' 2>/dev/null)"
  case "$rev" in ''|*[!0-9]*) _aa_err "$op failed: could not read numeric rev for work item $id"; return 1 ;; esac

  if [ "$mode" = "claim" ]; then
    claim_value="${SGE_AZDO_CLAIM_VALUE:-}"
    [ -n "$claim_value" ] || { _aa_err "claim-item refused: set SGE_AZDO_CLAIM_VALUE (DR5 fail-loud when claim path is not configured)"; return 1; }
    patch="[{\"op\":\"test\",\"path\":\"/rev\",\"value\":$rev},{\"op\":\"add\",\"path\":$(_aa_json_str "$field"),\"value\":$(_aa_json_str "$claim_value")}]"
  else
    release_mode="${SGE_AZDO_RELEASE_MODE:-remove}"
    case "$release_mode" in
      remove) patch="[{\"op\":\"test\",\"path\":\"/rev\",\"value\":$rev},{\"op\":\"remove\",\"path\":$(_aa_json_str "$field")}]"
        ;;
      replace)
        patch="[{\"op\":\"test\",\"path\":\"/rev\",\"value\":$rev},{\"op\":\"replace\",\"path\":$(_aa_json_str "$field"),\"value\":$(_aa_json_str "${SGE_AZDO_RELEASE_VALUE:-}")}]"
        ;;
      *)
        _aa_err "invalid SGE_AZDO_RELEASE_MODE '$release_mode' — use remove|replace"
        return 1
        ;;
    esac
  fi

  tmp="$(_aa_mktemp)" || return 1
  trap 'rm -f "$tmp"; trap - INT TERM' INT TERM
  status="$(_aa_api_patch_status "/_apis/wit/workitems/$id?api-version=7.1" "$patch" "$tmp")" || {
    rm -f "$tmp"; trap - INT TERM; return 1;
  }
  case "$status" in
    2[0-9][0-9]) rm -f "$tmp"; trap - INT TERM; return 0 ;;
    409|412)
      rm -f "$tmp"; trap - INT TERM
      _aa_err "$op lost for '$id' (HTTP $status) — rev-guard rejected; another racer won"
      return 1
      ;;
    *)
      snip="$(head -c 300 "$tmp" 2>/dev/null | tr '\n' ' ')"
      rm -f "$tmp"; trap - INT TERM
      _aa_err "$op failed (HTTP $status)${snip:+; response: $(_aa_scrub "$snip")}"
      return 1
      ;;
  esac
}

# --- Repos read: list-prs (issue #2946) ---------------------------------------
# Parse an Azure Repos origin URL into _AA_R_ORG / _AA_R_PROJECT / _AA_R_REPO.
# Exact host match only (never a substring), mirroring with-repo-cwd.sh's
# `azdo` classification:
#   https://[user@]dev.azure.com/<org>/<project>/_git/<repo>
#   https://[user@]<org>.visualstudio.com/[DefaultCollection/]<project>/_git/<repo>
#   [ssh://]git@ssh.dev.azure.com[:/]v3/<org>/<project>/<repo>
#   [ssh://]<user>@vs-ssh.visualstudio.com[:/]v3/<org>/<project>/<repo>
# The origin only NAMES the repo: the API call always goes to the allow-listed
# SGE_AZDO_BASE_URL (default https://dev.azure.com), never to the origin host.
_aa_pct_decode() { # <segment> -> %20 decoded to a space; any other % refused
  local s="${1//%20/ }"
  case "$s" in *%*) return 1 ;; esac
  printf '%s' "$s"
}

# A caller's git remote can legitimately embed a credential (CI setups commonly
# use https://user:PAT@dev.azure.com/...). _aa_parse_origin's own error
# messages used to echo the raw origin verbatim on any shape mismatch, so a
# malformed-but-credentialed remote leaked the credential to stderr (and from
# there into agent transcripts / CI logs / PR comments). Strip any userinfo
# before the origin is ever quoted in an error.
_aa_strip_userinfo() { # <authority> -> host[:port] with any user[:pass]@ removed
  case "$1" in *@*) printf '%s' "${1##*@}" ;; *) printf '%s' "$1" ;; esac
}

_aa_redact_origin() { # <origin-url> -> same URL with userinfo-before-host removed
  local u="$1" scheme rest
  case "$u" in
    *://*)
      scheme="${u%%://*}://"
      rest="${u#*://}"
      case "$rest" in
        */*) printf '%s%s/%s' "$scheme" "$(_aa_strip_userinfo "${rest%%/*}")" "${rest#*/}" ;;
        *)   printf '%s%s' "$scheme" "$(_aa_strip_userinfo "$rest")" ;;
      esac
      ;;
    *@*:*) printf '%s' "${u#*@}" ;;
    *) printf '%s' "$u" ;;
  esac
}

_aa_parse_origin() { # <origin-url>
  local url="$1" hostpart host path seg org="" project="" repo="" i
  _AA_R_ORG=""; _AA_R_PROJECT=""; _AA_R_REPO=""
  url="${url%/}"
  case "$url" in
    https://*|ssh://*)
      hostpart="${url#*://}"
      case "$hostpart" in */*) ;; *) _aa_err "list-prs: cannot parse origin '$(_aa_redact_origin "$url")'"; return 1 ;; esac
      path="${hostpart#*/}"
      hostpart="${hostpart%%/*}"
      hostpart="${hostpart##*@}"
      ;;
    *://*) _aa_err "list-prs: unsupported origin scheme in '$(_aa_redact_origin "$url")'"; return 1 ;;
    *@*:*)
      hostpart="${url%%:*}"
      hostpart="${hostpart##*@}"
      path="${url#*:}"
      case "$hostpart" in */*) _aa_err "list-prs: cannot parse origin '$(_aa_redact_origin "$url")'"; return 1 ;; esac
      ;;
    *) _aa_err "list-prs: cannot parse origin '$(_aa_redact_origin "$url")'"; return 1 ;;
  esac
  host="$(_aa_lower "${hostpart%%:*}")"
  path="${path%.git}"
  local segs=()
  IFS='/' read -r -a segs <<< "$path"
  for seg in "${segs[@]}"; do
    case "$seg" in ''|.|..) _aa_err "list-prs: empty or dot path segment in origin '$(_aa_redact_origin "$url")'"; return 1 ;; esac
  done
  case "$host" in
    dev.azure.com)
      [ "${#segs[@]}" -eq 4 ] && [ "${segs[2]}" = "_git" ] \
        || { _aa_err "list-prs: expected dev.azure.com/<org>/<project>/_git/<repo>, got '$(_aa_redact_origin "$url")'"; return 1; }
      org="${segs[0]}"; project="${segs[1]}"; repo="${segs[3]}"
      ;;
    ssh.dev.azure.com|vs-ssh.visualstudio.com)
      [ "${#segs[@]}" -eq 4 ] && [ "${segs[0]}" = "v3" ] \
        || { _aa_err "list-prs: expected $host:v3/<org>/<project>/<repo>, got '$(_aa_redact_origin "$url")'"; return 1; }
      org="${segs[1]}"; project="${segs[2]}"; repo="${segs[3]}"
      ;;
    *.visualstudio.com)
      org="${host%.visualstudio.com}"
      case "$org" in *.*) _aa_err "list-prs: unexpected legacy host '$host'"; return 1 ;; esac
      i=0
      if [ "${#segs[@]}" -eq 4 ] && [ "$(_aa_lower "${segs[0]}")" = "defaultcollection" ]; then i=1; fi
      [ "${#segs[@]}" -eq $((i + 3)) ] && [ "${segs[$((i + 1))]}" = "_git" ] \
        || { _aa_err "list-prs: expected <org>.visualstudio.com/<project>/_git/<repo>, got '$(_aa_redact_origin "$url")'"; return 1; }
      project="${segs[$i]}"; repo="${segs[$((i + 2))]}"
      ;;
    *)
      _aa_err "list-prs: origin host '$host' is not an Azure Repos host"
      return 1
      ;;
  esac
  project="$(_aa_pct_decode "$project")" || { _aa_err "list-prs: unsupported encoding in project of '$(_aa_redact_origin "$url")'"; return 1; }
  repo="$(_aa_pct_decode "$repo")" || { _aa_err "list-prs: unsupported encoding in repo of '$(_aa_redact_origin "$url")'"; return 1; }
  _aa_require_org_slug "$org" || return 1
  _aa_require_project_name "$project" || return 1
  case "$repo" in
    ''|*[!A-Za-z0-9._\ -]*) _aa_err "invalid repo '$repo' — must match [A-Za-z0-9._ -]+"; return 1 ;;
  esac
  _AA_R_ORG="$org"; _AA_R_PROJECT="$project"; _AA_R_REPO="$repo"
}

_aa_require_pos_int() { # <name> <value> <max>
  case "$2" in
    ''|*[!0-9]*|0*) _aa_err "$1 must be a positive integer (got '$2')"; return 1 ;;
  esac
  [ "$2" -le "$3" ] || { _aa_err "$1 must be <= $3 (got '$2')"; return 1; }
}

# Normalise + validate ONE page: `.value` must be an array of objects with a
# numeric pullRequestId and a refs/heads/ sourceRefName. Anything else is a
# malformed payload (an HTML sign-in page is ADO's answer to a bad PAT).
_AA_PR_PAGE_JQ='
  if type == "object" and (.value | type) == "array"
     and all(.value[]; type == "object"
             and (.pullRequestId | type) == "number"
             and (.sourceRefName | type) == "string"
             and (.sourceRefName | startswith("refs/heads/"))
             and ((.sourceRefName | length) > 11))
  then [.value[] | {number: .pullRequestId, headRefName: (.sourceRefName | ltrimstr("refs/heads/"))}]
  else error("malformed pull-request page") end'

# gh-shaped PR object (SPEC-110 S4, issue #2985): the field names `gh pr view
# --json` uses, so the host layer can project `--json f1,f2` and apply `--jq`
# exactly as gh does. `$webbase` is the PR web URL without the number.
#   status active/completed/abandoned -> OPEN/MERGED/CLOSED
#   mergeStatus succeeded/conflicts   -> MERGEABLE/CONFLICTING, else UNKNOWN
#   headRefOid = lastMergeSourceCommit (the head the policies evaluated)
_AA_PR_GH_JQ='{
  number: .pullRequestId,
  title: (.title // ""),
  body: (.description // ""),
  state: (if .status == "active" then "OPEN" elif .status == "completed" then "MERGED"
          elif .status == "abandoned" then "CLOSED" else "UNKNOWN" end),
  isDraft: (.isDraft // false),
  headRefName: ((.sourceRefName // "") | ltrimstr("refs/heads/")),
  baseRefName: ((.targetRefName // "") | ltrimstr("refs/heads/")),
  headRefOid: (.lastMergeSourceCommit.commitId // ""),
  baseRefOid: (.lastMergeTargetCommit.commitId // ""),
  mergeable: (if .mergeStatus == "succeeded" then "MERGEABLE" elif .mergeStatus == "conflicts" then "CONFLICTING" else "UNKNOWN" end),
  author: {login: (.createdBy.uniqueName // "")},
  labels: [ .labels[]? | select(.active != false) | {name: .name} ],
  createdAt: (.creationDate // ""),
  closedAt: (.closedDate // null),
  url: ($webbase + (.pullRequestId | tostring))
}'

_AA_PR_GH_PAGE_JQ='
  if type == "object" and (.value | type) == "array"
     and all(.value[]; type == "object" and (.pullRequestId | type) == "number")
  then [.value[] | '"$_AA_PR_GH_JQ"'] else error("malformed pull-request page") end'

_aa_list_prs() { # <origin-url> [gh]
  command -v jq >/dev/null 2>&1 || { _aa_err "jq not found — required for list-prs"; return 1; }
  local _aa_lp_mode="${2:-heads}"
  _aa_parse_origin "$1" || return 1
  if [ -n "${SGE_AZDO_ORG:-}" ]; then
    [ "$(_aa_lower "$SGE_AZDO_ORG")" = "$(_aa_lower "$_AA_R_ORG")" ] || {
      _aa_err "list-prs: SGE_AZDO_ORG '$SGE_AZDO_ORG' does not match the origin's org '$_AA_R_ORG' — refusing"
      return 1
    }
  fi
  SGE_AZDO_ORG="$_AA_R_ORG"
  local size="${SGE_AZDO_PR_PAGE_SIZE:-100}" pages="${SGE_AZDO_PR_MAX_PAGES:-10}"
  _aa_require_pos_int SGE_AZDO_PR_PAGE_SIZE "$size" 1000 || return 1
  _aa_require_pos_int SGE_AZDO_PR_MAX_PAGES "$pages" 100 || return 1
  local route p raw page n all='[]'
  route="/$(_aa_urlencode "$_AA_R_PROJECT")/_apis/git/repositories/$(_aa_urlencode "$_AA_R_REPO")/pullrequests"
  for (( p=0; p<pages; p++ )); do
    raw="$(_aa_api_get "${route}?searchCriteria.status=active&\$top=${size}&\$skip=$((p * size))&api-version=7.1")" \
      || { _aa_err "list-prs: pull-request request failed (auth/API error) — open-PR set unknown"; return 1; }
    if [ "$_aa_lp_mode" = gh ]; then
      page="$(printf '%s' "$raw" | jq -c --arg webbase "$(_aa_pr_webbase)" "$_AA_PR_GH_PAGE_JQ" 2>/dev/null)" \
        || { _aa_err "list-prs: malformed pull-request payload — open-PR set unknown"; return 1; }
    else
    page="$(printf '%s' "$raw" | jq -c "$_AA_PR_PAGE_JQ" 2>/dev/null)" \
      || { _aa_err "list-prs: malformed pull-request payload — open-PR set unknown"; return 1; }
    fi
    n="$(printf '%s' "$page" | jq 'length' | tr -d '\r')" || return 1   # jq.exe on Windows emits CRLF
    all="$(jq -cn --argjson a "$all" --argjson b "$page" '$a + $b')" || return 1
    if [ "$n" -lt "$size" ]; then
      printf '%s\n' "$all"
      return 0
    fi
  done
  _aa_err "list-prs: page cap reached ($pages pages x $size) — the list may be truncated; open-PR set unknown"
  return 1
}

# --- Repos read: list-completed-prs (issue #3027) ----------------------------
# Completed PRs whose source branch is <branch>, with the recorded source head
# (lastMergeSourceCommit) and completion time: the merged-PR lookup behind
# tidy-worktrees' squash-merge cross-check. Read-only (GET on the same
# pullrequests route as list-prs). Only status=completed counts; completion is
# never inferred from mergeability or a merge commit. Fail-closed: auth/API
# error, malformed page (a matching PR with no 40-hex head or no closedDate
# included) and a full last page at the cap are all non-zero, never an empty set.
_AA_PR_COMPLETED_PAGE_JQ='
  if type == "object" and (.value | type) == "array"
     and all(.value[]; type == "object" and (.sourceRefName | type) == "string")
  then [ .value[] | select(.sourceRefName == $ref and .status == "completed") ]
       | if all(.[]; (.pullRequestId | type) == "number"
                     and ((.lastMergeSourceCommit.commitId // "") | test("^[0-9a-f]{40}$"))
                     and ((.closedDate // "") | type == "string" and length > 0))
         then [ .[] | {number: .pullRequestId, headRefName: ($ref | ltrimstr("refs/heads/")),
                       headRefOid: .lastMergeSourceCommit.commitId, closedAt: .closedDate} ]
         else error("malformed completed pull request") end
  else error("malformed pull-request page") end'

_aa_list_completed_prs() { # <origin-url> <branch>
  command -v jq >/dev/null 2>&1 || { _aa_err "jq not found - required for list-completed-prs"; return 1; }
  _aa_require_branch "${2:-}" || return 1
  _aa_parse_origin "$1" || return 1
  if [ -n "${SGE_AZDO_ORG:-}" ]; then
    [ "$(_aa_lower "$SGE_AZDO_ORG")" = "$(_aa_lower "$_AA_R_ORG")" ] || {
      _aa_err "list-completed-prs: SGE_AZDO_ORG '$SGE_AZDO_ORG' does not match the origin's org '$_AA_R_ORG' - refusing"
      return 1
    }
  fi
  SGE_AZDO_ORG="$_AA_R_ORG"
  local size="${SGE_AZDO_PR_PAGE_SIZE:-100}" pages="${SGE_AZDO_PR_MAX_PAGES:-10}"
  _aa_require_pos_int SGE_AZDO_PR_PAGE_SIZE "$size" 1000 || return 1
  _aa_require_pos_int SGE_AZDO_PR_MAX_PAGES "$pages" 100 || return 1
  local ref="refs/heads/$2" route p raw page n total all='[]'
  route="/$(_aa_urlencode "$_AA_R_PROJECT")/_apis/git/repositories/$(_aa_urlencode "$_AA_R_REPO")/pullrequests"
  for (( p=0; p<pages; p++ )); do
    raw="$(_aa_api_get "${route}?searchCriteria.status=completed&searchCriteria.sourceRefName=$(_aa_urlencode "$ref")&\$top=${size}&\$skip=$((p * size))&api-version=7.1")" \
      || { _aa_err "list-completed-prs: pull-request request failed (auth/API error) - completed-PR set unknown"; return 1; }
    page="$(printf '%s' "$raw" | jq -c --arg ref "$ref" "$_AA_PR_COMPLETED_PAGE_JQ" 2>/dev/null)" \
      || { _aa_err "list-completed-prs: malformed pull-request payload - completed-PR set unknown"; return 1; }
    # Page fullness is judged on the RAW page, not the post-filter rows.
    n="$(printf '%s' "$raw" | jq '.value | length' | tr -d '\r')" || return 1
    all="$(jq -cn --argjson a "$all" --argjson b "$page" '$a + $b')" || return 1
    if [ "$n" -lt "$size" ]; then
      printf '%s\n' "$all"
      return 0
    fi
  done
  _aa_err "list-completed-prs: page cap reached ($pages pages x $size) - the list may be truncated; completed-PR set unknown"
  return 1
}

# --- Azure Repos PR surface (SPEC-110 S4, issue #2985) -----------------------
_aa_pr_webbase() {
  printf 'https://dev.azure.com/%s/%s/_git/%s/pullrequest/' \
    "$_AA_R_ORG" "$(_aa_urlencode "$_AA_R_PROJECT")" "$(_aa_urlencode "$_AA_R_REPO")"
}

# Resolve the origin into the project + repository REST routes. The origin only
# names the repo; the call still goes to the allow-listed SGE_AZDO_BASE_URL.
_aa_repo_route() { # <origin-url>
  _aa_parse_origin "$1" || return 1
  _aa_org_matches "$_AA_R_ORG" || return 1
  _AA_PROJ_ROUTE="/$(_aa_urlencode "$_AA_R_PROJECT")"
  _AA_ROUTE="${_AA_PROJ_ROUTE}/_apis/git/repositories/$(_aa_urlencode "$_AA_R_REPO")"
}

_aa_require_pr_id() {
  case "$1" in
    ''|*[!0-9]*|0*) _aa_err "invalid pull-request id '$1' — must be a positive integer"; return 1 ;;
  esac
}

# Raw PR JSON, validated: an HTML sign-in page (ADO's answer to a bad PAT) or a
# different PR id is refused, never normalised into empty fields.
_aa_pr_raw() { # <n> (after _aa_repo_route)
  local raw
  raw="$(_aa_call "get-pr" GET "${_AA_ROUTE}/pullrequests/$1?api-version=7.1")" || return $?
  printf '%s' "$raw" | jq -e --argjson n "$1" 'type == "object" and .pullRequestId == $n' >/dev/null 2>&1 \
    || { _aa_err "get-pr: malformed pull-request payload for PR $1"; return 1; }
  printf '%s' "$raw"
}

_aa_get_pr() { # <origin> <n>
  local raw
  command -v jq >/dev/null 2>&1 || { _aa_err "jq not found — required for get-pr"; return 1; }
  _aa_require_pr_id "$2" || return 1
  _aa_repo_route "$1" || return 1
  raw="$(_aa_pr_raw "$2")" || return 1
  printf '%s' "$raw" | jq -c --arg webbase "$(_aa_pr_webbase)" "$_AA_PR_GH_JQ"
}

# Changed paths of the PR's LATEST iteration (renames contribute both names).
# A paged (nextTop) or capped change list fails closed — never a partial set.
_aa_pr_files() { # <origin> <n>
  local iters last changes
  command -v jq >/dev/null 2>&1 || { _aa_err "jq not found — required for pr-files"; return 1; }
  _aa_require_pr_id "$2" || return 1
  _aa_repo_route "$1" || return 1
  iters="$(_aa_call "pr-files (iterations)" GET "${_AA_ROUTE}/pullRequests/$2/iterations?api-version=7.1")" || return 1
  last="$(printf '%s' "$iters" | jq -r '[.value[]?.id | numbers] | max // empty' 2>/dev/null | tr -d '\r')"
  case "$last" in ''|*[!0-9]*) _aa_err "pr-files: PR $2 has no readable iteration"; return 1 ;; esac
  changes="$(_aa_call "pr-files (changes)" GET "${_AA_ROUTE}/pullRequests/$2/iterations/$last/changes?\$top=2000&api-version=7.1")" || return 1
  printf '%s' "$changes" | jq -r '
    if (.changeEntries | type) != "array" then error("malformed")
    elif ((.nextTop // 0) > 0) or ((.changeEntries | length) >= 2000) then error("truncated")
    else .changeEntries[] | select((.item.isFolder // false) | not)
         | (.originalPath // empty), (.item.path // empty) end' 2>/dev/null \
    | sed 's#^/##' | awk 'NF && !seen[$0]++' \
    || { _aa_err "pr-files: change list for PR $2 is malformed or truncated — refusing a partial set"; return 1; }
}

# Unified diff, the same merge-base semantics as `gh pr diff`. Azure Repos has
# no unified-diff REST surface, so this fetches the PR's source and target
# branches through the checkout's own `origin` (git's credentials, not the
# token) and diffs base...head. The fetched head must equal the PR's
# lastMergeSourceCommit, else the head moved and the diff would be of
# something nobody asked to review: fail closed.
_aa_pr_diff() { # <origin> <n>
  local pr head base src tgt fetched
  pr="$(_aa_get_pr "$1" "$2")" || return 1
  head="$(printf '%s' "$pr" | jq -r '.headRefOid' | tr -d '\r')"
  base="$(printf '%s' "$pr" | jq -r '.baseRefOid' | tr -d '\r')"
  src="$(printf '%s' "$pr" | jq -r '.headRefName' | tr -d '\r')"
  tgt="$(printf '%s' "$pr" | jq -r '.baseRefName' | tr -d '\r')"
  [[ "$head" =~ ^[0-9a-f]{40}$ && "$base" =~ ^[0-9a-f]{40}$ ]] || { _aa_err "pr-diff: PR $2 has no head/base commit"; return 1; }
  git check-ref-format "refs/heads/$src" >/dev/null 2>&1 && git check-ref-format "refs/heads/$tgt" >/dev/null 2>&1 \
    || { _aa_err "pr-diff: PR $2 branch names are not valid refs"; return 1; }
  git fetch -q --no-tags origin "+refs/heads/$src:refs/sge-azdo/pr-$2/head" "+refs/heads/$tgt:refs/sge-azdo/pr-$2/base" 2>/dev/null \
    || { _aa_err "pr-diff: git fetch of PR $2 branches failed"; return 1; }
  fetched="$(git rev-parse "refs/sge-azdo/pr-$2/head" 2>/dev/null)"
  [ "$fetched" = "$head" ] || { _aa_err "pr-diff: PR $2 head moved (branch at ${fetched:-?}, PR at $head) — refusing a diff of an unreviewed head"; return 1; }
  git cat-file -e "$base^{commit}" 2>/dev/null || { _aa_err "pr-diff: base commit $base not available after fetch"; return 1; }
  git diff "$base...$head"
}

_aa_pr_commits() { # <origin> <n> -> [{oid, committedDate}] oldest first (gh order)
  local raw
  _aa_require_pr_id "$2" || return 1
  _aa_repo_route "$1" || return 1
  raw="$(_aa_call "pr-commits" GET "${_AA_ROUTE}/pullRequests/$2/commits?\$top=500&api-version=7.1")" || return 1
  printf '%s' "$raw" | jq -c 'if (.value | type) == "array" and (.value | length) < 500
    then [.value | reverse[] | {oid: .commitId, committedDate: (.committer.date // "")}]
    else error("malformed or truncated") end' 2>/dev/null \
    || { _aa_err "pr-commits: commit list for PR $2 is malformed or truncated"; return 1; }
}

# Unresolved review threads in the GitHub reviewThreads node shape
# (rl_unresolved_threads): status active/pending, not deleted, carrying at
# least one non-system comment. Any read or shape error fails closed.
_aa_pr_threads() { # <origin> <n>
  local raw
  _aa_require_pr_id "$2" || return 1
  _aa_repo_route "$1" || return 1
  raw="$(_aa_call "pr-threads" GET "${_AA_ROUTE}/pullRequests/$2/threads?api-version=7.1")" || return 1
  printf '%s' "$raw" | jq -c 'if (.value | type) != "array" then error("malformed") else
    [ .value[]
      | select((.isDeleted // false) | not)
      | select(((.status // "") | ascii_downcase) as $s | ($s == "active" or $s == "pending"))
      | select(any(.comments[]?; (.commentType // "") != "system"))
      | { id: (.id | tostring), isResolved: false, path: (.threadContext.filePath // null),
          comments: { nodes: [ .comments[]? | select((.isDeleted // false) | not)
                               | { databaseId: .id, body: (.content // ""), author: { login: (.author.uniqueName // "") } } ] } } ] end' 2>/dev/null \
    || { _aa_err "pr-threads: thread payload for PR $2 is malformed — unresolved-thread state unknown"; return 1; }
}

# DP5 — the CI-green reduction (SPEC-110 §2.4, DP5a/b/c). Pure jq over
#   {head, policies: [policy evaluation records], builds: [build records],
#    reviewers: [PR reviewer records]}
# -> {result: green | not-green-failing | not-green-indeterminate, reasons, checks}
#   * any rejected/broken policy, any failed/canceled/partially-succeeded
#     build (in policy or not — DP5b), or a -10/-5 vote (DP5c) -> failing;
#   * a queued/running blocking policy, an unfinished build, a build that ran
#     on another commit, a required reviewer who has not approved, a rejected
#     REVIEWER policy (approvals absent, DP5c), an unknown status, or no
#     positive signal at all -> indeterminate (DR3: never green);
#   * green only with at least one approved policy or succeeded build at head.
# `checks` is the gh `pr checks --json` shape. Its LAST row, `sge/ci-gate`,
# is SUCCESS only when green and FAILURE for BOTH not-green states, so every
# consumer that counts FAILURE rows sees a non-zero count (DP5a, DR8).
# services/review-daemon-poc/azdo_adapter.py mirrors this; both are checked
# against skills/tests/azdo-dp5-vectors.json.
_AA_DP5_JQ='
def lc: (. // "" | tostring | ascii_downcase);
def pname: (.configuration.type.displayName // "policy");
def bname: (.definition.name // "build");
def bsha: ((.triggerInfo["pr.sourceSha"] // .sourceVersion // "") | lc);
def row($n; $s; $d): {name: $n, state: $s, description: $d, link: "", workflow: "azure-pipelines",
  bucket: (if $s == "SUCCESS" then "pass" elif $s == "PENDING" then "pending" elif $s == "SKIPPED" then "skipping" else "fail" end),
  status: (if $s == "PENDING" then "IN_PROGRESS" else "COMPLETED" end),
  conclusion: (if $s == "PENDING" then "" else $s end), detailsUrl: ""};
. as $in
| ($in.head | lc) as $head
| [ $in.policies[]? | select(.configuration.isEnabled != false) ] as $pols
| ( [ $in.builds[]? ] | group_by(.definition.id // .definition.name // "")
    | map(sort_by(.queueTime // "") | last) ) as $builds
| [ ( if ($head | test("^[0-9a-f]{40}$")) then empty
      else {kind: "indeterminate", why: "PR head commit unknown"} end ),
    ( $pols[] | (.status | lc) as $s | (.configuration.isBlocking != false) as $blk
      | if ($s == "rejected" or $s == "broken") then
          ( if (pname | lc | test("reviewer")) then {kind: "indeterminate", why: "policy \"\(pname)\": required approvals absent"}
            else {kind: "failing", why: "policy \"\(pname)\": \($s)"} end )
        elif ($s == "queued" or $s == "running") then
          ( if $blk then {kind: "indeterminate", why: "policy \"\(pname)\": \($s)"} else empty end )
        elif ($s == "approved" or $s == "notapplicable") then empty
        else {kind: "indeterminate", why: "policy \"\(pname)\": unknown status \"\($s)\""} end ),
    ( $builds[] | (.status | lc) as $st | (.result | lc) as $r
      | if $st != "completed" then {kind: "indeterminate", why: "build \"\(bname)\": \($st)"}
        elif ($r == "failed" or $r == "canceled" or $r == "partiallysucceeded") then {kind: "failing", why: "build \"\(bname)\": \($r)"}
        elif $r != "succeeded" then {kind: "indeterminate", why: "build \"\(bname)\": result \"\($r)\""}
        elif (bsha != $head) then {kind: "indeterminate", why: "build \"\(bname)\" ran on \(bsha), not the head"}
        else empty end ),
    ( $in.reviewers[]? | (.vote // 0) as $v | (.displayName // .uniqueName // "reviewer") as $n
      | if $v == -10 then {kind: "failing", why: "reviewer \($n) rejected (-10)"}
        elif $v == -5 then {kind: "failing", why: "reviewer \($n) is waiting for the author (-5)"}
        elif ((.isRequired // false) and $v < 5) then {kind: "indeterminate", why: "required reviewer \($n) has not approved"}
        else empty end )
  ] as $f
| ( [ $pols[] | select((.status | lc) == "approved") ] | length ) as $pp
| ( [ $builds[] | select((.status | lc) == "completed" and (.result | lc) == "succeeded" and bsha == $head) ] | length ) as $pb
| ( if ([ $f[] | select(.kind == "failing") ] | length) > 0 then "not-green-failing"
    elif ($f | length) > 0 then "not-green-indeterminate"
    elif ($pp + $pb) == 0 then "not-green-indeterminate"
    else "green" end ) as $result
| ( [ $f[].why ] + (if ($f | length) == 0 and ($pp + $pb) == 0 then ["no policy evaluation or build signal for this head"] else [] end) ) as $why
| { result: $result, reasons: $why,
    checks: (
      [ $pols[] | (.status | lc) as $s
        | row("policy: \(pname)";
              (if $s == "approved" then "SUCCESS" elif ($s == "queued" or $s == "running") then "PENDING"
               elif $s == "notapplicable" then "SKIPPED" else "FAILURE" end); $s) ]
      + [ $builds[] | (.status | lc) as $st | (.result | lc) as $r
          | row("build: \(bname)";
                (if $st != "completed" then "PENDING" elif $r == "succeeded" then "SUCCESS" else "FAILURE" end);
                (if $st != "completed" then $st else $r end)) ]
      + [ row("sge/ci-gate"; (if $result == "green" then "SUCCESS" else "FAILURE" end);
              ($result + (if ($why | length) > 0 then ": " + ($why | join("; ")) else "" end)))
          + {sgeGate: $result} ] ) }'

_aa_pr_ci() { # <origin> <n> -> the DP5 reduction object
  local raw head proj_id repo_id art pols builds
  command -v jq >/dev/null 2>&1 || { _aa_err "jq not found — required for pr-ci"; return 1; }
  _aa_require_pr_id "$2" || return 1
  _aa_repo_route "$1" || return 1
  raw="$(_aa_pr_raw "$2")" || return 1
  head="$(printf '%s' "$raw" | jq -r '.lastMergeSourceCommit.commitId // ""' | tr -d '\r')"
  proj_id="$(printf '%s' "$raw" | jq -r '.repository.project.id // ""' | tr -d '\r')"
  repo_id="$(printf '%s' "$raw" | jq -r '.repository.id // ""' | tr -d '\r')"
  case "$proj_id" in ''|*[!0-9a-fA-F-]*) _aa_err "pr-ci: PR $2 carries no valid project id"; return 1 ;; esac
  case "$repo_id" in ''|*[!0-9a-fA-F-]*) _aa_err "pr-ci: PR $2 carries no valid repository id"; return 1 ;; esac
  art="vstfs:///CodeReview/CodeReviewId/${proj_id}/$2"
  pols="$(_aa_call "pr-ci (policy evaluations)" GET "${_AA_PROJ_ROUTE}/_apis/policy/evaluations?artifactId=$(_aa_urlencode "$art")&api-version=7.1-preview.1")" || return 1
  builds="$(_aa_call "pr-ci (builds)" GET "${_AA_PROJ_ROUTE}/_apis/build/builds?branchName=$(_aa_urlencode "refs/pull/$2/merge")&repositoryId=$repo_id&repositoryType=TfsGit&queryOrder=queueTimeDescending&\$top=100&api-version=7.1")" || return 1
  # Files, not --argjson: a 100-build page would overflow Windows' argv limit.
  local d rc=0
  d="$(mktemp -d "${TMPDIR:-/tmp}/azdo-ci.XXXXXX")" || { _aa_err "mktemp failed"; return 1; }
  printf '%s' "$raw" > "$d/pr"; printf '%s' "$pols" > "$d/p"; printf '%s' "$builds" > "$d/b"
  jq -n --slurpfile pr "$d/pr" --slurpfile p "$d/p" --slurpfile b "$d/b" \
    '($pr[0]) as $pr | ($p[0]) as $p | ($b[0]) as $b
     | if ($p.value | type) == "array" and ($b.value | type) == "array"
       then {head: ($pr.lastMergeSourceCommit.commitId // ""), policies: $p.value, builds: $b.value, reviewers: ($pr.reviewers // [])}
       else error("malformed") end' 2>/dev/null \
    | jq -c "$_AA_DP5_JQ" 2>/dev/null || rc=1
  rm -rf "$d"
  [ "$rc" -eq 0 ] || { _aa_err "pr-ci: policy/build payload for PR $2 is malformed — CI state unknown"; return 1; }
}

# --- Azure Repos PR writes (SPEC-110 S3/S4, issue #2985) — all MUTATING ------
_aa_require_label() {
  case "$1" in
    ''|-*|*[!A-Za-z0-9._-]*) _aa_err "invalid label '$1' — must match [A-Za-z0-9._-]+ with no leading '-'"; return 1 ;;
  esac
}

# The authenticated identity's id (the token's own user/service id).
_aa_me_id() {
  local raw id
  raw="$(_aa_call "connectionData" GET "/_apis/connectionData")" || return 1
  id="$(printf '%s' "$raw" | jq -r '.authenticatedUser.id // empty' 2>/dev/null | tr -d '\r')"
  [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]     || { _aa_err "could not resolve the token's identity id (not a full GUID)"; return 1; }
  printf '%s' "$id"
}

_aa_pr_add_label() { # <origin> <n> <label>   (PR labels = PR tags)
  _aa_require_pr_id "$2" || return 1
  _aa_require_label "$3" || return 1
  _aa_repo_route "$1" || return 1
  _aa_call "pr-add-label" POST "${_AA_ROUTE}/pullRequests/$2/labels?api-version=7.1-preview.1" \
    "{\"name\":$(_aa_json_str "$3")}" >/dev/null
}

_aa_pr_remove_label() { # <origin> <n> <label> — idempotent: an absent label is fine
  local rc=0
  _aa_require_pr_id "$2" || return 1
  _aa_require_label "$3" || return 1
  _aa_repo_route "$1" || return 1
  _aa_call "pr-remove-label" DELETE "${_AA_ROUTE}/pullRequests/$2/labels/$(_aa_urlencode "$3")?api-version=7.1-preview.1" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0|4) return 0 ;; esac
  _aa_err "pr-remove-label: could not remove '$3' from PR $2"
  return 1
}

# ── Race-safe claim (pr-reviewing / pr-fixing / work) ─────────────────────────
# PR tags have no revision guard, so the claim MUTEX is a git ref created with
# the refs API's compare-and-swap: oldObjectId all-zeros succeeds only if the
# ref does not exist, so two racers resolve to exactly one winner (§2.3). The
# ref is generation-numbered:
#     refs/heads/sge-claims/pr-<n>-<kind>-g<k>
# A metadata thread posted by the winner (status closed, authored by the token
# identity, `<!-- sge-claim: {...} -->`) carries the owner for gen k; the claim's
# age comes from the comment's SERVER publishedDate, never the claimant's clock.
#   * no claim ref         -> race for g1
#   * top gen k is stale   -> race for g(k+1); losers of THAT race lose
#     (its own metadata thread, written by THIS identity, older than
#      SGE_AZDO_CLAIM_TTL seconds, default 1800) or --force
#   * top gen k is live, or has no metadata thread yet -> lost (fail closed:
#     a winner that died before writing metadata is only taken over by --force)
# Two takeover racers both target g(k+1): the CAS picks one. A takeover never
# deletes a live claim's ref, so a slow live owner cannot be stolen from.
_aa_claim_ref_base() { printf 'refs/heads/sge-claims/pr-%s-%s-g' "$1" "$2"; }

_aa_require_claim_kind() {
  case "$1" in reviewing|fixing|work) return 0 ;; esac
  _aa_err "invalid claim kind '$1' — use reviewing|fixing|work"
  return 1
}

_aa_require_gen() { # <n> — a claim generation: 0 (none) or 1-9 digits without a leading zero
  [[ "$1" =~ ^(0|[1-9][0-9]{0,8})$ ]] && return 0
  _aa_err "claim: unreadable claim generation '$1' — refusing"
  return 1
}

_aa_claim_owner() {
  local o="${SGE_AGENT_ID:-$(hostname 2>/dev/null || echo unknown)}"
  case "$o" in ''|*[!A-Za-z0-9._:/@-]*) o="$(printf '%s' "$o" | tr -c 'A-Za-z0-9._:/@-' '_')" ;; esac
  printf '%s' "$o"
}

# -> JSON array [{gen, objectId}] of this PR's claim refs for <kind>, sorted by gen.
_aa_claim_refs() { # <n> <kind>  (after _aa_repo_route)
  local raw base
  base="$(_aa_claim_ref_base "$1" "$2")"
  raw="$(_aa_call "claim (list refs)" GET "${_AA_ROUTE}/refs?filter=$(_aa_urlencode "${base#refs/}")&api-version=7.1")" || return 1
  printf '%s' "$raw" | jq -c --arg base "$base" '
    if (.value | type) != "array" then error("malformed") else
    [ .value[] | select((.name | type) == "string" and (.name | startswith($base)))
      | (.name | ltrimstr($base)) as $g
      | if ($g | test("^[1-9][0-9]{0,8}$")) then {gen: ($g | tonumber), objectId: .objectId}
        else error("malformed generation") end ] | sort_by(.gen) end' 2>/dev/null \
    || { _aa_err "claim: ref listing for PR $1 is malformed (a generation is 1-9 digits, no leading zero) — claim state unknown"; return 1; }
}

# -> JSON array of this identity's claim-metadata markers for <kind>: the claim
# records ("SGE claim: ...") and, marked "hb":true, heartbeat records ("SGE claim
# heartbeat: ...", posted by pr-claim-heartbeat to prove a long review is alive).
_aa_claim_meta() { # <n> <kind> <me-id>  (after _aa_repo_route)
  local raw
  raw="$(_aa_call "claim (threads)" GET "${_AA_ROUTE}/pullRequests/$1/threads?api-version=7.1")" || return 1
  printf '%s' "$raw" | jq -c --arg kind "$2" --arg me "$3" --argjson n "$1" '
    def okrec($m): $m != null and ($m | type) == "object" and $m.kind == $kind and $m.pr == $n and ($m.gen | type) == "number"
                   and $m.gen >= 1 and $m.gen <= 999999999 and ($m.gen | floor) == $m.gen;
    def marker($c; $tag): $c | split($tag) | last | split(" -->")[0] | (try fromjson catch null);
    if (.value | type) != "array" then error("malformed") else
    [ .value[] | .comments[]?
      | select((.author.id // "") == $me)
      | (.content // "") as $c | (.publishedDate // "") as $pub
      | if ($c | startswith("SGE claim: ") and contains("<!-- sge-claim: ")) then
          marker($c; "<!-- sge-claim: ") as $m | select(okrec($m)) | $m + {claimedAt: $pub}
        elif ($c | startswith("SGE claim heartbeat: ") and contains("<!-- sge-claim-heartbeat: ")) then
          marker($c; "<!-- sge-claim-heartbeat: ") as $m | select(okrec($m)) | $m + {claimedAt: $pub, hb: true}
        else empty end ] end' 2>/dev/null \
    || { _aa_err "claim: thread listing for PR $1 is malformed — claim state unknown"; return 1; }
}

# The claim record (not a heartbeat) of generation <g>: its owner / its server
# publish time. Shared jq prefix for the three readers below.
_AA_GEN_REC='[.[] | select(.gen == $g and ((.hb // false) | not))]'

# live|stale|unknown for generation <g> of <meta>. The age runs from the claim
# record's SERVER publish time, extended by this owner's newest heartbeat for the
# same generation, but never past SGE_AZDO_CLAIM_MAX_LIFETIME (default 4h) from
# the claim itself: a heartbeat loop cannot hold the mutex forever. Anything
# unreadable is "unknown" (never stale: the claim cannot be taken over).
_aa_claim_liveness() { # <meta> <g>
  local at ep hep now ttl maxl owner base
  at="$(printf '%s' "$1" | jq -r --argjson g "$2" "$_AA_GEN_REC | last.claimedAt // empty")"
  owner="$(printf '%s' "$1" | jq -r --argjson g "$2" "$_AA_GEN_REC | last.owner // empty")"
  [ -n "$at" ] || { echo unknown; return 0; }
  ep="$(_aa_iso_epoch "$at")"
  [[ "$ep" =~ ^[0-9]+$ ]] || { echo unknown; return 0; }
  ttl="${SGE_AZDO_CLAIM_TTL:-1800}"; maxl="${SGE_AZDO_CLAIM_MAX_LIFETIME:-14400}"
  [[ "$ttl" =~ ^[0-9]+$ && "$maxl" =~ ^[0-9]+$ ]] || { echo unknown; return 0; }
  now="$(date -u +%s)"
  if [ $((now - ep)) -ge "$maxl" ]; then echo stale; return 0; fi
  hep="$(printf '%s' "$1" | jq -r --argjson g "$2" --arg o "$owner" '
    [.[] | select(.gen == $g and .hb == true and (.owner // "") == $o) | .claimedAt
      | (try (sub("\\.[0-9]+"; "") | fromdateiso8601) catch empty)] | max // empty' 2>/dev/null | tr -d '\r')"
  base="$ep"
  [[ "$hep" =~ ^[0-9]+$ ]] && [ "$hep" -gt "$base" ] && base="$hep"
  if [ $((now - base)) -ge "$ttl" ]; then echo stale; else echo live; fi
}

_aa_iso_epoch() { # <iso> -> epoch seconds (fractional seconds dropped)
  jq -rn --arg t "$1" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601' 2>/dev/null
}

_aa_cas_ref() { # <ref> <old> <new> -> 0 won, 5 lost, 1 error
  local raw rc=0
  raw="$(_aa_call "claim (ref CAS)" POST "${_AA_ROUTE}/refs?api-version=7.1" \
    "[{\"name\":$(_aa_json_str "$1"),\"oldObjectId\":\"$2\",\"newObjectId\":\"$3\"}]")" || rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 5 ] && return 5; return 1; }
  if printf '%s' "$raw" | jq -e '(.value | type) == "array" and (.value | length) == 1 and .value[0].success == true' >/dev/null 2>&1; then
    return 0
  fi
  printf '%s' "$raw" | jq -e '(.value | type) == "array" and .value[0].success == false' >/dev/null 2>&1 && return 5
  _aa_err "claim: unrecognised ref-update response — treating as not won"
  return 1
}

_ZERO_SHA='0000000000000000000000000000000000000000'

_aa_pr_claim() { # <origin> <n> <kind> [--force | --handoff <owner>]
  local n="$2" kind="$3" force="${4:-}" handoff="" handoff_from="" raw head me refs top meta live target ref ttl rc owner
  _aa_require_pr_id "$n" || return 1
  _aa_require_claim_kind "$kind" || return 1
  case "$force" in
    ''|--force) ;;
    # Daemon handoff (#2989, the Azure twin of SGE_REVIEW_CLAIM_HANDOFF_OWNER): a
    # LIVE claim whose recorded owner equals <owner> EXACTLY is the dispatcher's
    # own pre-claim and is taken over as the next generation. Any other live
    # owner is still a lost claim (exit 3).
    --handoff)
      handoff="${5:-}"
      [[ "$handoff" =~ ^[A-Za-z0-9._:/@-]+$ ]] || { _aa_err "pr-claim: --handoff needs an owner id ([A-Za-z0-9._:/@-]+)"; return 1; }
      force="" ;;
    *) _aa_err "pr-claim: unknown option '$force'"; return 1 ;;
  esac
  command -v jq >/dev/null 2>&1 || { _aa_err "jq not found — required for pr-claim"; return 1; }
  _aa_repo_route "$1" || return 1
  raw="$(_aa_pr_raw "$n")" || return 1
  # Anchor the ref at the TARGET commit: it always exists in this repository,
  # whereas a fork PR's head commit does not. `head` is recorded as metadata.
  local anchor
  anchor="$(printf '%s' "$raw" | jq -r '.lastMergeTargetCommit.commitId // ""' | tr -d '\r')"
  head="$(printf '%s' "$raw" | jq -r '.lastMergeSourceCommit.commitId // ""' | tr -d '\r')"
  [[ "$anchor" =~ ^[0-9a-f]{40}$ ]] || { _aa_err "pr-claim: PR $n has no target commit to anchor the claim ref"; return 1; }
  me="$(_aa_me_id)" || return 1
  refs="$(_aa_claim_refs "$n" "$kind")" || return 1
  top="$(printf '%s' "$refs" | jq -r 'last.gen // 0')"
  _aa_require_gen "$top" || return 1
  meta="$(_aa_claim_meta "$n" "$kind" "$me")" || return 1
  # A generation is NEVER reused (PR #2986 review): the next one is one past
  # the highest generation seen in a ref OR in any metadata this identity ever
  # wrote, so a stale record from an earlier, released cycle can never be
  # mistaken for the metadata of a live claim with the same number.
  local maxgen
  maxgen="$(printf '%s' "$meta" | jq -r --argjson t "$top" '[$t] + [.[].gen] | max')"
  _aa_require_gen "$maxgen" || return 1
  [ "$maxgen" -lt 999999999 ] || { _aa_err "pr-claim: claim generations for PR $n are exhausted — refusing"; return 1; }
  target=$((maxgen + 1))
  if [ "$top" -gt 0 ]; then
    owner="$(printf '%s' "$meta" | jq -r --argjson g "$top" "$_AA_GEN_REC | last.owner // empty")"
    ttl="${SGE_AZDO_CLAIM_TTL:-1800}"
    case "$ttl" in ''|*[!0-9]*) _aa_err "SGE_AZDO_CLAIM_TTL must be an integer"; return 1 ;; esac
    live="$(_aa_claim_liveness "$meta" "$top")"
    if [ -n "$handoff" ] && [ -z "$owner" ]; then
      _aa_err "pr-claim: PR $n's $kind claim record carries no owner field — handoff refused (fail closed); --force takes it over deliberately"
      return 3
    elif [ -n "$handoff" ] && [ "$owner" = "$handoff" ]; then
      handoff_from="$owner"
      _aa_err "pr-claim: PR $n's live $kind claim is the dispatcher's own pre-claim (owner $owner == handoff owner) — taking it over as gen $target"
    elif [ "$force" != "--force" ] && [ "$live" != "stale" ]; then
      _aa_err "pr-claim: PR $n is already claimed for $kind (gen $top, owner ${owner:-unknown}, ${live}) — claim lost; --force takes it over deliberately"
      return 3
    fi
  fi
  ref="$(_aa_claim_ref_base "$n" "$kind")$target"
  rc=0; _aa_cas_ref "$ref" "$_ZERO_SHA" "$anchor" || rc=$?
  case "$rc" in
    0) : ;;
    5) _aa_err "pr-claim: lost the race for $ref — another agent claimed PR $n first"; return 3 ;;
    *) return 1 ;;
  esac
  local body
  body="$(jq -cn --arg kind "$kind" --argjson gen "$target" --arg owner "$(_aa_claim_owner)" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson n "$n" --arg head "$head" \
    --arg from "$handoff_from" \
    '{kind: $kind, gen: $gen, owner: $owner, claimedAt: $at, pr: $n, head: $head}
     + (if $from == "" then {} else {handoffFrom: $from} end)')"
  # ONE record, 1:1 with the claim standing: a handoff's attribution (previous
  # owner `handoffFrom`, new owner `owner`, head, generation) rides in the claim's
  # single metadata thread, written only AFTER the CAS won. If that thread cannot
  # be posted for a handoff, the claim is rolled back (the ref just taken is
  # released) and the call fails, so "audited" holds and no false record exists.
  if ! _aa_call "claim (metadata thread)" POST "${_AA_ROUTE}/pullRequests/$n/threads?api-version=7.1" \
    "{\"comments\":[{\"parentCommentId\":0,\"commentType\":1,\"content\":$(_aa_json_str "SGE claim: \`$kind\` (gen $target)${handoff_from:+ - handoff from $handoff_from}
<!-- sge-claim: $body -->")}],\"status\":\"closed\"}" >/dev/null; then
    if [ -n "$handoff_from" ]; then
      _aa_cas_ref "$ref" "$anchor" "$_ZERO_SHA" >/dev/null 2>&1 \
        || _aa_err "pr-claim: COULD NOT ROLL BACK $ref after the handoff record failed - release it with --force"
      _aa_err "pr-claim: handoff refused - its record could not be posted ($handoff_from -> $(_aa_claim_owner)); the takeover was rolled back"
      return 1
    fi
    _aa_err "pr-claim: won $ref but could not post its metadata thread — the claim stands; only --force can take it over"
  fi
  # Best-effort: drop superseded generations (CAS on their observed ids).
  printf '%s' "$refs" | jq -r '.[] | "\(.gen) \(.objectId)"' | tr -d '\r' | while read -r g oid; do
    [ "$g" -lt "$target" ] || continue
    _aa_cas_ref "$(_aa_claim_ref_base "$n" "$kind")$g" "$oid" "$_ZERO_SHA" >/dev/null 2>&1 || true
  done
  printf 'claimed %s gen %s\n' "$kind" "$target"
}

_aa_pr_release_claim() { # <origin> <n> <kind> [--force]
  local n="$2" kind="$3" force="${4:-}" refs me meta mine g oid rc=0
  _aa_require_pr_id "$n" || return 1
  _aa_require_claim_kind "$kind" || return 1
  _aa_repo_route "$1" || return 1
  refs="$(_aa_claim_refs "$n" "$kind")" || return 1
  [ "$(printf '%s' "$refs" | jq 'length')" -gt 0 ] || return 0
  me="$(_aa_me_id)" || return 1
  meta="$(_aa_claim_meta "$n" "$kind" "$me")" || return 1
  mine="$(_aa_claim_owner)"
  while read -r g oid; do
    [ -n "$g" ] || continue
    if [ "$force" != "--force" ]; then
      local o; o="$(printf '%s' "$meta" | jq -r --argjson g "$g" "$_AA_GEN_REC | last.owner // empty")"
      [ "$o" = "$mine" ] || continue
    fi
    _aa_cas_ref "$(_aa_claim_ref_base "$n" "$kind")$g" "$oid" "$_ZERO_SHA" >/dev/null || rc=1
  done < <(printf '%s' "$refs" | jq -r '.[] | "\(.gen) \(.objectId)"' | tr -d '\r')
  [ "$rc" -eq 0 ] || _aa_err "pr-release-claim: a claim ref for PR $n could not be released"
  return "$rc"
}

_aa_pr_claim_status() { # <origin> <n> <kind> -> "claimed=<bool> gen=<k> owner=<o> live=<live|stale|unknown>"
  local n="$2" kind="$3" refs top me meta owner live="unknown"
  _aa_require_pr_id "$n" || return 1
  _aa_require_claim_kind "$kind" || return 1
  _aa_repo_route "$1" || return 1
  refs="$(_aa_claim_refs "$n" "$kind")" || return 1
  top="$(printf '%s' "$refs" | jq -r 'last.gen // 0')"
  _aa_require_gen "$top" || return 1
  if [ "$top" -eq 0 ]; then printf 'claimed=false gen=0 owner= live=none mine=false\n'; return 0; fi
  me="$(_aa_me_id)" || return 1
  meta="$(_aa_claim_meta "$n" "$kind" "$me")" || return 1
  owner="$(printf '%s' "$meta" | jq -r --argjson g "$top" "$_AA_GEN_REC | last.owner // empty")"
  live="$(_aa_claim_liveness "$meta" "$top")"
  local mine=false
  [ -n "$owner" ] && [ "$owner" = "$(_aa_claim_owner)" ] && mine=true
  printf 'claimed=true gen=%s owner=%s live=%s mine=%s\n' "$top" "$owner" "$live" "$mine"
}

# Heartbeat (#2989, the Azure twin of the GitHub sge-claim-heartbeat): proves a
# long review still holds its claim, so the TTL does not release the mutex out
# from under active work. Only the CURRENT generation's owner may heartbeat; a
# lost/released/other-owner claim is exit 7 (the "claim not held" contract).
_aa_pr_claim_heartbeat() { # <origin> <n> <kind>
  local n="$2" kind="$3" st body
  _aa_require_pr_id "$n" || return 1
  _aa_require_claim_kind "$kind" || return 1
  _aa_repo_route "$1" || return 1
  st="$(_aa_pr_claim_status "$1" "$n" "$kind")" || return 1
  case " $st " in
    *" claimed=true "*" mine=true "*) : ;;
    *) _aa_err "pr-claim-heartbeat: this agent does not hold PR $n's $kind claim ($st)"; return 7 ;;
  esac
  body="$(jq -cn --arg kind "$kind" --argjson gen "$(printf '%s' "$st" | sed -E 's/.*gen=([0-9]+).*/\1/')" \
    --arg owner "$(_aa_claim_owner)" --argjson n "$n" '{kind: $kind, gen: $gen, owner: $owner, pr: $n}')" || return 1
  _aa_call "claim (heartbeat thread)" POST "${_AA_ROUTE}/pullRequests/$n/threads?api-version=7.1" \
    "{\"comments\":[{\"parentCommentId\":0,\"commentType\":1,\"content\":$(_aa_json_str "SGE claim heartbeat: \`$kind\`
<!-- sge-claim-heartbeat: $body -->")}],\"status\":\"closed\"}" >/dev/null || return 1
  printf 'heartbeat %s\n' "$kind"
}

# A plain comment on a PR as a CLOSED thread (it never counts as an unresolved
# thread). The Azure twin of `gh api .../issues/N/comments`: prints the new
# thread's numeric id (the "comment id" the review lane reports), fail closed on
# a response without one.
_aa_pr_comment() { # <origin> <n> <body-file>
  local out tid
  _aa_require_pr_id "$2" || return 1
  [ -f "$3" ] || { _aa_err "pr-comment: body file '$3' not found"; return 1; }
  [ -s "$3" ] || { _aa_err "pr-comment: empty body"; return 1; }
  # Defence in depth: a plain comment must never impersonate the verdict / claim
  # artefacts read under this same identity.
  if grep -qE '<!-- sge-(verdict-head|claim|claim-heartbeat|claim-handoff):' "$3"; then
    _aa_err "pr-comment: refusing a body that contains a verdict/claim marker"; return 1
  fi
  command -v jq >/dev/null 2>&1 || { _aa_err "jq not found — required for pr-comment"; return 1; }
  _aa_repo_route "$1" || return 1
  out="$(_aa_call "pr-comment" POST "${_AA_ROUTE}/pullRequests/$2/threads?api-version=7.1" \
    "{\"comments\":[{\"parentCommentId\":0,\"commentType\":1,\"content\":$(_aa_json_str "$(cat "$3")")}],\"status\":\"closed\"}")" || return 1
  tid="$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null | tr -d '\r')"
  [[ "$tid" =~ ^[0-9]{1,12}$ ]] || { _aa_err "pr-comment: the thread was posted but the response carried no numeric id"; return 1; }
  printf '%s\n' "$tid"
}

# Every comment on a PR in the shape the GitHub issue-comments API has, so the
# review lane's jq filters read both hosts: [{id (thread id), comment_id, body,
# user:{login,id}, created_at}]. Deleted threads/comments and system comments
# are skipped; a malformed payload is an error, never "no comments".
_aa_pr_comments() { # <origin> <n>
  local raw
  _aa_require_pr_id "$2" || return 1
  command -v jq >/dev/null 2>&1 || { _aa_err "jq not found — required for pr-comments"; return 1; }
  _aa_repo_route "$1" || return 1
  raw="$(_aa_call "pr-comments" GET "${_AA_ROUTE}/pullRequests/$2/threads?api-version=7.1")" || return 1
  printf '%s' "$raw" | jq -c '
    if (.value | type) != "array" then error("malformed") else
    [ .value[] | select((.isDeleted // false) | not) | (.id // 0) as $t | .comments[]?
      | select((.isDeleted // false) | not) | select((.commentType // "text") != "system")
      | {id: $t, comment_id: (.id // 0), body: (.content // ""),
         user: {login: (.author.uniqueName // .author.displayName // ""), id: (.author.id // "")},
         created_at: (.publishedDate // "")} ] end' 2>/dev/null \
    || { _aa_err "pr-comments: thread payload for PR $2 is malformed"; return 1; }
}

# ── Verdicts: vote + thread, bound to the head commit judged ─────────────────
# The PR must be AT <expected-head> before the vote, and still there after it;
# a head that moved in between gets the vote reset to 0 and a non-zero exit, so
# a vote can never stand on commits nobody reviewed. An approve vote by the
# PR's own author identity is refused (review independence).
# Write paths (pr-verdict, pr-merge, pr-auto-complete) bind to a FULL 40-hex
# head: a prefix binds only a few bits and could be ground by a same-prefix
# commit during review (#2989). Prefix matching stays for read/display only
# (sync-check's compare, claim-status output).
_aa_head_matches() { # <actual> <expected-40-hex>
  local a e
  a="$(printf '%s' "$1" | tr 'A-F' 'a-f')"; e="$(printf '%s' "$2" | tr 'A-F' 'a-f')"
  [[ "$e" =~ ^[0-9a-f]{40}$ && "$a" =~ ^[0-9a-f]{40}$ && "$a" == "$e" ]]
}

_aa_require_full_head() { # <op> <expected>
  [[ "$2" =~ ^[0-9a-fA-F]{40}$ ]] && return 0
  _aa_err "$1: the expected head must be the full 40-hex commit id (a prefix is not accepted on a write path)"
  return 1
}

_aa_pr_verdict() { # <origin> <n> <approve|wait|reject> <expected-head> <body-file>
  local n="$2" verdict="$3" exp="$4" bodyf="$5" vote raw head me author text
  _aa_require_pr_id "$n" || return 1
  case "$verdict" in approve) vote=10 ;; wait) vote=-5 ;; reject) vote=-10 ;;
    *) _aa_err "pr-verdict: verdict must be approve|wait|reject"; return 1 ;; esac
  [ -f "$bodyf" ] || { _aa_err "pr-verdict: body file '$bodyf' not found"; return 1; }
  _aa_require_full_head "pr-verdict" "$exp" || return 1
  _aa_repo_route "$1" || return 1
  raw="$(_aa_pr_raw "$n")" || return 1
  head="$(printf '%s' "$raw" | jq -r '.lastMergeSourceCommit.commitId // ""' | tr -d '\r')"
  _aa_head_matches "$head" "$exp" || { _aa_err "pr-verdict: PR $n head moved (judged $exp, now ${head:-unknown}) — re-review the new head"; return 6; }
  me="$(_aa_me_id)" || return 1
  author="$(printf '%s' "$raw" | jq -r '.createdBy.id // ""' | tr -d '\r')"
  if [ "$verdict" = approve ] && [ -n "$author" ] && [ "$author" = "$me" ]; then
    _aa_err "pr-verdict: refusing to approve PR $n as its own author identity (review independence)"
    return 1
  fi
  _aa_call "pr-verdict (vote)" PUT "${_AA_ROUTE}/pullRequests/$n/reviewers/$me?api-version=7.1" \
    "{\"vote\":$vote}" >/dev/null || return 1
  raw="$(_aa_pr_raw "$n")" || { _aa_call "pr-verdict (reset vote)" PUT "${_AA_ROUTE}/pullRequests/$n/reviewers/$me?api-version=7.1" '{"vote":0}' >/dev/null 2>&1; _aa_err "pr-verdict: could not re-read PR $n after voting — vote reset"; return 1; }
  if [ "$(printf '%s' "$raw" | jq -r '.lastMergeSourceCommit.commitId // ""' | tr -d '\r')" != "$head" ]; then
    _aa_call "pr-verdict (reset vote)" PUT "${_AA_ROUTE}/pullRequests/$n/reviewers/$me?api-version=7.1" '{"vote":0}' >/dev/null 2>&1 \
      || _aa_err "pr-verdict: COULD NOT RESET the vote on PR $n after its head moved — reset it by hand"
    _aa_err "pr-verdict: PR $n head moved while voting — vote reset to 0; re-review the new head"
    return 6
  fi
  # The verdict artefact is written LAST, only once the vote stands at the
  # judged head. Its machine marker is the comment's final line, which is how
  # pr-verdict-status (the merge gate) tells it from text quoted in a body.
  text="$(cat "$bodyf")

<!-- sge-verdict-head: $head verdict=$verdict -->"
  if ! _aa_call "pr-verdict (thread)" POST "${_AA_ROUTE}/pullRequests/$n/threads?api-version=7.1" \
      "{\"comments\":[{\"parentCommentId\":0,\"commentType\":1,\"content\":$(_aa_json_str "$text")}],\"status\":\"closed\"}" >/dev/null; then
    _aa_call "pr-verdict (reset vote)" PUT "${_AA_ROUTE}/pullRequests/$n/reviewers/$me?api-version=7.1" '{"vote":0}' >/dev/null 2>&1 \
      || _aa_err "pr-verdict: COULD NOT RESET the vote on PR $n — reset it by hand"
    _aa_err "pr-verdict: the verdict thread could not be posted — vote reset to 0"
    return 1
  fi
  printf 'verdict %s (vote %s) at %s\n' "$verdict" "$vote" "$head"
}

# The newest verdict artefact on a PR: "<approve|wait|reject> <sha>", or
# "none". Only a comment AUTHORED BY THE TOKEN IDENTITY counts, and only when
# the marker is its final line (a marker quoted inside a body does not count).
# This, not the pr-reviewed tag (which anyone with tag-write can set), is what
# the Azure merge gate trusts (PR #2986 review).
_aa_pr_verdict_status() { # <origin> <n>
  local raw me
  _aa_require_pr_id "$2" || return 1
  _aa_repo_route "$1" || return 1
  me="$(_aa_me_id)" || return 1
  raw="$(_aa_call "pr-verdict-status" GET "${_AA_ROUTE}/pullRequests/$2/threads?api-version=7.1")" || return 1
  printf '%s' "$raw" | jq -r --arg me "$me" '
    if (.value | type) != "array" then error("malformed") else
    # Newest by NUMERIC publish time (fractional seconds kept: a string sort puts
    # "...:00Z" after "...:00.5Z"), ties broken by (thread id, comment id). A
    # verdict comment with a missing or unparsable date is malformed -> error.
    def ep: . as $t | ($t | sub("\\.[0-9]+"; "") | fromdateiso8601)
      + ((($t | capture("\\.(?<f>[0-9]+)")? | .f) // "0") | ("0." + .) | tonumber);
    [ .value[] | select((.isDeleted // false) | not) | (.id // 0) as $tid | .comments[]?
      | select((.isDeleted // false) | not)
      | select((.author.id // "") == $me)
      | ((.content // "") | capture("<!-- sge-verdict-head: (?<sha>[0-9a-f]{40}) verdict=(?<v>approve|wait|reject) -->\\s*\\z")?) as $m
      | select($m != null)
      | {k: [((.publishedDate // "") | ep), $tid, (.id // 0)], v: $m.v, sha: $m.sha} ]
    | sort_by(.k) | if length == 0 then "none" else (last | "\(.v) \(.sha)") end end' 2>/dev/null \
    || { _aa_err "pr-verdict-status: thread payload for PR $2 is malformed — verdict unknown"; return 1; }
}

# Every reviewer's vote, human votes included (pr-verdict-status only sees this
# token identity's own verdict artefacts).
_aa_pr_votes() { # <origin> <n>
  local raw
  _aa_require_pr_id "$2" || return 1
  command -v jq >/dev/null 2>&1 || { _aa_err "jq not found - required for pr-votes"; return 1; }
  _aa_repo_route "$1" || return 1
  raw="$(_aa_pr_raw "$2")" || return 1
  printf '%s' "$raw" | jq -c '
    if (.reviewers | type) != "array" or any(.reviewers[]; (type != "object") or ((.vote | type) != "number"))
    then error("malformed") else [ .reviewers[] | {id: (.id // ""), vote: .vote} ] end' 2>/dev/null     || { _aa_err "pr-votes: reviewer payload for PR $2 is malformed - votes unknown"; return 1; }
}

# ── Merge: complete the PR pinned to the head, closing linked work items ─────
_aa_pr_merge() { # <origin> <n> <expected-head>
  local n="$2" raw head out
  _aa_require_pr_id "$n" || return 1
  _aa_require_full_head "pr-merge" "$3" || return 1
  _aa_repo_route "$1" || return 1
  raw="$(_aa_pr_raw "$n")" || return 1
  head="$(printf '%s' "$raw" | jq -r '.lastMergeSourceCommit.commitId // ""' | tr -d '\r')"
  _aa_head_matches "$head" "$3" || { _aa_err "pr-merge: PR $n head moved (checked $3, now ${head:-unknown}) — refusing"; return 6; }
  out="$(_aa_call "pr-merge" PATCH "${_AA_ROUTE}/pullrequests/$n?api-version=7.1" \
    "{\"status\":\"completed\",\"lastMergeSourceCommit\":{\"commitId\":\"$head\"},\"completionOptions\":{\"mergeStrategy\":\"squash\",\"transitionWorkItems\":true,\"deleteSourceBranch\":false,\"bypassPolicy\":false}}")" || return 1
  printf '%s' "$out" | jq -e '.status == "completed"' >/dev/null 2>&1 \
    || { _aa_err "pr-merge: PR $n was not completed (policies or a moved head blocked it)"; return 1; }
  printf 'merged PR %s at %s\n' "$n" "$head"
}

# ── Auto-complete: arm ADO auto-complete, PINNED to the head the review judged ─
# `pass --auto-merge` on Azure Repos (#2989). Auto-complete survives a later push
# to the source branch, so the head is pinned three ways: refused (exit 6) before
# anything is sent when the PR is not AT <expected-head>; the PATCH itself names
# lastMergeSourceCommit; and the PR is re-read afterwards - a head that moved
# mid-call gets auto-complete CLEARED again and exit 6. Squash + transitionWorkItems
# like pr-merge (P8); bypassPolicy is always false, so branch policies still gate.
_AA_NO_IDENTITY='00000000-0000-0000-0000-000000000000'

# ADO does NOT cancel auto-complete when the source branch is pushed again unless
# the target branch has an enabled, blocking "Minimum number of reviewers" policy
# (>= 1 approver) with resetOnSourcePush = true, creatorVoteCounts = false and
# blockLastPusherVote = true. resetOnSourcePush alone is not enough: the author
# could push an unreviewed head and approve their OWN PR. Each field must be
# present and exactly right; absent/unreadable => REFUSED (exit 6).
_AA_REVIEWERS_POLICY_TYPE='fa4e907d-c16b-4a4c-9dfa-4906e5d171dd'

_aa_reset_on_push_policy() { # <repo-id> <target-ref> (after _aa_repo_route)
  local raw
  raw="$(_aa_call "pr-auto-complete (branch policy)" GET \
    "${_AA_PROJ_ROUTE}/_apis/policy/configurations?repositoryId=$1&refName=$(_aa_urlencode "$2")&policyType=${_AA_REVIEWERS_POLICY_TYPE}&api-version=7.1")" || return 1
  printf '%s' "$raw" | jq -e --arg t "$_AA_REVIEWERS_POLICY_TYPE" '
    (.value | type) == "array"
    and any(.value[]; (.isEnabled == true) and (.isBlocking == true) and ((.isDeleted // false) | not)
            and (.type.id == $t) and (.settings.resetOnSourcePush == true)
            and (.settings.creatorVoteCounts == false) and (.settings.blockLastPusherVote == true)
            and ((.settings.minimumApproverCount | type) == "number") and (.settings.minimumApproverCount >= 1))' >/dev/null 2>&1
}

_aa_pr_auto_complete() { # <origin> <n> <expected-head>
  local n="$2" raw head me out repo_id tref
  _aa_require_pr_id "$n" || return 1
  _aa_require_full_head "pr-auto-complete" "$3" || return 1
  _aa_repo_route "$1" || return 1
  raw="$(_aa_pr_raw "$n")" || return 1
  head="$(printf '%s' "$raw" | jq -r '.lastMergeSourceCommit.commitId // ""' | tr -d '\r')"
  _aa_head_matches "$head" "$3" || { _aa_err "pr-auto-complete: PR $n head moved (judged $3, now ${head:-unknown}) — refusing"; return 6; }
  [ "$(printf '%s' "$raw" | jq -r '.status // ""')" = active ] || { _aa_err "pr-auto-complete: PR $n is not active"; return 1; }
  repo_id="$(printf '%s' "$raw" | jq -r '.repository.id // ""' | tr -d '\r')"
  tref="$(printf '%s' "$raw" | jq -r '.targetRefName // ""' | tr -d '\r')"
  [[ "$repo_id" =~ ^[0-9a-fA-F-]+$ && "$tref" == refs/heads/* ]] \
    || { _aa_err "pr-auto-complete: PR $n carries no valid repository id / target branch — refusing"; return 1; }
  _aa_reset_on_push_policy "$repo_id" "$tref" \
    || { _aa_err "pr-auto-complete: cannot confirm a blocking minimum-reviewers policy with resetOnSourcePush, creatorVoteCounts=false and blockLastPusherVote on $tref (missing, off or unreadable) — a later push would not cancel auto-complete; refusing to arm"; return 6; }
  me="$(_aa_me_id)" || return 1
  out="$(_aa_call "pr-auto-complete" PATCH "${_AA_ROUTE}/pullrequests/$n?api-version=7.1" \
    "{\"autoCompleteSetBy\":{\"id\":\"$me\"},\"lastMergeSourceCommit\":{\"commitId\":\"$head\"},\"completionOptions\":{\"mergeStrategy\":\"squash\",\"transitionWorkItems\":true,\"deleteSourceBranch\":false,\"bypassPolicy\":false}}")" || return 1
  printf '%s' "$out" | jq -e --arg me "$me" '.autoCompleteSetBy.id == $me' >/dev/null 2>&1 \
    || { _aa_err "pr-auto-complete: PR $n was not set to auto-complete (the response does not confirm it)"; return 1; }
  raw="$(_aa_pr_raw "$n")" || raw=""
  if [ "$(printf '%s' "$raw" | jq -r '.lastMergeSourceCommit.commitId // ""' 2>/dev/null | tr -d '\r')" != "$head" ]; then
    _aa_call "pr-auto-complete (clear)" PATCH "${_AA_ROUTE}/pullrequests/$n?api-version=7.1" \
      "{\"autoCompleteSetBy\":{\"id\":\"$_AA_NO_IDENTITY\"}}" >/dev/null 2>&1 \
      || _aa_err "pr-auto-complete: COULD NOT CLEAR auto-complete on PR $n after its head moved — clear it by hand"
    _aa_err "pr-auto-complete: PR $n head moved (or became unreadable) while arming — auto-complete cleared; re-review the new head"
    return 6
  fi
  printf 'auto-complete armed for PR %s at %s\n' "$n" "$head"
}

# Clear auto-complete when the PR's CURRENT head is not the head the review
# judged ("none" = no usable verdict: always clear). Used by sync-check / stale
# after a push. Nothing set -> nothing to do (exit 0). Fail closed: a PR that
# cannot be read, or a clear that fails, is exit 1.
_aa_pr_auto_complete_clear() { # <origin> <n> <judged-head|none>
  local n="$2" raw head set
  _aa_require_pr_id "$n" || return 1
  [[ "$3" == none || "$3" =~ ^[0-9a-fA-F]{40}$ ]] || { _aa_err "pr-auto-complete-clear: judged head must be 40-hex or 'none'"; return 1; }
  _aa_repo_route "$1" || return 1
  raw="$(_aa_pr_raw "$n")" || return 1
  set="$(printf '%s' "$raw" | jq -r '.autoCompleteSetBy.id // ""' | tr -d '\r')"
  [ -n "$set" ] && [ "$set" != "$_AA_NO_IDENTITY" ] || return 0
  head="$(printf '%s' "$raw" | jq -r '.lastMergeSourceCommit.commitId // ""' | tr -d '\r')"
  if [ "$3" != none ] && _aa_head_matches "$head" "$3"; then return 0; fi
  _aa_call "pr-auto-complete-clear" PATCH "${_AA_ROUTE}/pullrequests/$n?api-version=7.1" \
    "{\"autoCompleteSetBy\":{\"id\":\"$_AA_NO_IDENTITY\"}}" >/dev/null || return 1
  printf 'auto-complete cleared on PR %s (head %s, judged %s)\n' "$n" "${head:-unknown}" "$3"
}

_aa_pr_work_items() { # <origin> <n> -> one linked work-item id per line
  local raw
  _aa_require_pr_id "$2" || return 1
  _aa_repo_route "$1" || return 1
  raw="$(_aa_call "pr-work-items" GET "${_AA_ROUTE}/pullRequests/$2/workitems?api-version=7.1")" || return 1
  printf '%s' "$raw" | jq -r 'if (.value | type) == "array" then .value[].id else error("malformed") end' 2>/dev/null | tr -d '\r' \
    || { _aa_err "pr-work-items: malformed payload for PR $2"; return 1; }
}

_aa_require_branch() {
  case "$1" in
    ''|-*|*..*|*//*|/*|*/|*.lock|*[!A-Za-z0-9._/-]*) _aa_err "invalid branch name '$1'"; return 1 ;;
  esac
}

_aa_create_pr() { # <origin> <source> <target> <title> <body-file> [--draft] [<work-item-id>...]
  local origin="$1" src="$2" tgt="$3" title="$4" bodyf="$5" draft=false ids='[]' a raw
  shift 5
  _aa_require_branch "$src" || return 1
  _aa_require_branch "$tgt" || return 1
  [ -n "$title" ] || { _aa_err "create-pr: empty title"; return 1; }
  [ -f "$bodyf" ] || { _aa_err "create-pr: body file '$bodyf' not found"; return 1; }
  for a in "$@"; do
    case "$a" in
      --draft) draft=true ;;
      *) _aa_require_work_item_id "$a" || return 1; ids="$(jq -cn --argjson a "$ids" --arg i "$a" '$a + [{id: $i}]')" ;;
    esac
  done
  _aa_repo_route "$origin" || return 1
  raw="$(_aa_call "create-pr" POST "${_AA_ROUTE}/pullrequests?api-version=7.1" \
    "{\"sourceRefName\":$(_aa_json_str "refs/heads/$src"),\"targetRefName\":$(_aa_json_str "refs/heads/$tgt"),\"title\":$(_aa_json_str "$title"),\"description\":$(_aa_json_str "$(cat "$bodyf")"),\"isDraft\":$draft,\"workItemRefs\":$ids}")" || return 1
  printf '%s' "$raw" | jq -c --arg webbase "$(_aa_pr_webbase)" "$_AA_PR_GH_JQ" 2>/dev/null \
    || { _aa_err "create-pr: unrecognised response — the PR may or may not exist"; return 1; }
}

# Linked PR artefacts of a work item (intake rule 9): [{id, status, closedDate}].
_aa_item_linked_prs() { # <id>
  local raw ids id out='[]' pr
  _aa_require_work_item_id "$1" || return 1
  raw="$(_aa_call "item-linked-prs" GET "/_apis/wit/workitems/$1?\$expand=relations&api-version=7.1")" || return 1
  ids="$(printf '%s' "$raw" | jq -r '[.relations[]? | select(.rel == "ArtifactLink")
        | (.url // "") | ascii_downcase | select(startswith("vstfs:///git/pullrequestid/"))
        | capture("%2f(?<n>[0-9]+)$").n] | unique | .[]' 2>/dev/null | tr -d '\r')" \
    || { _aa_err "item-linked-prs: malformed work item $1"; return 1; }
  for id in $ids; do
    pr="$(_aa_call "item-linked-prs (PR $id)" GET "/_apis/git/pullrequests/$id?api-version=7.1")" || return 1
    out="$(printf '%s' "$pr" | jq -c --argjson a "$out" '$a + [{id: .pullRequestId, status: (.status // ""), closedDate: (.closedDate // "")}]' 2>/dev/null)" \
      || { _aa_err "item-linked-prs: malformed PR $id"; return 1; }
  done
  printf '%s\n' "$out"
}

_aa_main() {
  local cmd="${1:-}"
  case "$cmd" in
    dispatch-label-config)
      local lbl="${SGE_DISPATCH_LABEL:-sge-ready}"
      _aa_require_label_name "$lbl" || exit 1
      printf '%s\n' "$lbl"
      ;;
    view-item)
      [ -n "${2:-}" ] || _aa_usage 'view-item needs <work-item-id>'
      _aa_require_work_item_id "$2" || exit 1
      _aa_api_get "/_apis/wit/workitems/$2?\$expand=relations&api-version=7.1"
      ;;
    item-dependencies)
      [ -n "${2:-}" ] || _aa_usage 'item-dependencies needs <work-item-id>'
      _aa_require_work_item_id "$2" || exit 1
      command -v jq >/dev/null 2>&1 || { _aa_err "jq not found — required for item-dependencies"; exit 1; }
      local rel_json dep_ids dep_items
      rel_json="$(_aa_api_get "/_apis/wit/workitems/$2?\$expand=relations&api-version=7.1")" || exit 1
      dep_ids="$(printf '%s' "$rel_json" | jq -r '
        [.relations[]? |
          select((.rel == "System.LinkTypes.Dependency-Reverse") or (.rel == "System.LinkTypes.Hierarchy-Reverse")) |
          (.url | capture("(?<id>[0-9]+)$").id)
        ] | unique | join(",")')"
      [ -n "$dep_ids" ] || exit 0
      dep_items="$(_aa_hydrate_ids "$dep_ids")" || exit 1
      printf '%s' "$dep_items" | jq -r '
        .value[]?
        | [(.id|tostring),
           ((
              ((.fields."System.StateCategory" // .fields."System.State" // "") | ascii_downcase)
            ) as $state
            | if ($state == "completed" or $state == "removed" or $state == "done" or $state == "closed" or $state == "resolved")
              then "closed"
              else "open"
              end)]
        | @tsv'
      ;;
    search-items)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _aa_usage 'search-items needs <project> <text> [open|closed|all]'
      _aa_require_project_name "$2" || exit 1
      local state="${4:-open}" qtext wiql
      qtext="$(_aa_wiql_escape "$3")"
      wiql="SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = \"$2\" AND [System.Title] CONTAINS \"$qtext\""
      case "$state" in
        open) wiql="$wiql AND [System.StateCategory] <> 'Completed' AND [System.StateCategory] <> 'Removed'" ;;
        closed) wiql="$wiql AND ([System.StateCategory] = 'Completed' OR [System.StateCategory] = 'Removed')" ;;
        all) : ;;
        *) _aa_err "search-items: invalid state '$state' — use open|closed|all"; exit 2 ;;
      esac
      _aa_list_or_search "$2" "$wiql"
      ;;
    list-dispatchable)
      [ -n "${2:-}" ] || _aa_usage 'list-dispatchable needs <project>'
      _aa_require_project_name "$2" || exit 1
      local lbl="${3:-${SGE_DISPATCH_LABEL:-sge-ready}}"
      _aa_require_label_name "$lbl" || exit 1
      local wiql="SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = \"$2\" AND [System.StateCategory] <> 'Completed' AND [System.StateCategory] <> 'Removed' AND [System.Tags] CONTAINS \"$(_aa_wiql_escape "$lbl")\" AND [System.AssignedTo] = ''"
      _aa_list_or_search "$2" "$wiql"
      ;;
    claim-item)
      [ -n "${2:-}" ] || _aa_usage 'claim-item needs <work-item-id>'
      _aa_require_write "claim-item" || exit 1
      _aa_claim_or_release "claim-item" "$2" "claim" || exit 1
      ;;
    release-item)
      [ -n "${2:-}" ] || _aa_usage 'release-item needs <work-item-id>'
      _aa_require_write "release-item" || exit 1
      _aa_claim_or_release "release-item" "$2" "release" || exit 1
      ;;
    list-prs)
      [ -n "${2:-}" ] || _aa_usage 'list-prs needs <origin-url>'
      case "${3:-}" in
        '') _aa_list_prs "$2" || exit 1 ;;
        --gh) _aa_list_prs "$2" gh || exit 1 ;;
        *) _aa_usage "list-prs: unknown option '$3'" ;;
      esac
      ;;
    list-completed-prs)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _aa_usage 'list-completed-prs needs <origin-url> <branch>'
      _aa_list_completed_prs "$2" "$3" || exit 1
      ;;
    repo-id)
      # Pure: the org/project/repo an Azure Repos origin names. No network.
      [ -n "${2:-}" ] || _aa_usage 'repo-id needs <origin-url>'
      _aa_parse_origin "$2" || exit 1
      printf '%s/%s/%s\n' "$_AA_R_ORG" "$_AA_R_PROJECT" "$_AA_R_REPO"
      ;;
    get-pr)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _aa_usage 'get-pr needs <origin-url> <pr>'
      _aa_get_pr "$2" "$3" || exit 1
      ;;
    pr-files)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _aa_usage 'pr-files needs <origin-url> <pr>'
      _aa_pr_files "$2" "$3" || exit 1
      ;;
    pr-diff)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _aa_usage 'pr-diff needs <origin-url> <pr>'
      _aa_pr_diff "$2" "$3" || exit 1
      ;;
    pr-commits)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _aa_usage 'pr-commits needs <origin-url> <pr>'
      _aa_pr_commits "$2" "$3" || exit 1
      ;;
    pr-threads)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _aa_usage 'pr-threads needs <origin-url> <pr>'
      _aa_pr_threads "$2" "$3" || exit 1
      ;;
    pr-ci)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _aa_usage 'pr-ci needs <origin-url> <pr>'
      _aa_pr_ci "$2" "$3" || exit 1
      ;;
    pr-claim-status)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || _aa_usage 'pr-claim-status needs <origin-url> <pr> <kind>'
      _aa_pr_claim_status "$2" "$3" "$4" || exit 1
      ;;
    pr-verdict-status)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _aa_usage 'pr-verdict-status needs <origin-url> <pr>'
      _aa_pr_verdict_status "$2" "$3" || exit 1
      ;;
    pr-votes)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _aa_usage 'pr-votes needs <origin-url> <pr>'
      _aa_pr_votes "$2" "$3" || exit 1
      ;;
    pr-work-items)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _aa_usage 'pr-work-items needs <origin-url> <pr>'
      _aa_pr_work_items "$2" "$3" || exit 1
      ;;
    item-linked-prs)
      [ -n "${2:-}" ] || _aa_usage 'item-linked-prs needs <work-item-id>'
      _aa_item_linked_prs "$2" || exit 1
      ;;
    pr-add-label|pr-remove-label)
      _aa_require_write "$cmd" || exit 1
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || _aa_usage "$cmd needs <origin-url> <pr> <label>"
      if [ "$cmd" = pr-add-label ]; then _aa_pr_add_label "$2" "$3" "$4" || exit 1
      else _aa_pr_remove_label "$2" "$3" "$4" || exit 1; fi
      ;;
    pr-claim|pr-release-claim)
      _aa_require_write "$cmd" || exit 1
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || _aa_usage "$cmd needs <origin-url> <pr> <kind> [--force]"
      local _rc=0
      if [ "$cmd" = pr-claim ]; then _aa_pr_claim "$2" "$3" "$4" "${5:-}" "${6:-}" || _rc=$?
      else _aa_pr_release_claim "$2" "$3" "$4" "${5:-}" || _rc=$?; fi
      exit "$_rc"
      ;;
    pr-claim-heartbeat)
      _aa_require_write "$cmd" || exit 1
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || _aa_usage 'pr-claim-heartbeat needs <origin-url> <pr> <kind>'
      local _rc=0
      _aa_pr_claim_heartbeat "$2" "$3" "$4" || _rc=$?
      exit "$_rc"
      ;;
    pr-comments)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _aa_usage 'pr-comments needs <origin-url> <pr>'
      _aa_pr_comments "$2" "$3" || exit 1
      ;;
    pr-comment)
      _aa_require_write "$cmd" || exit 1
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || _aa_usage 'pr-comment needs <origin-url> <pr> <body-file>'
      _aa_pr_comment "$2" "$3" "$4" || exit 1
      ;;
    pr-verdict)
      _aa_require_write "pr-verdict" || exit 1
      [ "$#" -ge 6 ] || _aa_usage 'pr-verdict needs <origin-url> <pr> <approve|wait|reject> <expected-head> <body-file>'
      local _rc=0
      _aa_pr_verdict "$2" "$3" "$4" "$5" "$6" || _rc=$?
      exit "$_rc"
      ;;
    pr-merge)
      _aa_require_write "pr-merge" || exit 1
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || _aa_usage 'pr-merge needs <origin-url> <pr> <expected-head>'
      local _rc=0
      _aa_pr_merge "$2" "$3" "$4" || _rc=$?
      exit "$_rc"
      ;;
    pr-auto-complete)
      _aa_require_write "pr-auto-complete" || exit 1
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || _aa_usage 'pr-auto-complete needs <origin-url> <pr> <expected-head>'
      local _rc=0
      _aa_pr_auto_complete "$2" "$3" "$4" || _rc=$?
      exit "$_rc"
      ;;
    pr-auto-complete-clear)
      _aa_require_write "pr-auto-complete-clear" || exit 1
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] || _aa_usage 'pr-auto-complete-clear needs <origin-url> <pr> <judged-head|none>'
      _aa_pr_auto_complete_clear "$2" "$3" "$4" || exit 1
      ;;
    create-pr)
      _aa_require_write "create-pr" || exit 1
      [ "$#" -ge 6 ] || _aa_usage 'create-pr needs <origin-url> <source> <target> <title> <body-file> [--draft] [<work-item-id>...]'
      shift
      _aa_create_pr "$@" || exit 1
      ;;
    ci-reduce)
      # Pure: the DP5 reduction over a {head,policies,builds,reviewers} object
      # on stdin. No network, no credential — the shared-vector test seam.
      command -v jq >/dev/null 2>&1 || { _aa_err "jq not found — required for ci-reduce"; exit 1; }
      jq -c "$_AA_DP5_JQ" || { _aa_err "ci-reduce: input is not a reducible object"; exit 1; }
      ;;
    comment-item)
      _aa_require_write "comment-item" || exit 1
      [ -n "${2:-}" ] && [ "$#" -ge 3 ] || _aa_usage 'comment-item needs <work-item-id> <body>'
      _aa_comment_item "$2" "$3" || exit 1
      ;;
    create-item)
      _aa_require_write "create-item" || exit 1
      _aa_require_create || exit 1
      [ -n "${2:-}" ] || _aa_usage 'create-item needs <title> [<description>]'
      _aa_create_item "$2" "${3:-}" || exit 1
      ;;
    link-close-on-merge)
      _aa_require_write "link-close-on-merge" || exit 1
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _aa_usage 'link-close-on-merge needs <work-item-id> <pr-url>'
      _aa_link_close_on_merge "$2" "$3" || exit 1
      ;;
    item-comments)
      [ -n "${2:-}" ] || _aa_usage 'item-comments needs <work-item-id>'
      _aa_item_comments "$2" || exit 1
      ;;
    -h|--help|help|'')
      _aa_usage
      ;;
    *)
      _aa_usage "unknown command '$cmd'"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  _aa_main "$@"
fi
