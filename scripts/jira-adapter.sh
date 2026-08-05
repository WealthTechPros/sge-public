#!/usr/bin/env bash
# jira-adapter.sh — the ALM-adapter port's first non-GitHub backend (SPEC-105,
# issue #1596 — S1 enabler slice of the #1150 Jira/ADO epic).
#
# `gh`-based dispatch skills assume the ISSUE TRACKER is GitHub Issues. A repo
# whose work items live in Jira cannot be dispatched — there is no
# `gh issue list` for a Jira project. This adapter is the single seam every
# downstream skill slice (S2–S4) routes through when `with-repo-cwd.sh alm`
# reports `jira`. S1 ships the READ verbs (P1 list-dispatchable, P2 view-item,
# P7 item-dependencies, P9 dispatch-label-config), the claim-mutex core
# (P3 claim-item / P4 release-item), and the credential + allow-list +
# redirect-pin boundary. S3 (#1701) adds the mutating comment/create/link ops
# (P5 comment-item, P6 create-item — DP3 scope-gated, P8 link-close-on-merge).
# Still absent: P7/P9's Jira realisations, which are S4 scope.
#
# Structure mirrors scripts/forgejo-adapter.sh (SPEC-094) point-for-point:
# injection-safe field encoding (_ja_json_str = the _fa_json_str family), the
# read-only-vs-mutating boundary checked BEFORE any credential/host/project
# resolution, host allow-list before auth, redirects pinned so the credential
# never rides a cross-host redirect, and path components validated before URL
# construction.
#
# Configuration (environment; per the Doppler-injected convention — never
# stored in the repo, never logged):
#   SGE_JIRA_BASE_URL   https://<host> of the Jira instance (Cloud or Server).
#                       Caller/config-supplied → treated as UNTRUSTED until the
#                       host passes the allow-list.
#   SGE_JIRA_HOSTS      ';'-separated allow-list of bare hosts the credential
#                       may be sent to. The base URL's host MUST appear here —
#                       an explicit listing IS the trust decision (SPEC-094
#                       pattern: routing is not trust).
#   SGE_JIRA_BEARER     OAuth bearer token  — preferred when set, OR
#   SGE_JIRA_EMAIL + SGE_JIRA_API_TOKEN
#                       Jira Cloud Basic auth pair (email + API token).
#   Any op needing auth FAILS LOUD when no credential is set — never a silent
#   unauthenticated call.
#
#   SGE_DISPATCH_LABEL              dispatch-gate label name (default sge-ready
#                                   — DP2: the Jira gate is a label).
#   SGE_JIRA_CLAIM_TRANSITION_ID    workflow transition id that acquires the
#                                   claim (→ the transition-guarded `Claimed`
#                                   status). REQUIRED for claim-item: the
#                                   transition guard is what makes the claim
#                                   single-winner — the second racer's
#                                   transition is no longer available and Jira
#                                   refuses it (409/400), which claim-item
#                                   surfaces as a loud non-zero "already
#                                   claimed". Without it configured we REFUSE
#                                   to claim (DR3: claim atomicity not
#                                   guaranteeable → fail loud, never permit a
#                                   double-claim).
#   SGE_JIRA_RELEASE_TRANSITION_ID  transition id that releases the claim
#                                   (REQUIRED for release-item, same rule).
#   SGE_JIRA_CLAIM_STATUS           optional status name of the claimed state;
#                                   when set, list-dispatchable additionally
#                                   excludes items sitting in it.
#
# Read-only-vs-mutating boundary (the FORGEJO_ADAPTER_ALLOW_WRITE analogue):
#   Read ops     — always allowed.
#   Mutating ops — REFUSE unless JIRA_ADAPTER_ALLOW_WRITE=1, checked BEFORE any
#                  credential, project, or JQL resolution, so a read-path
#                  caller gets the boundary error, not an auth complaint.
#
# Usage:
#   jira-adapter.sh dispatch-label-config                                (read, P9)
#       Print the repo-configurable dispatch-label name (default sge-ready).
#       Pure/local — no network, no credential.
#   jira-adapter.sh view-item <issueKey>                                 (read, P2)
#       GET one work item's fields (summary, description, labels, assignee,
#       status, issuelinks). Prints the Jira JSON.
#   jira-adapter.sh item-dependencies <issueKey>                         (read, P7)
#       Print, one per line, `<KEY>\t<open|closed>` for every issue this item
#       is blocked by (link type "is blocked by"), state resolved via status
#       CATEGORY (DR2 — never a localised status name).
#   jira-adapter.sh search-items <project-key> <text> [open|closed|all] (read, P10)
#       JQL `summary ~ "<text>"` scoped to <project-key>. State defaults to
#       "open" (statusCategory != Done); "closed" = Done only; "all" = no
#       state filter. Free text is JQL-escaped so it cannot break out of the
#       string literal. Prints the Jira search JSON (same shape as
#       list-dispatchable).
#   jira-adapter.sh list-dispatchable <project-key> [<dispatch-label>]   (read, P1)
#       Open (statusCategory != Done) items in <project-key> carrying the
#       dispatch label, unassigned, excluding SGE_JIRA_CLAIM_STATUS when set.
#       Prints the Jira search JSON. JQL is assembled ONLY from atoms that have
#       passed a strict character class — no free text reaches the query.
#   jira-adapter.sh claim-item <issueKey>                            (MUTATING, P3)
#       Fire the SGE_JIRA_CLAIM_TRANSITION_ID transition. Exactly one racer
#       wins; the loser's transition is refused by Jira and this exits non-zero
#       reporting the item already claimed.
#   jira-adapter.sh release-item <issueKey>                          (MUTATING, P4)
#       Fire the SGE_JIRA_RELEASE_TRANSITION_ID transition.
#   jira-adapter.sh comment-item <issueKey> <body>                   (MUTATING, P5)
#       Append a comment (claim notice, triage, exit report). The body is
#       injection-encoded through _ja_json_str — free text can never close the
#       JSON string early and inject a sibling key. A non-2xx is surfaced loud.
#   jira-adapter.sh create-item <project-key> <summary> [<description>]  (MUTATING, P6)
#       Open a new work item. SCOPE-GATED per DP3: needs JIRA_ADAPTER_ALLOW_WRITE=1
#       AND the explicit JIRA_ADAPTER_ALLOW_CREATE=1 opt-in — the common-case
#       dispatch token must not be able to create items in the customer's Jira.
#       Issue type = SGE_JIRA_ISSUETYPE (default Task). Prints the created JSON
#       ({key,...}). All free text is injection-encoded.
#   jira-adapter.sh link-close-on-merge <issueKey> <change-url> [<title>]  (MUTATING, P8)
#       Express "merging this change closes item N" on the Jira item. Jira has
#       NO native link to an externally-hosted PR (#1150); the CORRELATION
#       CONVENTION is a development-panel REMOTE LINK on the issue carrying the
#       merged change URL, with a stable globalId (= the URL) so a re-run is
#       idempotent, not a duplicate. When SGE_JIRA_CLOSE_TRANSITION_ID is set the
#       close transition is ALSO fired. FAILURE MODE: a non-2xx from the
#       remote-link POST (or a non-204 from the optional transition) is surfaced
#       non-zero — the linkage is never silently swallowed, so a caller must not
#       record an unlinked merge as linked.
# END_USAGE
#
# NOTE: shell state does NOT persist across agent tool calls; skills re-derive
# their adapter context at the top of every shell call, exactly as for
# with-repo-cwd.sh and forgejo-adapter.sh.

_JA_SELF="${BASH_SOURCE[0]}"

# Never run traced: xtrace is INHERITABLE via SHELLOPTS=xtrace in the
# environment, and a traced run would echo the Authorization material to
# stderr — which CI/agent harnesses routinely capture into durable logs. The
# executed path disables it here; the credential-touching functions ALSO
# disable it function-scoped (`local -; set +x`) so a sourcing caller who
# traces cannot leak either.
{ set +x; } 2>/dev/null

_ja_err() { printf 'jira-adapter: error: %s\n' "$*" >&2; }

# Emit a JSON string literal (surrounding quotes included) for arbitrary text —
# the SAFE encoder for free-text fields, reproduced from forgejo-adapter.sh's
# _fa_json_str. Prefer jq; the jq-less fallback escapes backslash FIRST, then
# double-quote, then the literal control bytes tab/CR/LF, so a value containing
# '"' or '\' can never close the string early and inject sibling keys. Never
# hand-interpolate untrusted item text straight into a JSON body — call this.
_ja_json_str() { # <raw-text>  -> stdout: quoted JSON string literal
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -Rs .
    return
  fi
  local s="$1"
  s="${s//\\/\\\\}"    # backslash first
  s="${s//\"/\\\"}"    # then double-quote
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  # Remaining C0 control bytes (0x01–0x1F minus the three above) must be
  # \u00XX-escaped too — emitting them raw would produce INVALID JSON, which
  # jq's path never does; the fallback must match it byte-for-byte.
  local i c
  for i in 1 2 3 4 5 6 7 8 11 12 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    c="$(printf "\\$(printf '%03o' "$i")")"
    [ -n "$c" ] && s="${s//$c/$(printf '\\u%04x' "$i")}"
  done
  printf '"%s"' "$s"
}

_ja_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Validate an issueKey against the strict class ^[A-Z][A-Z0-9]+-[0-9]+$
# (SPEC-105 §2.4) BEFORE it goes anywhere near a URL — a reference like
# 'PROJ-1/../../rest/api/2/myself' must never traverse to another REST route.
_ja_valid_issue_key() { # <key>
  case "$1" in
    [A-Z][A-Z0-9]*-[0-9]*) : ;;
    *) return 1 ;;
  esac
  # The shell pattern above is looser than the spec class (globs cannot anchor
  # "digits only" after the dash); tighten with expr-free loops: the part
  # before the last '-' must be [A-Z][A-Z0-9]+, after it [0-9]+.
  local proj="${1%-*}" num="${1##*-}"
  case "$proj" in
    [A-Z]) return 1 ;;                       # single letter — class needs 2+
    [A-Z]*[!A-Z0-9]*) return 1 ;;
    [A-Z][A-Z0-9]*) : ;;
    *) return 1 ;;
  esac
  case "$num" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

_ja_require_issue_key() { # <key>
  _ja_valid_issue_key "$1" || {
    _ja_err "invalid issueKey '$1' — must match the class [A-Z][A-Z0-9]+-[0-9]+ (SPEC-105 §2.4); refusing before URL construction"
    return 1
  }
}

# Project keys and label names feed BOTH the URL and the JQL query; validate
# against strict classes so neither injection surface is reachable.
_ja_require_project_key() { # <key>
  case "$1" in
    [A-Z][A-Z0-9]*)
      case "$1" in *[!A-Z0-9]*) : ;; *) return 0 ;; esac ;;
  esac
  _ja_err "invalid project key '$1' — must match [A-Z][A-Z0-9]+ (SPEC-105 §2.4)"
  return 1
}

_ja_require_label_name() { # <label>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*)
      _ja_err "invalid label name '$1' — must match [A-Za-z0-9._-]+ (SPEC-105 §2.4)"
      return 1
      ;;
  esac
  return 0
}

# Status names are looser than labels: real Jira statuses commonly contain
# spaces ("In Progress", "Code Review"), and the value only ever lands inside
# a quoted JQL string literal — so spaces are safe, while quote/backslash/
# control bytes (the characters that could close the literal or mangle the
# query) stay forbidden. Deliberately a separate class from labels so nobody
# is tempted to loosen the label validator instead.
_ja_require_status_name() { # <status>
  case "$1" in
    ''|*[!A-Za-z0-9.\ _-]*)
      _ja_err "invalid status name '$1' — must match [A-Za-z0-9. _-]+ (spaces allowed; quotes and backslashes never; SPEC-105 §2.4)"
      return 1
      ;;
  esac
  return 0
}

# Resolve + validate the API base from SGE_JIRA_BASE_URL. Sets _JA_API_BASE
# (https://host[:port], no trailing slash) and _JA_HOSTPORT. https only — the
# credential is never sent over cleartext.
_ja_api_base() {
  local url="${SGE_JIRA_BASE_URL:-}"
  [ -n "$url" ] || { _ja_err "no Jira base URL — set SGE_JIRA_BASE_URL (https://<host>)"; return 1; }
  case "$url" in
    https://*) : ;;
    *) _ja_err "SGE_JIRA_BASE_URL must be https:// (got '$url') — the credential is never sent over cleartext"; return 1 ;;
  esac
  local hostport="${url#https://}"
  hostport="${hostport%%/*}"
  case "$hostport" in
    ''|*[!A-Za-z0-9.:-]*) _ja_err "SGE_JIRA_BASE_URL host '$hostport' contains invalid characters"; return 1 ;;
  esac
  _JA_HOSTPORT="$hostport"
  _JA_API_BASE="https://${hostport}"
}

# Validate the derived host against the allow-list BEFORE the credential is
# attached (SPEC-094 §2.3 pattern). The base URL is caller/config-supplied, so
# an unlisted host (typo or attacker-influenced config) must be REFUSED — the
# token is never leaked to it. Matching keys on the bare host; ':port' is
# stripped from both sides so a port-qualified entry still matches.
_ja_require_allowed_host() { # uses _JA_HOSTPORT
  local host entry h
  host="$(_ja_lower "${_JA_HOSTPORT%%:*}")"
  if [ -n "${SGE_JIRA_HOSTS:-}" ]; then
    local hosts=(); IFS=';' read -r -a hosts <<< "$(_ja_lower "$SGE_JIRA_HOSTS")"
    for entry in "${hosts[@]}"; do
      h="${entry%%:*}"
      [ -n "$h" ] && [ "$host" = "$h" ] && return 0
    done
  fi
  _ja_err "refusing authenticated call to host '${_JA_HOSTPORT}' — not in the SGE_JIRA_HOSTS allow-list (';'-separated bare hosts); the credential is never sent to an unlisted host"
  return 1
}

# Resolve the credential per the SPEC-105 §2.4 convention and PRINT it as curl
# config-file lines (consumed via `curl -K -` on stdin), so the secret never
# appears in curl's argv (readable by any local user via ps/cmdline) and never
# in an xtrace expansion (function-scoped `set +x`). Fails loud when absent.
# Quote/backslash in the values are escaped per curl's config-file quoting so
# the value cannot terminate the config line early.
_ja_credential() {
  local -
  { set +x; } 2>/dev/null
  _ja_cfg_quote() { local v="$1"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "$v"; }
  if [ -n "${SGE_JIRA_BEARER:-}" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$(_ja_cfg_quote "$SGE_JIRA_BEARER")"
  elif [ -n "${SGE_JIRA_EMAIL:-}" ] && [ -n "${SGE_JIRA_API_TOKEN:-}" ]; then
    printf 'user = "%s"\n' "$(_ja_cfg_quote "${SGE_JIRA_EMAIL}:${SGE_JIRA_API_TOKEN}")"
  else
    _ja_err "no Jira credential — set SGE_JIRA_BEARER, or SGE_JIRA_EMAIL + SGE_JIRA_API_TOKEN (never stored in the repo)"
    return 1
  fi
}

# Refuse a mutating op unless the caller opted in. Checked BEFORE any
# credential/host/project resolution — a read-path caller gets the boundary
# error, not an auth complaint (SPEC-105 §2.2).
_ja_require_write() { # <op-name>
  if [ "${JIRA_ADAPTER_ALLOW_WRITE:-}" != "1" ]; then
    _ja_err "refusing mutating op '$1': set JIRA_ADAPTER_ALLOW_WRITE=1 to permit writes (read-only-vs-mutating boundary, SPEC-105 §2.2)"
    return 1
  fi
}

# create-item (P6) is SCOPE-GATED beyond the write boundary (DP3): it is
# EXCLUDED from the default token scope and enabled only via this explicit
# opt-in, so the common-case dispatch token cannot create work items in the
# customer's Jira. Checked AFTER the write boundary, still BEFORE any
# credential/host/project resolution — a caller lacking the opt-in fails loud
# on the scope gate, not on an auth complaint.
_ja_require_create() {
  if [ "${JIRA_ADAPTER_ALLOW_CREATE:-}" != "1" ]; then
    _ja_err "refusing create-item: set JIRA_ADAPTER_ALLOW_CREATE=1 to permit work-item creation — P6 is EXCLUDED from the default token scope (SPEC-105 DP3); the common-case dispatch token must not be able to create items in the customer's Jira"
    return 1
  fi
}

_ja_mktemp() {
  mktemp "${TMPDIR:-/tmp}/jira-adapter.XXXXXX" 2>/dev/null \
    || { _ja_err "mktemp failed — cannot buffer the REST response body"; return 1; }
}

# POST a JSON body to a MUTATING endpoint and require a 2xx. A non-2xx is
# surfaced LOUD (status + a bounded body snippet) — a failed write is NEVER
# silently swallowed, so a caller cannot record an unlinked/uncommented item as
# done. Prints the response body on success (create-item wants the new key).
# The body reaches curl via _ja_api_post_status: credential as config lines on
# stdin (never argv), allow-list before auth, redirects pinned to https.
_ja_post_expect() { # <op-name> <path> <json-body>
  local op="$1" path="$2" body="$3" status tmp snip
  tmp="$(_ja_mktemp)" || return 1
  # The temp holds only a (non-secret, mode-0600) Jira response body. It is
  # removed on every RETURN path below — success, non-2xx, and post-call failure
  # — via _ja_drop_tmp, which ALSO clears the signal trap.
  #
  # A RETURN trap is deliberately NOT used: set inside a function it persists
  # and refires on outer returns where `tmp` is unbound (set -u). INT/TERM is
  # safe because _ja_drop_tmp clears it before this frame goes away, so the
  # handler can never outlive the `tmp` it closes over.
  trap 'rm -f "$tmp"; trap - INT TERM' INT TERM
  _ja_drop_tmp() { rm -f "$tmp"; trap - INT TERM; }
  status="$(_ja_api_post_status "$path" "$body" "$tmp")" || { _ja_drop_tmp; return 1; }
  case "$status" in
    2[0-9][0-9])
      cat "$tmp"
      _ja_drop_tmp
      return 0
      ;;
    *)
      snip="$(head -c 300 "$tmp" 2>/dev/null | tr '\n' ' ')"
      _ja_drop_tmp
      _ja_err "$op failed (HTTP $status) — the write did not land and is not silently swallowed${snip:+; response: $snip}"
      return 1
      ;;
  esac
}

# Authenticated GET. Read path: allow-list before credential, redirects refused
# and pinned to https so the credential can never ride a cross-host redirect.
# The credential is RESOLVED FIRST (fail loud — an empty config must never
# degrade into an unauthenticated call) and reaches curl as config lines on
# stdin (`-K -`), never as argv; xtrace is disabled function-scoped so neither
# the resolution nor the pipe can echo it.
_ja_api_get() { # <path-with-leading-slash-and-query>
  local -
  { set +x; } 2>/dev/null
  _ja_api_base || return 1
  _ja_require_allowed_host || return 1
  local _authcfg
  _authcfg="$(_ja_credential)" || return 1
  command -v curl >/dev/null 2>&1 || { _ja_err "curl not found — required for REST calls"; return 1; }
  printf '%s' "$_authcfg" | \
    curl -K - -fsS --proto '=https' --proto-redir '=https' --max-redirs 0 \
    -H "Accept: application/json" \
    "${_JA_API_BASE}$1"
}

# Authenticated POST. MUTATING path (callers gate via _ja_require_write first).
# Same allow-list/redirect/credential hardening as _ja_api_get. Prints the
# HTTP status code on stdout so callers can branch on the transition-guard
# refusal without parsing bodies; the response body goes to the file named in
# $3 (or /dev/null).
_ja_api_post_status() { # <path> <json-body> [<body-out-file>]
  local -
  { set +x; } 2>/dev/null
  _ja_api_base || return 1
  _ja_require_allowed_host || return 1
  local _authcfg
  _authcfg="$(_ja_credential)" || return 1
  command -v curl >/dev/null 2>&1 || { _ja_err "curl not found — required for REST calls"; return 1; }
  printf '%s' "$_authcfg" | \
    curl -K - -sS --proto '=https' --proto-redir '=https' --max-redirs 0 -X POST \
    -H "Content-Type: application/json" -H "Accept: application/json" \
    -d "$2" -o "${3:-/dev/null}" -w '%{http_code}' \
    "${_JA_API_BASE}$1"
}

# Escape free text for safe inclusion inside a JQL "..." string literal.
# JQL string literals are delimited by double quotes; inside them only `\` and
# `"` need escaping (backslash-prefix). This is NOT JSON encoding — JQL has its
# own quoting rules. Backslash is escaped FIRST so the subsequent quote escape
# cannot double-escape it.
_ja_jql_escape() { # <raw-text> -> stdout: escaped text (no surrounding quotes)
  local s="$1"
  s="${s//\\/\\\\}"    # backslash first
  s="${s//\"/\\\"}"    # then double-quote
  s="${s//$'\n'/ }"    # newline → space (Jira Cloud rejects literal newlines in JQL strings)
  s="${s//$'\r'/ }"    # carriage return → space
  printf '%s' "$s"
}

# URL-encode one query-string value. jq is the correct encoder; the fallback
# percent-encodes everything outside the unreserved set byte-by-byte.
_ja_urlencode() { # <raw> -> stdout: encoded
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

# Fire a workflow transition on an issue; the transition GUARD is the claim
# mutex (SPEC-105 §2.3 / P3 semantics): when two racers fire the same
# transition, Jira accepts exactly one — the loser's transition is no longer
# available on the issue's new status and Jira refuses it, which we surface as
# a loud non-zero exit. HTTP 204 = won; anything else = lost/failed loud.
_ja_transition() { # <issueKey> <transition-id> <claim|release>
  local key="$1" tid="$2" what="$3" status body
  case "$tid" in
    ''|*[!0-9]*) _ja_err "invalid transition id '$tid' — must be numeric"; return 1 ;;
  esac
  body="{\"transition\":{\"id\":$(_ja_json_str "$tid")}}"
  status="$(_ja_api_post_status "/rest/api/2/issue/${key}/transitions" "$body")" || return 1
  case "$status" in
    204) return 0 ;;
    409)
      _ja_err "$what transition refused for '$key' (HTTP 409) — the item is already ${what}ed by another agent (single-winner transition guard); pick another candidate"
      return 1
      ;;
    400)
      # Jira Cloud reports an unavailable transition as 400 — which is EITHER a
      # lost claim race (the winner moved the issue, so the transition is no
      # longer available) OR a misconfigured transition id. Both are loud
      # non-zero (DR3); the message names both so an operator debugging config
      # is not sent chasing a phantom racer.
      _ja_err "$what transition refused for '$key' (HTTP 400) — either the item is already ${what}ed by another agent (lost race, single-winner transition guard: pick another candidate) or transition id '$tid' does not exist on this issue's workflow (check SGE_JIRA_${what^^}_TRANSITION_ID)"
      return 1
      ;;
    *)
      _ja_err "$what transition for '$key' failed (HTTP $status)"
      return 1
      ;;
  esac
}

_ja_usage() {
  # `if`, not `[ -n … ] && …`: the short-circuit form returns non-zero when the
  # arg is empty, which would abort the caller under `set -e` if this ever
  # stopped being followed by `exit 2`.
  if [ -n "${1:-}" ]; then _ja_err "$1"; fi
  # awk, not sed: BSD/macOS sed rejects the `{ /re/d; p }` one-liner address
  # form ("extra characters at the end of p command"), which broke printing
  # this block exactly when a caller had the subcommand wrong (issue #1675).
  awk '/^# END_USAGE/{exit} f{sub(/^# ?/,""); print} /^# Usage:/{f=1; sub(/^# ?/,""); print}' "$_JA_SELF" >&2
  exit 2
}

_ja_main() {
  local cmd="${1:-}"
  case "$cmd" in
    dispatch-label-config)
      # P9 — pure/local: resolve the repo-configurable dispatch-label name.
      # DP2: the Jira dispatch gate is a LABEL, named here, default sge-ready.
      local lbl="${SGE_DISPATCH_LABEL:-sge-ready}"
      _ja_require_label_name "$lbl" || exit 1
      printf '%s\n' "$lbl"
      ;;
    view-item)
      # P2 — one work item's fields. Key validated before URL construction.
      [ -n "${2:-}" ] || _ja_usage 'view-item needs <issueKey>'
      _ja_require_issue_key "$2" || exit 1
      _ja_api_get "/rest/api/2/issue/$2?fields=summary,description,labels,assignee,status,issuelinks"
      ;;
    item-dependencies)
      # P7 — the resolved "is blocked by" set with each dependency's state,
      # resolved via status CATEGORY (DR2), printed as `KEY\topen|closed`.
      [ -n "${2:-}" ] || _ja_usage 'item-dependencies needs <issueKey>'
      _ja_require_issue_key "$2" || exit 1
      command -v jq >/dev/null 2>&1 || { _ja_err "jq not found — required for item-dependencies"; exit 1; }
      local raw
      raw="$(_ja_api_get "/rest/api/2/issue/$2?fields=issuelinks")" || exit 1
      printf '%s' "$raw" | jq -r '
        [.fields.issuelinks[]?
          | select(.type.inward == "is blocked by" and .inwardIssue != null)
          | .inwardIssue]
        | .[]
        | [.key,
           (if .fields.status.statusCategory.key == "done" then "closed" else "open" end)]
        | @tsv'
      ;;
    search-items)
      # P10 — free-text search by summary, scoped to a project. The search
      # text is JQL-escaped (_ja_jql_escape) so it cannot break out of the
      # `summary ~ "..."` literal — the same injection treatment the S1 read
      # path applies to its JQL atoms via character-class validation, but here
      # the input is intentionally free-form so escaping replaces validation.
      [ -n "${2:-}" ] || _ja_usage 'search-items needs <project-key> <text>'
      [ -n "${3:-}" ] || _ja_usage 'search-items needs <project-key> <text>'
      _ja_require_project_key "$2" || exit 1
      local search_text="$3" search_state="${4:-open}"
      local escaped
      escaped="$(_ja_jql_escape "$search_text")"
      local jql="project = $2 AND summary ~ \"$escaped\""
      case "$search_state" in
        open)   jql="$jql AND statusCategory != Done" ;;
        closed) jql="$jql AND statusCategory = Done" ;;
        all)    : ;;  # no state filter
        *)      _ja_err "search-items: invalid state '$search_state' — use open|closed|all"; exit 2 ;;
      esac
      _ja_api_get "/rest/api/2/search?jql=$(_ja_urlencode "$jql")&fields=summary,description,labels,assignee,status,issuelinks"
      ;;
    list-dispatchable)
      # P1 — open items carrying the dispatch label, unassigned, minus the
      # claimed status when configured. JQL is assembled ONLY from atoms that
      # passed the strict classes above; no free text reaches the query.
      [ -n "${2:-}" ] || _ja_usage 'list-dispatchable needs <project-key>'
      _ja_require_project_key "$2" || exit 1
      local lbl="${3:-${SGE_DISPATCH_LABEL:-sge-ready}}"
      _ja_require_label_name "$lbl" || exit 1
      local jql="project = $2 AND statusCategory != Done AND labels = \"$lbl\" AND assignee is EMPTY"
      if [ -n "${SGE_JIRA_CLAIM_STATUS:-}" ]; then
        _ja_require_status_name "${SGE_JIRA_CLAIM_STATUS}" || exit 1
        jql="$jql AND status != \"${SGE_JIRA_CLAIM_STATUS}\""
      fi
      _ja_api_get "/rest/api/2/search?jql=$(_ja_urlencode "$jql")&fields=summary,labels,assignee,status,issuelinks"
      ;;
    claim-item)
      # P3 — MUTATING. Boundary FIRST (before key/credential/host/config), so
      # a read-path caller gets the boundary error, not an auth complaint.
      [ -n "${2:-}" ] || _ja_usage 'claim-item needs <issueKey>'
      _ja_require_write "claim-item" || exit 1
      _ja_require_issue_key "$2" || exit 1
      [ -n "${SGE_JIRA_CLAIM_TRANSITION_ID:-}" ] || {
        _ja_err "claim-item refused: SGE_JIRA_CLAIM_TRANSITION_ID is not set — without the transition guard the claim is not single-winner, and an adapter that cannot guarantee atomic claim MUST fail loud (SPEC-105 DR3)"
        exit 1
      }
      _ja_transition "$2" "${SGE_JIRA_CLAIM_TRANSITION_ID}" "claim" || exit 1
      ;;
    release-item)
      # P4 — MUTATING, same ordering as claim-item.
      [ -n "${2:-}" ] || _ja_usage 'release-item needs <issueKey>'
      _ja_require_write "release-item" || exit 1
      _ja_require_issue_key "$2" || exit 1
      [ -n "${SGE_JIRA_RELEASE_TRANSITION_ID:-}" ] || {
        _ja_err "release-item refused: SGE_JIRA_RELEASE_TRANSITION_ID is not set (SPEC-105 DR3)"
        exit 1
      }
      _ja_transition "$2" "${SGE_JIRA_RELEASE_TRANSITION_ID}" "release" || exit 1
      ;;
    comment-item)
      # P5 — MUTATING. Boundary FIRST (before key/credential/host/project), so a
      # read-path caller gets the write-boundary error, not an auth complaint.
      # The body is injection-encoded via _ja_json_str — never hand-interpolated.
      _ja_require_write "comment-item" || exit 1
      [ -n "${2:-}" ] && [ "$#" -ge 3 ] || _ja_usage 'comment-item needs <issueKey> <body>'
      _ja_require_issue_key "$2" || exit 1
      _ja_post_expect "comment-item" "/rest/api/2/issue/$2/comment" \
        "{\"body\":$(_ja_json_str "$3")}" >/dev/null
      ;;
    create-item)
      # P6 — MUTATING + SCOPE-GATED (DP3): needs the write boundary AND the
      # explicit create opt-in, both checked before any credential/host/project
      # resolution. Every free-text field (summary, description, issuetype,
      # project key) is injection-encoded; the project key is ALSO validated
      # against its strict class.
      _ja_require_write "create-item" || exit 1
      _ja_require_create || exit 1
      [ -n "${2:-}" ] && [ "$#" -ge 3 ] || _ja_usage 'create-item needs <project-key> <summary> [<description>]'
      _ja_require_project_key "$2" || exit 1
      local _ja_itype="${SGE_JIRA_ISSUETYPE:-Task}"
      local _ja_fields
      _ja_fields="{\"project\":{\"key\":$(_ja_json_str "$2")},\"summary\":$(_ja_json_str "$3"),\"issuetype\":{\"name\":$(_ja_json_str "$_ja_itype")}"
      # Arity, not emptiness: an explicitly-supplied empty description is a
      # deliberate "clear the field" and must reach Jira, whereas an omitted
      # 4th arg must leave `description` absent entirely.
      if [ "$#" -ge 4 ]; then
        _ja_fields="${_ja_fields},\"description\":$(_ja_json_str "$4")"
      fi
      _ja_fields="${_ja_fields}}"
      _ja_post_expect "create-item" "/rest/api/2/issue" "{\"fields\":${_ja_fields}}"
      ;;
    link-close-on-merge)
      # P8 — MUTATING. Jira has NO native link to an externally-hosted PR
      # (#1150). CORRELATION CONVENTION: record the merged change as a
      # development-panel REMOTE LINK on the issue, globalId = the change URL so
      # a re-run is idempotent (Jira upserts on globalId) rather than a
      # duplicate. When SGE_JIRA_CLOSE_TRANSITION_ID is configured the close
      # transition is ALSO fired. Both the remote-link POST and the optional
      # transition fail LOUD on a non-2xx/non-204 — the linkage is never
      # silently swallowed, so a caller cannot record an unlinked merge as
      # linked. The change URL only ever lands inside a JSON string value
      # (encoded), never a URL path, so no traversal surface is opened.
      _ja_require_write "link-close-on-merge" || exit 1
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _ja_usage 'link-close-on-merge needs <issueKey> <change-url> [<title>]'
      _ja_require_issue_key "$2" || exit 1
      local _ja_url="$3" _ja_title="${4:-Closed by merged change $3}"
      case "$_ja_url" in
        http://*|https://*) : ;;
        *) _ja_err "link-close-on-merge: <change-url> '$3' is not an http(s) URL"; exit 1 ;;
      esac
      _ja_post_expect "link-close-on-merge (remote link)" "/rest/api/2/issue/$2/remotelink" \
        "{\"globalId\":$(_ja_json_str "$_ja_url"),\"object\":{\"url\":$(_ja_json_str "$_ja_url"),\"title\":$(_ja_json_str "$_ja_title")}}" >/dev/null
      if [ -n "${SGE_JIRA_CLOSE_TRANSITION_ID:-}" ]; then
        case "${SGE_JIRA_CLOSE_TRANSITION_ID}" in
          ''|*[!0-9]*) _ja_err "invalid SGE_JIRA_CLOSE_TRANSITION_ID '${SGE_JIRA_CLOSE_TRANSITION_ID}' — must be numeric"; exit 1 ;;
        esac
        local _ja_tstatus
        _ja_tstatus="$(_ja_api_post_status "/rest/api/2/issue/$2/transitions" \
          "{\"transition\":{\"id\":$(_ja_json_str "${SGE_JIRA_CLOSE_TRANSITION_ID}")}}")" || exit 1
        case "$_ja_tstatus" in
          204) : ;;
          *) _ja_err "link-close-on-merge: close transition for '$2' failed (HTTP $_ja_tstatus) — the merge remote link was recorded but the close transition did not apply; not silently swallowed (check SGE_JIRA_CLOSE_TRANSITION_ID)"; exit 1 ;;
        esac
      fi
      ;;
    -h|--help|help|'')
      _ja_usage
      ;;
    *)
      _ja_usage "unknown command '$cmd'"
      ;;
  esac
}

# Executed (not sourced): run the CLI. Sourcing only defines functions (so the
# guard test can unit-test _ja_json_str) — no `set -e` side effects on the
# sourcing shell, same convention as with-repo-cwd.sh.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  _ja_main "$@"
fi
