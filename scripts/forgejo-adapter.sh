#!/usr/bin/env bash
# forgejo-adapter.sh — thin Forgejo/Gitea REST adapter seam (ADR-0010, #1236).
#
# Enabler slice for the #1146 non-GitHub-host epic. `gh`-based SGE skills
# assume the issue tracker is GitHub. A repo whose `origin` points at a
# self-hosted Forgejo (or Gitea — they share one REST surface) instead fails
# before Step 0 of skills like /sge:sge-align. This adapter is the single seam
# every downstream host-agnostic skill slice (read-issues, read-PRs, mutating
# pr-review, dispatch) will route through when `with-repo-cwd.sh host` reports
# `forgejo`. This slice ships the READ path (repo-resolve first) and the
# read-only-vs-mutating boundary; the concrete read/write REST verbs are grown
# in the downstream slices, each behind this same boundary.
#
# Gitea-compatible REST surface (Forgejo speaks the same dialect):
#   GET  {base}/repos/{owner}/{repo}
#   GET  {base}/repos/{owner}/{repo}/issues
#   GET  {base}/repos/{owner}/{repo}/pulls
#   PATCH {base}/repos/{owner}/{repo}/issues/{index}   (mutating)
# where {base} is https://{host}/api/v1 and auth is a header
#   Authorization: token <PAT>
# — analogous to `gh auth`. See ADR-0010.
#
# Auth-token convention (analogous to `gh auth token`):
#   FORGEJO_API_TOKEN   preferred
#   GITEA_TOKEN         fallback (Gitea's own conventional name)
# Any op that needs auth fails loudly when neither is set — never silently
# makes an unauthenticated call.
#
# Read-only-vs-mutating boundary (mirrors how the gh-based skills gate writes):
#   Read ops       — always allowed (repo-resolve, get-repo, list-issues, …).
#   Mutating ops   — REFUSE unless FORGEJO_ADAPTER_ALLOW_WRITE=1 is set by the
#                    caller. This makes a write an explicit, auditable decision
#                    at the call site, exactly like the mutating gh-based
#                    skills' pre-flight, and keeps a read-path skill from ever
#                    writing by accident.
#
# Usage:
#   forgejo-adapter.sh repo-resolve <origin-url-or-owner/name> [<host>]
#       Print two lines: the owner/name slug and the derived API base URL.
#       Pure/local — no network. This is the read-path seam every other op
#       builds on. When given owner/name (no host in the value) a <host> arg
#       (or SGE_FORGEJO_DEFAULT_HOST) is required to derive the API base.
#   forgejo-adapter.sh get-repo    <origin-url-or-owner/name> [<host>]     (read)
#   forgejo-adapter.sh list-issues <origin-url-or-owner/name> [<host>]     (read)
#   forgejo-adapter.sh list-issues-filtered <origin-url-or-owner/name> [<query-string>] [<host>]  (read)
#       Like list-issues but replaces the default query string with <query-string>.
#       The caller is responsible for encoding. Absent → "state=open&type=issues".
#       Use this for parameterised listing (state, label, page, limit etc.).
#   forgejo-adapter.sh view-issue  <origin-url-or-owner/name> <index> [<host>]  (read)
#       GET a single issue by its tracker index number.
#   forgejo-adapter.sh list-prs    <origin-url-or-owner/name> [<host>]     (read)
#       List open pull requests. Returns JSON array (Gitea PR schema).
#   forgejo-adapter.sh get-pr      <origin-url-or-owner/name> <index> [<host>] (read)
#       Fetch a single PR by its index. Returns JSON object.
#   forgejo-adapter.sh pr-diff     <origin-url-or-owner/name> <index> [<host>] (read)
#       Fetch the unified diff for a PR (plain text, Accept: text/plain).
#   forgejo-adapter.sh pr-statuses <origin-url-or-owner/name> <sha>   [<host>] (read)
#       List commit statuses for a SHA — Forgejo/Gitea's equivalent of CI checks.
#       Returns JSON array (Gitea CommitStatus schema).
#   forgejo-adapter.sh close-issue <origin-url-or-owner/name> <index>      (MUTATING)
#
#   ── PR label state-machine ops (issue #1239) ──────────────────────────────
#   forgejo-adapter.sh pr-label-status    <origin> <pr-num>
#       Print "reviewing=<bool> reviewed=<bool>" for the pr-reviewing /
#       pr-reviewed labels on the PR. Mirrors pr-labels.sh label_status.  (read)
#   forgejo-adapter.sh pr-fix-claim-status <origin> <pr-num>
#       Print "fixing=<bool>" for the pr-fixing label.                    (read)
#   forgejo-adapter.sh pr-is-draft        <origin> <pr-num>
#       Print "true" or "false".                                          (read)
#   forgejo-adapter.sh pr-head-sha        <origin> <pr-num>
#       Print the PR's current HEAD commit SHA.                           (read)
#   forgejo-adapter.sh pr-body            <origin> <pr-num>
#       Print the PR body text (for follow-up preservation gate).         (read)
#   forgejo-adapter.sh pr-commit-status   <origin> <sha>
#       Print the combined Gitea commit status:
#       success | pending | failure | error | none | unknown.             (read)
#   forgejo-adapter.sh pr-ensure-label    <origin> <name> <color> <desc>
#       Idempotent: create the label in the repo if it does not exist.    (MUTATING)
#   forgejo-adapter.sh pr-add-label       <origin> <pr-num> <name>
#       Add a label to a PR by name (label must already exist in repo).   (MUTATING)
#   forgejo-adapter.sh pr-remove-label    <origin> <pr-num> <name>
#       Remove a label from a PR by name. Idempotent — no error if the
#       label is absent or not attached to this PR.                       (MUTATING)
#   forgejo-adapter.sh pr-merge-squash    <origin> <pr-num> <head-sha>
#       Squash-merge a PR, pinned to <head-sha> (sent as head_commit_id so
#       Gitea refuses a moved head — TOCTOU-safe).                        (MUTATING)
#
#   ── Dispatch-skill ops (issue #1240) ──────────────────────────────────────
#   NOTE ON LABEL OPS — two distinct families, do NOT conflate:
#     • ISSUE labels, by numeric ID: get-label / create-label / add-label /
#       remove-label operate on ISSUES and take a label *ID* (resolve name→id
#       via get-label). Used by the dispatch skills' agent-lock claim.
#     • PR labels, by name: pr-ensure-label / pr-add-label / pr-remove-label
#       (issue #1239, above) operate on PRs and take a label *name*. Used by the
#       pr-review gate. They are NOT interchangeable.
#   PR/commit reads for dispatch skills reuse the canonical list-prs / get-pr /
#   pr-statuses verbs above — there is deliberately no list-pulls/get-pull/
#   list-statuses duplicate.
#   forgejo-adapter.sh get-label   <origin-url-or-owner/name> <name>       (read)
#       Look up a repo label by name and print its JSON (including `id`).
#       Exits non-zero when no label with that name exists.
#   forgejo-adapter.sh create-label <origin-url-or-owner/name> <name> <color> [<description>] (MUTATING)
#       Create a repo label. <color> is a 6-digit hex string without '#'.
#   forgejo-adapter.sh add-label    <origin-url-or-owner/name> <issue-index> <label-id> (MUTATING)
#       Add a label (by numeric ID) to an ISSUE (get-label resolves name→id).
#   forgejo-adapter.sh remove-label <origin-url-or-owner/name> <issue-index> <label-id> (MUTATING)
#       Remove a label (by numeric ID) from an ISSUE.
#   forgejo-adapter.sh create-pull  <origin-url-or-owner/name> <head> <base> <title> [--draft] (MUTATING)
#       Open a PR from <head> into <base>; PR body read from stdin.
# END_USAGE
#
# NOTE: shell state does NOT persist across agent tool calls; skills re-derive
# their adapter context at the top of every shell call, exactly as they do for
# scripts/with-repo-cwd.sh. See docs/skill-authoring-repo-context.md and
# docs/decisions/0010-non-github-host-adapter.md.

set -euo pipefail

_FA_SELF="${BASH_SOURCE[0]}"
_FA_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_fa_err() { printf 'forgejo-adapter: error: %s\n' "$*" >&2; }

# Emit a JSON string literal (including the surrounding quotes) for arbitrary
# text — the SAFE encoder for free-text fields (PR title/body, label
# name/description). Prefer jq (correct for the full character range). The
# jq-less fallback escapes the two characters that let text break out of a JSON
# string — backslash and double-quote — plus the literal control bytes tab,
# carriage-return and newline, so a value containing '"' or '\' can never close
# the string early and inject sibling keys (e.g. override "base"). Escaping runs
# backslash-first so an already-escaped backslash is not doubled again. Never
# hand-interpolate untrusted free text straight into a JSON body — call this.
_fa_json_str() { # <raw-text>  -> stdout: quoted JSON string literal
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
  printf '"%s"' "$s"
}

# Reuse with-repo-cwd.sh's host classifier (_wrc_host_kind) as the single
# source of truth for the SGE_FORGEJO_HOSTS / SGE_GITHUB_HOSTS allow-list — do
# NOT fork a second allow-list here. Sourcing only defines functions (that file
# guards its own `set -e`/CLI behind a BASH_SOURCE==$0 check), so this is a
# pure include with no side effects.
# shellcheck source=scripts/with-repo-cwd.sh
. "$_FA_SCRIPT_DIR/with-repo-cwd.sh"

_fa_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Extract the host[:port] from a git remote URL (mirrors with-repo-cwd's helper;
# kept local so the adapter is usable standalone). Empty when no host.
# The port is PRESERVED — a self-hosted instance on a non-default port (e.g.
# git.example.com:3000) must keep it so the derived API base reaches the right
# endpoint. Note: git@host:owner/name (scp-form) uses ':' as the path separator,
# NOT a port, so no port is extractable from that form.
_fa_url_host() {
  local url="$1" h
  case "$url" in
    http://*|https://*|ssh://*)
      h="${url#*://}"; h="${h#*@}"; h="${h%%/*}" ;;   # keep host[:port]
    git@*)
      h="${url#*@}"; h="${h%%:*}" ;;                  # git@host:owner/name — ':' is the path sep
    *) h="" ;;
  esac
  printf '%s' "$h"
}

# Extract owner/name slug from a git URL or accept a bare owner/name.
# Sets _FA_SLUG. Returns non-zero (with a loud error) on anything unparseable.
_fa_slug_of() {
  local v="$1" s
  v="${v%/}"; v="${v%.git}"
  case "$v" in
    http://*|https://*|ssh://*)
      s="${v#*://}"; s="${s#*@}"          # drop scheme + user@
      s="${s#*/}"                          # drop host[:port]/
      ;;
    git@*)
      s="${v#*@}"                          # host:owner/name
      case "$s" in *:*) s="${s#*:}" ;; *) s="" ;; esac
      ;;
    *) s="$v" ;;                           # assume already owner/name
  esac
  # Keep exactly the first two path segments (owner/name), dropping any
  # /issues/N etc. tail.
  case "$s" in
    */*/*) s="${s%%/*}/$(x="${s#*/}"; printf '%s' "${x%%/*}")" ;;
  esac
  case "$s" in
    */*) : ;;
    *) _fa_err "cannot parse an owner/name from '$1'"; return 1 ;;
  esac
  case "${s%%/*}" in ''|*[!A-Za-z0-9._-]*) _fa_err "invalid owner in '$1'"; return 1 ;; esac
  case "${s#*/}"  in ''|*[!A-Za-z0-9._-]*) _fa_err "invalid repo name in '$1'"; return 1 ;; esac
  _FA_SLUG="$s"
}

# Derive the API base URL from a value + optional explicit host.
# Sets _FA_API_BASE. host precedence: <host> arg > host in the URL value >
# SGE_FORGEJO_DEFAULT_HOST. Fails loud when none is available.
_fa_api_base_of() { # <value> [<host>]
  local v="$1" host="${2:-}"
  [ -n "$host" ] || host="$(_fa_url_host "$v")"
  [ -n "$host" ] || host="${SGE_FORGEJO_DEFAULT_HOST:-}"
  [ -n "$host" ] || {
    _fa_err "no host for '$v' — pass it as the last arg or set SGE_FORGEJO_DEFAULT_HOST"
    return 1
  }
  _FA_API_BASE="https://${host}/api/v1"
}

# Validate the derived API-base host against the allow-list before any
# authenticated call. The operator PAT is attached to requests to this host,
# so an unlisted host (attacker-supplied owner/name/URL, or a typo) must be
# REFUSED — never leak the token to it. We reuse with-repo-cwd's classifier so
# there is ONE allow-list (SGE_FORGEJO_HOSTS / SGE_GITHUB_HOSTS), not a fork.
# A host classified `github` or `unknown` is always refused — this adapter
# only ever authenticates to Forgejo/Gitea hosts.
#
# TRUST vs ROUTING: `_wrc_host_kind`'s substring leg (*forgejo*/*gitea*) is a
# ROUTING convenience — it must never gate a credential, because an attacker
# can register gitea.<anything> and a cloned repo's `origin` is
# attacker-influenced data. Token attachment therefore additionally requires
# EXPLICIT trust: the bare host must appear in SGE_FORGEJO_HOSTS (';'-separated)
# or equal SGE_FORGEJO_DEFAULT_HOST. Set SGE_FORGEJO_TRUST_SUBSTRING=1 to
# opt in to substring-classified hosts (NOT recommended outside dev).
# The host may carry a :port (e.g. git.example.com:3000); classification and
# allow-list matching key on the bare host, so we strip the port — and also
# strip any :port from allow-list entries, so a port-qualified entry still
# matches instead of silently never matching.
_fa_require_allowed_host() { # <api-base>
  local base="$1" hostport host kind h entry
  hostport="${base#https://}"; hostport="${hostport%%/*}"   # host[:port]
  host="$(_fa_lower "${hostport%%:*}")"                     # bare host
  # Explicit trust first — an explicit listing IS the trust decision.
  if [ -n "${SGE_FORGEJO_HOSTS:-}" ]; then
    local fjs=(); IFS=';' read -r -a fjs <<< "$(_fa_lower "$SGE_FORGEJO_HOSTS")"
    for entry in "${fjs[@]}"; do
      h="${entry%%:*}"                                      # tolerate host:port entries
      [ -n "$h" ] && [ "$host" = "$h" ] && return 0
    done
  fi
  if [ -n "${SGE_FORGEJO_DEFAULT_HOST:-}" ]; then
    h="$(_fa_lower "$SGE_FORGEJO_DEFAULT_HOST")"; h="${h%%:*}"
    [ "$host" = "$h" ] && return 0
  fi
  # Not explicitly trusted: a substring-classified host is only accepted with
  # the explicit opt-in; everything else is refused before the token exists.
  kind="$(_wrc_host_kind "$host")"
  if [ "$kind" = "forgejo" ] && [ "${SGE_FORGEJO_TRUST_SUBSTRING:-0}" = "1" ]; then
    return 0
  fi
  if [ "$kind" = "forgejo" ]; then
    _fa_err "refusing authenticated call to host '$hostport' — its name merely resembles a Forgejo/Gitea host, which is routing, not trust; the operator token is only sent to hosts explicitly listed in SGE_FORGEJO_HOSTS (';'-separated) or SGE_FORGEJO_DEFAULT_HOST (or set SGE_FORGEJO_TRUST_SUBSTRING=1 to opt in)"
  else
    _fa_err "refusing authenticated call to host '$hostport' (classified '$kind', not an allow-listed Forgejo host) — add it to SGE_FORGEJO_HOSTS (';'-separated) to permit; the operator token is never sent to an unlisted host"
  fi
  return 1
}

# Resolve the auth token per the FORGEJO_API_TOKEN > GITEA_TOKEN convention.
# Sets _FA_TOKEN. Fails loud when neither is set.
_fa_token() {
  if [ -n "${FORGEJO_API_TOKEN:-}" ]; then
    _FA_TOKEN="$FORGEJO_API_TOKEN"
  elif [ -n "${GITEA_TOKEN:-}" ]; then
    _FA_TOKEN="$GITEA_TOKEN"
  else
    _fa_err "no API token — set FORGEJO_API_TOKEN (preferred) or GITEA_TOKEN (analogous to 'gh auth token')"
    return 1
  fi
}

# Refuse a mutating op unless the caller opted in. Mirrors the gh-based skills'
# explicit write pre-flight so a read-path caller can never write by accident.
_fa_require_write() { # <op-name>
  if [ "${FORGEJO_ADAPTER_ALLOW_WRITE:-}" != "1" ]; then
    _fa_err "refusing mutating op '$1': set FORGEJO_ADAPTER_ALLOW_WRITE=1 to permit writes (read-only-vs-mutating boundary, ADR-0010)"
    return 1
  fi
}

# Perform an authenticated GET against the Gitea REST surface. Read path.
# Host is allow-list-validated before the token is attached, and redirects are
# refused (--max-redirs 0) and pinned to https (--proto/--proto-redir) so the
# manually-set Authorization header can never ride a cross-host redirect to an
# unvalidated endpoint and leak the operator PAT.
_fa_api_get() { # <api-base> <path>
  _fa_require_allowed_host "$1" || return 1
  _fa_token || return 1
  command -v curl >/dev/null 2>&1 || { _fa_err "curl not found — required for REST calls"; return 1; }
  curl -fsS --proto '=https' --proto-redir '=https' --max-redirs 0 \
    -H "Authorization: token ${_FA_TOKEN}" -H "Accept: application/json" \
    "$1$2"
}

# Authenticated POST/PATCH against the Gitea REST surface. MUTATING.
# Same redirect and allow-list hardening as _fa_api_get. Body is required.
_fa_api_post() { # <method> <api-base> <path> <json-body>
  local method="$1" base="$2" path="$3" body="$4"
  _fa_require_allowed_host "$base" || return 1
  _fa_token || return 1
  command -v curl >/dev/null 2>&1 || { _fa_err "curl not found — required for REST calls"; return 1; }
  curl -fsS --proto '=https' --proto-redir '=https' --max-redirs 0 -X "$method" \
    -H "Authorization: token ${_FA_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$body" "$base$path"
}

# Authenticated DELETE. MUTATING. Idempotent: 404 is treated as success.
_fa_api_delete() { # <api-base> <path>
  local base="$1" path="$2"
  _fa_require_allowed_host "$base" || return 1
  _fa_token || return 1
  command -v curl >/dev/null 2>&1 || { _fa_err "curl not found — required for REST calls"; return 1; }
  # Use -o/dev/null -w '%{http_code}' so we can treat 404 as success (idempotent)
  # without curl -f failing on it.
  local http_code
  http_code=$(curl -sS --proto '=https' --proto-redir '=https' --max-redirs 0 -X DELETE \
    -H "Authorization: token ${_FA_TOKEN}" \
    -H "Accept: application/json" \
    -o /dev/null -w '%{http_code}' \
    "$base$path" 2>/dev/null) || true
  case "${http_code:-}" in
    2??) return 0 ;;
    404) return 0 ;;   # already absent — idempotent
    '')  _fa_err "DELETE ${base}${path}: no HTTP response from curl"; return 1 ;;
    *)   _fa_err "DELETE ${base}${path}: HTTP ${http_code}"; return 1 ;;
  esac
}

# Find a repo-level label by name; print its full JSON object (compact) on
# stdout — id, color, description and all. Returns non-zero (silently) when the
# label does not exist. This is the primitive; _fa_find_label_id narrows it to
# the id. pr-ensure-label needs the whole record to detect appearance drift.
_fa_find_label() { # <api-base> <slug> <label-name>
  local base="$1" slug="$2" name="$3" page=1 raw count found
  while :; do
    raw=$(_fa_api_get "$base" "/repos/$slug/labels?limit=50&page=$page") || return 1
    count=$(printf '%s' "$raw" | jq 'length' 2>/dev/null) || break
    [ "${count:-0}" -eq 0 ] && break
    found=$(printf '%s' "$raw" | jq -c --arg n "$name" \
        'map(select(.name == $n)) | .[0] // empty' 2>/dev/null)
    if [ -n "$found" ] && [ "$found" != "null" ]; then
      printf '%s' "$found"; return 0
    fi
    [ "${count:-0}" -lt 50 ] && break
    page=$((page+1))
    [ "$page" -gt 10 ] && break  # safety cap: 500 labels
  done
  return 1
}

# Find a repo-level label by name; print its numeric ID on stdout.
# Returns non-zero (silently) when the label does not exist.
_fa_find_label_id() { # <api-base> <slug> <label-name>
  local _obj
  _obj=$(_fa_find_label "$1" "$2" "$3") || return 1
  printf '%s' "$_obj" | jq -r '.id'
}

# Get the labels currently attached to a PR/issue as a JSON array.
# Returns the raw Gitea JSON: [{id, name, ...}, ...].
_fa_pr_labels_json() { # <api-base> <slug> <pr-num>
  # Gitea treats PRs as issues for label purposes.
  _fa_api_get "$1" "/repos/$2/issues/$3/labels"
}

_fa_usage() {
  [ -n "${1:-}" ] && _fa_err "$1"
  # awk, not sed: BSD/macOS sed rejects the `{ /re/d; p }` one-liner address
  # form ("extra characters at the end of p command"), which broke printing
  # this block exactly when a caller had the subcommand wrong (issue #1675).
  awk '/^# END_USAGE/{exit} f{sub(/^# ?/,""); print} /^# Usage:/{f=1; sub(/^# ?/,""); print}' "$_FA_SELF" >&2
  exit 2
}

_fa_main() {
  local cmd="${1:-}"
  case "$cmd" in
    repo-resolve)
      [ -n "${2:-}" ] || _fa_usage 'repo-resolve needs <origin-url-or-owner/name>'
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "${3:-}" || exit 1
      printf '%s\n%s\n' "$_FA_SLUG" "$_FA_API_BASE"
      ;;
    get-repo)
      [ -n "${2:-}" ] || _fa_usage 'get-repo needs <origin-url-or-owner/name>'
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "${3:-}" || exit 1
      _fa_api_get "$_FA_API_BASE" "/repos/$_FA_SLUG"
      ;;
    list-issues)
      [ -n "${2:-}" ] || _fa_usage 'list-issues needs <origin-url-or-owner/name>'
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "${3:-}" || exit 1
      _fa_api_get "$_FA_API_BASE" "/repos/$_FA_SLUG/issues?state=open&type=issues"
      ;;
    list-prs)
      # List open pull requests. Returns JSON array (Gitea PR schema).
      # Paginates with page=1&limit=50 — enough for typical active repos; callers
      # that need full pagination should page via the Link header themselves.
      [ -n "${2:-}" ] || _fa_usage 'list-prs needs <origin-url-or-owner/name>'
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "${3:-}" || exit 1
      _fa_api_get "$_FA_API_BASE" "/repos/$_FA_SLUG/pulls?state=open&page=1&limit=50"
      ;;
    get-pr)
      # Fetch a single PR by its numeric index. Returns JSON object (Gitea PR schema).
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _fa_usage 'get-pr needs <origin-url-or-owner/name> <index>'
      case "$3" in
        ''|*[!0-9]*) _fa_err "invalid PR index '$3' — must be a positive integer"; exit 1 ;;
      esac
      _fa_slug_of "$2" || exit 1
      # Host may be in the value (URL) or the 4th arg (bare owner/name form).
      _fa_api_base_of "$2" "${4:-}" || exit 1
      _fa_api_get "$_FA_API_BASE" "/repos/$_FA_SLUG/pulls/$3"
      ;;
    pr-diff)
      # Fetch the unified diff for a PR (plain text). Gitea serves this at
      # /pulls/{index}.diff with Content-Type text/plain.
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _fa_usage 'pr-diff needs <origin-url-or-owner/name> <index>'
      case "$3" in
        ''|*[!0-9]*) _fa_err "invalid PR index '$3' — must be a positive integer"; exit 1 ;;
      esac
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "${4:-}" || exit 1
      _fa_require_allowed_host "$_FA_API_BASE" || exit 1
      _fa_token || exit 1
      command -v curl >/dev/null 2>&1 || { _fa_err "curl not found — required for REST calls"; exit 1; }
      # Accept text/plain to receive the raw diff; same redirect-leak hardening
      # as _fa_api_get: refuse redirects, pin to https, never leak the PAT.
      curl -fsS --proto '=https' --proto-redir '=https' --max-redirs 0 \
        -H "Authorization: token ${_FA_TOKEN}" -H "Accept: text/plain" \
        "$_FA_API_BASE/repos/$_FA_SLUG/pulls/$3.diff"
      ;;
    pr-statuses)
      # List commit statuses for a SHA — Forgejo/Gitea's CI-checks equivalent.
      # Returns JSON array (Gitea CommitStatus schema: state, context, description).
      # Callers map `state` (pending/success/error/failure/warning) to the same
      # traffic-light logic used for `gh pr checks` output.
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _fa_usage 'pr-statuses needs <origin-url-or-owner/name> <sha>'
      # Validate SHA: hex only, and 7–40 chars (abbreviated to full git SHA-1).
      # The character-class check alone accepted "" (caught) but also any length;
      # enforce the bound the comment promises so a stray/oversized token can't
      # be interpolated into the commits/<sha>/statuses path.
      case "$3" in
        *[!0-9A-Fa-f]*) _fa_err "invalid SHA '$3' — must be a hex string"; exit 1 ;;
      esac
      if [ "${#3}" -lt 7 ] || [ "${#3}" -gt 40 ]; then
        _fa_err "invalid SHA '$3' — must be 7–40 hex chars"; exit 1
      fi
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "${4:-}" || exit 1
      _fa_api_get "$_FA_API_BASE" "/repos/$_FA_SLUG/commits/$3/statuses?page=1&limit=50"
      ;;
    list-issues-filtered)
      # Like list-issues but accepts an explicit <query-string> appended verbatim as
      # the URL query string (no leading '?'). Caller is responsible for encoding.
      # Absent <query-string> → "state=open&type=issues" (same default as list-issues
      # plus the type=issues filter to exclude pull-request entries).
      [ -n "${2:-}" ] || _fa_usage 'list-issues-filtered needs <origin-url-or-owner/name>'
      local _fa_qs="${3:-state=open&type=issues}"
      local _fa_host_arg="${4:-}"
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "$_fa_host_arg" || exit 1
      _fa_api_get "$_FA_API_BASE" "/repos/$_FA_SLUG/issues?${_fa_qs}"
      ;;
    view-issue)
      # GET a single issue by its tracker index.
      # Usage: forgejo-adapter.sh view-issue <origin-url-or-owner/name> <index> [<host>]
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _fa_usage 'view-issue needs <origin-url-or-owner/name> <index>'
      local _fa_view_idx="$3"
      case "$_fa_view_idx" in
        ''|*[!0-9]*) _fa_err "invalid issue index '$_fa_view_idx' — must be a positive integer"; exit 1 ;;
      esac
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "${4:-}" || exit 1
      _fa_api_get "$_FA_API_BASE" "/repos/$_FA_SLUG/issues/$_fa_view_idx"
      ;;
    close-issue)
      # MUTATING — gated behind the write boundary. Refusal is checked before
      # token/host so a read-path caller gets the boundary error, not an
      # auth/host complaint.
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _fa_usage 'close-issue needs <origin-url-or-owner/name> <index>'
      _fa_require_write "close-issue" || exit 1
      # Validate the issue index before it goes into a URL — a non-numeric value
      # is a caller error (or an injection attempt), never a real Gitea index.
      case "$3" in
        ''|*[!0-9]*) _fa_err "invalid issue index '$3' — must be a positive integer"; exit 1 ;;
      esac
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      _fa_require_allowed_host "$_FA_API_BASE" || exit 1
      _fa_token || exit 1
      command -v curl >/dev/null 2>&1 || { _fa_err "curl not found — required for REST calls"; exit 1; }
      # Same redirect-leak hardening as _fa_api_get: refuse redirects and pin to
      # https so the operator PAT never rides a cross-host redirect.
      curl -fsS --proto '=https' --proto-redir '=https' --max-redirs 0 -X PATCH \
        -H "Authorization: token ${_FA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"state":"closed"}' \
        "$_FA_API_BASE/repos/$_FA_SLUG/issues/$3"
      ;;
    # ── PR label state-machine ops (issue #1239) ──────────────────────────────

    pr-label-status)
      # Print "reviewing=<bool> reviewed=<bool>" for the SGE gate labels on a PR.
      # Mirrors pr-labels.sh label_status output contract exactly.           (read)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] \
        || _fa_usage 'pr-label-status needs <origin-url-or-owner/name> <pr-num>'
      case "$3" in ''|*[!0-9]*) _fa_err "invalid PR number '$3'"; exit 1 ;; esac
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      local _labels_json _reviewing _reviewed _n
      _labels_json=$(_fa_pr_labels_json "$_FA_API_BASE" "$_FA_SLUG" "$3") || exit 1
      _reviewing=false; _reviewed=false
      while IFS= read -r _n; do
        [ "$_n" = "pr-reviewing" ] && _reviewing=true
        [ "$_n" = "pr-reviewed" ]  && _reviewed=true
      done < <(printf '%s\n' "${_labels_json:-[]}" | jq -r '.[].name' 2>/dev/null | tr -d '\r')
      printf 'reviewing=%s reviewed=%s\n' "$_reviewing" "$_reviewed"
      ;;

    pr-fix-claim-status)
      # Print "fixing=<bool>" for the pr-fixing claim label.                  (read)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] \
        || _fa_usage 'pr-fix-claim-status needs <origin-url-or-owner/name> <pr-num>'
      case "$3" in ''|*[!0-9]*) _fa_err "invalid PR number '$3'"; exit 1 ;; esac
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      local _labels_json _fixing _n
      _labels_json=$(_fa_pr_labels_json "$_FA_API_BASE" "$_FA_SLUG" "$3") || exit 1
      _fixing=false
      while IFS= read -r _n; do
        [ "$_n" = "pr-fixing" ] && _fixing=true
      done < <(printf '%s\n' "${_labels_json:-[]}" | jq -r '.[].name' 2>/dev/null | tr -d '\r')
      printf 'fixing=%s\n' "$_fixing"
      ;;

    pr-is-draft)
      # Print "true" or "false" for a PR's draft state.                       (read)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] \
        || _fa_usage 'pr-is-draft needs <origin-url-or-owner/name> <pr-num>'
      case "$3" in ''|*[!0-9]*) _fa_err "invalid PR number '$3'"; exit 1 ;; esac
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      _fa_api_get "$_FA_API_BASE" "/repos/$_FA_SLUG/pulls/$3" \
        | jq -r 'if .draft == true then "true" else "false" end' 2>/dev/null
      ;;

    pr-head-sha)
      # Print the PR's current HEAD commit SHA.                               (read)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] \
        || _fa_usage 'pr-head-sha needs <origin-url-or-owner/name> <pr-num>'
      case "$3" in ''|*[!0-9]*) _fa_err "invalid PR number '$3'"; exit 1 ;; esac
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      _fa_api_get "$_FA_API_BASE" "/repos/$_FA_SLUG/pulls/$3" \
        | jq -r '.head.sha // empty' 2>/dev/null
      ;;

    pr-body)
      # Print the PR body text (used by assert_followups_preserved).          (read)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] \
        || _fa_usage 'pr-body needs <origin-url-or-owner/name> <pr-num>'
      case "$3" in ''|*[!0-9]*) _fa_err "invalid PR number '$3'"; exit 1 ;; esac
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      _fa_api_get "$_FA_API_BASE" "/repos/$_FA_SLUG/pulls/$3" \
        | jq -r '.body // ""' 2>/dev/null
      ;;

    pr-commit-status)
      # Print the combined Gitea commit status for <sha>:
      #   success | pending | failure | none                              (read)
      # Aggregation (traffic-light), aligned with the fpr_checks normaliser in
      # skills/lib/forgejo-pr-read.sh (#1439) so both adapters agree on 'warning':
      #   any failure/error         → failure
      #   any pending               → pending
      #   otherwise (success and/or warning, all non-blocking) → success
      #   empty list                → none
      # 'warning' is Gitea's NON-BLOCKING neutral — it must never read as
      # 'failure' (it wouldn't block a merge in Gitea) but it also must not, on
      # its own, be the reason a red gate reads green: failure/error are checked
      # FIRST, so warning only ever contributes to a success rollup once nothing
      # is actually failing. (The previous `select(.state=="success") | length
      # == length` was a self-comparison tautology that always fired once
      # failure/pending were excluded, silently mapping a warning-only head to
      # success — the arm-merge-while-not-green class, #885.)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] \
        || _fa_usage 'pr-commit-status needs <origin-url-or-owner/name> <sha>'
      # Validate SHA (hex, 7–40) before URL interpolation — same bound as
      # pr-statuses, so a stray/oversized token can't reach the statuses path.
      case "$3" in *[!0-9A-Fa-f]*) _fa_err "invalid SHA '$3' — must be a hex string"; exit 1 ;; esac
      if [ "${#3}" -lt 7 ] || [ "${#3}" -gt 40 ]; then
        _fa_err "invalid SHA '$3' — must be 7–40 hex chars"; exit 1
      fi
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      local _raw _state
      _raw=$(_fa_api_get "$_FA_API_BASE" "/repos/$_FA_SLUG/commits/$3/statuses?limit=50") || exit 1
      _state=$(printf '%s' "$_raw" | jq -r '
        if length == 0 then "none"
        elif [.[] | select(.state == "failure" or .state == "error")] | length > 0 then "failure"
        elif [.[] | select(.state == "pending")] | length > 0 then "pending"
        elif [.[] | select(.state != "success" and .state != "warning")] | length > 0 then "unknown"
        else "success"
        end' 2>/dev/null) || _state="unknown"
      printf '%s\n' "$_state"
      ;;

    pr-ensure-label)
      # Idempotent + appearance-converging.                               (MUTATING)
      # Create the label if it does not exist. If a label with this name already
      # exists but its color OR description has drifted from the requested
      # values, PATCH it (PATCH /repos/{slug}/labels/{id}) so both hosts converge
      # on the requested appearance — parity with the GitHub path, where
      # `gh label create --force` (pr-labels.sh ensure_labels) re-asserts
      # color+description on every call (#1441). An already-matching label is
      # left untouched — no needless write. The merge gate keys on the label
      # NAME either way, so gate correctness never depended on this; the PATCH is
      # purely to stop the two hosts diverging when a pre-existing label drifted.
      # Args: <origin> <label-name> <color-without-#> <description>
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] && [ -n "${5:-}" ] \
        || _fa_usage 'pr-ensure-label needs <origin> <label-name> <color> <description>'
      _fa_require_write "pr-ensure-label" || exit 1
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      # Look the label up as a full record so we can compare its appearance.
      local _lbl _lbl_id _lbl_color _lbl_desc
      if _lbl=$(_fa_find_label "$_FA_API_BASE" "$_FA_SLUG" "$3"); then
        _lbl_id=$(printf '%s' "$_lbl" | jq -r '.id')
        # The requested color arg ($4) is bare hex; Gitea returns the stored
        # color with a leading '#'. Strip a leading '#' from the stored value so
        # the comparison is bare-hex vs bare-hex regardless of Gitea version.
        _lbl_color=$(printf '%s' "$_lbl" | jq -r '.color // ""'); _lbl_color=${_lbl_color#\#}
        _lbl_desc=$(printf '%s' "$_lbl" | jq -r '.description // ""')
        if [ "$_lbl_color" = "$4" ] && [ "$_lbl_desc" = "$5" ]; then
          return 0   # appearance already matches — no needless write
        fi
        # Drifted — re-assert color + description (parity with gh --force).
        _fa_api_post PATCH "$_FA_API_BASE" "/repos/$_FA_SLUG/labels/$_lbl_id" \
          "{\"color\":$(printf '#%s' "$4" | jq -Rs .),\
\"description\":$(printf '%s' "$5" | jq -Rs .)}" >/dev/null
        return 0
      fi
      # Not found — create it. jq -Rs . encodes the value as a JSON string.
      _fa_api_post POST "$_FA_API_BASE" "/repos/$_FA_SLUG/labels" \
        "{\"name\":$(printf '%s' "$3" | jq -Rs .),\
\"color\":$(printf '#%s' "$4" | jq -Rs .),\
\"description\":$(printf '%s' "$5" | jq -Rs .)}" >/dev/null
      ;;

    pr-add-label)
      # Add a label to a PR by name. The label must already exist in the repo;
      # run pr-ensure-label first. Gitea silently ignores already-applied labels.
      # Args: <origin> <pr-num> <label-name>                             (MUTATING)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] \
        || _fa_usage 'pr-add-label needs <origin> <pr-num> <label-name>'
      case "$3" in ''|*[!0-9]*) _fa_err "invalid PR number '$3'"; exit 1 ;; esac
      _fa_require_write "pr-add-label" || exit 1
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      local _label_id
      _label_id=$(_fa_find_label_id "$_FA_API_BASE" "$_FA_SLUG" "$4") || {
        _fa_err "label '$4' not found in repo '$_FA_SLUG' — run pr-ensure-label first"
        exit 1
      }
      _fa_api_post POST "$_FA_API_BASE" "/repos/$_FA_SLUG/issues/$3/labels" \
        "{\"labels\":[$_label_id]}" >/dev/null
      ;;

    pr-remove-label)
      # Remove a label from a PR by name. Idempotent: no error when the label
      # is absent from the repo or not attached to this PR.
      # Args: <origin> <pr-num> <label-name>                             (MUTATING)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] \
        || _fa_usage 'pr-remove-label needs <origin> <pr-num> <label-name>'
      case "$3" in ''|*[!0-9]*) _fa_err "invalid PR number '$3'"; exit 1 ;; esac
      _fa_require_write "pr-remove-label" || exit 1
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      # Look for the label IN the PR's current label list — this tells us both
      # whether it is attached AND gives us the ID in one read. If it is not in
      # the list, there is nothing to do (idempotent).
      local _pr_labels_json _label_id
      _pr_labels_json=$(_fa_pr_labels_json "$_FA_API_BASE" "$_FA_SLUG" "$3") || exit 1
      _label_id=$(printf '%s' "${_pr_labels_json:-[]}" \
        | jq -r --arg n "$4" '.[] | select(.name == $n) | .id' 2>/dev/null)
      if [ -z "$_label_id" ] || [ "$_label_id" = "null" ]; then
        return 0   # label not attached — idempotent
      fi
      _fa_api_delete "$_FA_API_BASE" "/repos/$_FA_SLUG/issues/$3/labels/$_label_id"
      ;;

    pr-merge-squash)
      # Squash-merge a PR, PINNED to an expected head SHA.               (MUTATING)
      # Args: <origin> <pr-num> <head-sha>
      # <head-sha> is REQUIRED and sent as Gitea's head_commit_id: Gitea refuses
      # the merge if the PR head has moved since <head-sha>, closing a TOCTOU
      # race — GitHub's queued `--auto` re-checks server-side, but this direct
      # POST would otherwise squash-merge whatever HEAD happens to be at POST
      # time, so a push landing between the caller's convergence check and this
      # call could merge unreviewed code. The caller (pr-labels.sh) passes the
      # convergence-checked head; if it drifts, Gitea returns an error and we
      # fail loud rather than merge the wrong commit.
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] \
        || _fa_usage 'pr-merge-squash needs <origin> <pr-num> <head-sha>'
      case "$3" in ''|*[!0-9]*) _fa_err "invalid PR number '$3'"; exit 1 ;; esac
      case "$4" in *[!0-9A-Fa-f]*) _fa_err "invalid head SHA '$4' — must be hex"; exit 1 ;; esac
      if [ "${#4}" -lt 7 ] || [ "${#4}" -gt 40 ]; then
        _fa_err "invalid head SHA '$4' — must be 7–40 hex chars"; exit 1
      fi
      _fa_require_write "pr-merge-squash" || exit 1
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      _fa_api_post POST "$_FA_API_BASE" "/repos/$_FA_SLUG/pulls/$3/merge" \
        "{\"Do\":\"squash\",\"head_commit_id\":$(printf '%s' "$4" | jq -Rs .)}" >/dev/null
      ;;

    # ── Dispatch-skill verbs (issue #1240) — issue-label CRUD by ID + create-pull.
    # PR/commit reads reuse the canonical list-prs/get-pr/pr-statuses above.
    get-label)
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || _fa_usage 'get-label needs <origin-url-or-owner/name> <name>'
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      local label_name="$3" label_json label_found
      # Gitea paginates labels; fetch up to 50 (sufficient for the agent-lock use-case).
      label_json="$(_fa_api_get "$_FA_API_BASE" "/repos/$_FA_SLUG/labels?limit=50")" || exit 1
      # Extract the object whose "name" field matches exactly; print it and exit 0.
      # We rely on jq if available, with a portable grep fallback.
      if command -v jq >/dev/null 2>&1; then
        label_found="$(printf '%s' "$label_json" | jq -r --arg n "$label_name" '.[] | select(.name == $n)')"
      else
        # Portable jq-less fallback. Split into one label object per line, then
        # let awk compare the name field as a LITERAL string (no regex), so a
        # name containing metacharacters like 'c++' or 'a.b' matches correctly
        # and 'bug' never spuriously matches 'bug-report' (exact-equality, not
        # substring). The name is passed via -v to keep it out of the program
        # text entirely. Gitea emits no embedded quotes in label names.
        label_found="$(printf '%s' "$label_json" \
          | sed 's/},{/}\n{/g' \
          | awk -v want="$label_name" '
              {
                if (match($0, /"name":"[^"]*"/)) {
                  nm = substr($0, RSTART + 8, RLENGTH - 9)   # strip "name":" ... "
                  if (nm == want) { print; exit }
                }
              }')"
      fi
      [ -n "$label_found" ] || { _fa_err "label '$label_name' not found in $2"; exit 1; }
      printf '%s\n' "$label_found"
      ;;
    create-label)
      # MUTATING — gated behind the write boundary.
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] \
        || _fa_usage 'create-label needs <origin-url-or-owner/name> <name> <color> [<description>]'
      _fa_require_write "create-label" || exit 1
      local cl_name="$3" cl_color="${4#\#}" cl_desc="${5:-}"   # strip leading '#' if present
      # Validate color: must be 6 hex digits.
      case "$cl_color" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) : ;;
        *) _fa_err "invalid color '$4' — expected 6 hex digits (with or without leading '#')"; exit 1 ;;
      esac
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      _fa_require_allowed_host "$_FA_API_BASE" || exit 1
      _fa_token || exit 1
      command -v curl >/dev/null 2>&1 || { _fa_err "curl not found — required for REST calls"; exit 1; }
      local cl_body
      if command -v jq >/dev/null 2>&1; then
        cl_body="$(jq -n --arg n "$cl_name" --arg c "#${cl_color}" --arg d "$cl_desc" \
          '{name:$n,color:$c,description:$d}')"
      else
        # jq-less fallback — encode free-text name/description through
        # _fa_json_str so a '"' or '\' cannot inject sibling keys. color is
        # already validated to 6 hex digits, so its interpolation is safe.
        cl_body='{"name":'"$(_fa_json_str "$cl_name")"',"color":"#'"$cl_color"'","description":'"$(_fa_json_str "$cl_desc")"'}'
      fi
      curl -fsS --proto '=https' --proto-redir '=https' --max-redirs 0 -X POST \
        -H "Authorization: token ${_FA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$cl_body" \
        "$_FA_API_BASE/repos/$_FA_SLUG/labels"
      ;;
    add-label)
      # MUTATING — gated behind the write boundary.
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] \
        || _fa_usage 'add-label needs <origin-url-or-owner/name> <issue-index> <label-id>'
      _fa_require_write "add-label" || exit 1
      # Validate issue index and label id before URL construction.
      case "$3" in
        ''|*[!0-9]*) _fa_err "invalid issue index '$3' — must be a positive integer"; exit 1 ;;
      esac
      case "$4" in
        ''|*[!0-9]*) _fa_err "invalid label id '$4' — must be a positive integer"; exit 1 ;;
      esac
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      _fa_require_allowed_host "$_FA_API_BASE" || exit 1
      _fa_token || exit 1
      command -v curl >/dev/null 2>&1 || { _fa_err "curl not found — required for REST calls"; exit 1; }
      curl -fsS --proto '=https' --proto-redir '=https' --max-redirs 0 -X POST \
        -H "Authorization: token ${_FA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"labels":['"$4"']}' \
        "$_FA_API_BASE/repos/$_FA_SLUG/issues/$3/labels"
      ;;
    remove-label)
      # MUTATING — gated behind the write boundary.
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] \
        || _fa_usage 'remove-label needs <origin-url-or-owner/name> <issue-index> <label-id>'
      _fa_require_write "remove-label" || exit 1
      case "$3" in
        ''|*[!0-9]*) _fa_err "invalid issue index '$3' — must be a positive integer"; exit 1 ;;
      esac
      case "$4" in
        ''|*[!0-9]*) _fa_err "invalid label id '$4' — must be a positive integer"; exit 1 ;;
      esac
      _fa_slug_of "$2" || exit 1
      _fa_api_base_of "$2" "" || exit 1
      _fa_require_allowed_host "$_FA_API_BASE" || exit 1
      _fa_token || exit 1
      command -v curl >/dev/null 2>&1 || { _fa_err "curl not found — required for REST calls"; exit 1; }
      # Gitea uses DELETE /repos/{owner}/{repo}/issues/{index}/labels/{id}
      curl -fsS --proto '=https' --proto-redir '=https' --max-redirs 0 -X DELETE \
        -H "Authorization: token ${_FA_TOKEN}" \
        "$_FA_API_BASE/repos/$_FA_SLUG/issues/$3/labels/$4"
      ;;
    create-pull)
      # MUTATING — gated behind the write boundary.
      [ -n "${2:-}" ] && [ -n "${3:-}" ] && [ -n "${4:-}" ] && [ -n "${5:-}" ] \
        || _fa_usage 'create-pull needs <origin-url-or-owner/name> <head> <base> <title> [--draft]'
      _fa_require_write "create-pull" || exit 1
      local cp_origin="$2" cp_head="$3" cp_base="$4" cp_title="$5" cp_draft="false"
      # Optional --draft flag (position 6).
      [ "${6:-}" = "--draft" ] && cp_draft="true"
      # Validate branch names against a git-ref-safe allow-list — accept only
      # [A-Za-z0-9._/-], and reject the ref-illegal shapes ('..' path traversal,
      # leading/trailing '/', a leading '-' that could be read as a flag). This
      # rejects the JSON-breaking bytes (" \ {) and every shell/URL metacharacter
      # at the door, so a crafted branch can neither inject the payload nor the
      # request path — belt-and-braces with _fa_json_str's string encoding.
      _fa_valid_ref() { # <name> — echoes nothing; returns 0 if git-ref-safe
        case "$1" in
          ''|*[!A-Za-z0-9._/-]*) return 1 ;;   # empty or a disallowed char
          -*|/*|*/) return 1 ;;                 # leading '-'/'/', or trailing '/'
          *..*) return 1 ;;                     # '..' (traversal / illegal ref)
        esac
        return 0
      }
      _fa_valid_ref "$cp_head" || { _fa_err "invalid head branch '$cp_head' — allowed: A-Za-z0-9._/- (no '..', no leading '-' or '/')"; exit 1; }
      _fa_valid_ref "$cp_base" || { _fa_err "invalid base branch '$cp_base' — allowed: A-Za-z0-9._/- (no '..', no leading '-' or '/')"; exit 1; }
      _fa_slug_of "$cp_origin" || exit 1
      _fa_api_base_of "$cp_origin" "" || exit 1
      _fa_require_allowed_host "$_FA_API_BASE" || exit 1
      _fa_token || exit 1
      command -v curl >/dev/null 2>&1 || { _fa_err "curl not found — required for REST calls"; exit 1; }
      # Read the PR body from stdin; default to empty string when stdin is a terminal.
      local cp_body=""
      if [ ! -t 0 ]; then
        cp_body="$(cat)"
      fi
      local cp_payload
      if command -v jq >/dev/null 2>&1; then
        cp_payload="$(jq -n \
          --arg head "$cp_head" --arg base "$cp_base" \
          --arg title "$cp_title" --arg body "$cp_body" \
          --argjson draft "$cp_draft" \
          '{head:$head,base:$base,title:$title,body:$body,draft:$draft}')"
      else
        # jq-less fallback — encode every free-text field through _fa_json_str so
        # a title/body containing '"' or '\' cannot break out of its string and
        # override a sibling key such as "base". head/base are already
        # whitespace-validated but are encoded too for defence in depth; draft is
        # a validated boolean literal, not a string.
        cp_payload='{"head":'"$(_fa_json_str "$cp_head")"',"base":'"$(_fa_json_str "$cp_base")"',"title":'"$(_fa_json_str "$cp_title")"',"body":'"$(_fa_json_str "$cp_body")"',"draft":'"$cp_draft"'}'
      fi
      curl -fsS --proto '=https' --proto-redir '=https' --max-redirs 0 -X POST \
        -H "Authorization: token ${_FA_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$cp_payload" \
        "$_FA_API_BASE/repos/$_FA_SLUG/pulls"
      ;;

    -h|--help|help|'')
      _fa_usage
      ;;
    *)
      _fa_usage "unknown command '$cmd'"
      ;;
  esac
}

_fa_main "$@"
