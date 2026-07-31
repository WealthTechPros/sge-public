#!/usr/bin/env bash
# issue-write.sh — host/ALM-aware MUTATING issue operations (SPEC-105 S3, #1701).
# The write-path analogue of scripts/issue-read.sh (S2): the single seam every
# dispatch skill routes tracker-side WRITES through, so a Jira-tracked repo's
# claim notices, triage/exit-report comments, decomposition children, and
# close-on-merge linkage land on the RIGHT backend instead of a `gh` call that
# has nothing to write to.
#
# The ALM (issue-tracker) backend is resolved FIRST, via scripts/with-repo-cwd.sh
# alm (SGD_ALM_BACKEND) — a repo may be GitHub-HOSTED yet track its work in Jira,
# so the tracker is orthogonal to the git host:
#
#   github (unset/empty)  delegate to `gh` — byte-identical to before this seam
#                         existed; the ALM dimension is dark until a repo
#                         declares a non-GitHub tracker (SPEC-105 §3).
#   jira                  route P5 comment-item / P6 create-item / P8
#                         link-close-on-merge through scripts/jira-adapter.sh.
#                         This seam IS the write opt-in: it sets
#                         JIRA_ADAPTER_ALLOW_WRITE=1 for its adapter calls
#                         (unlike issue-read.sh, which never does). It does NOT
#                         set JIRA_ADAPTER_ALLOW_CREATE — that scope gate (DP3)
#                         stays the caller's/environment's explicit decision, so
#                         the common-case dispatch token cannot create items.
#   unrecognised          FAIL LOUD naming the value (DR1); issue NO gh call and
#                         NO Jira REST call — never a silent GitHub write against
#                         the wrong tracker.
#
# Read-only issue ops (list/view) stay on scripts/issue-read.sh ($IR); this seam
# is the mutating counterpart. Keeping the two seams separate is what lets the
# read path assert (statically) that it never sets the write-allow flag.
#
# Usage:
#   issue-write.sh comment <issueRef> <body>
#       Append a comment (claim notice, triage, exit report). P5 on Jira.
#   issue-write.sh create <title> <body>
#       Open a new work item. On Jira (P6) the project is SGD_JIRA_PROJECT and
#       the caller MUST have set JIRA_ADAPTER_ALLOW_CREATE=1 (DP3 scope gate).
#       Prints the new item's BARE REF on stdout — an integer issue number on
#       GitHub, an issueKey (PROJ-123) on Jira — so it can be piped straight
#       into `comment`/`close-link`. Treat it as opaque; never parse as an int.
#   issue-write.sh close-link <issueRef> <change-url>
#       Express "merging this change closes item N". On GitHub close-on-merge is
#       DECLARATIVE — this prints the `Closes #N` token for the caller to embed
#       in the PR body (this seam does not edit the PR). On Jira (P8) it records
#       the merge as a remote link on the item (+ optional close transition).
# END_USAGE
#
# SPEC-057: always run from the target repo's checkout cwd — shell state does
# NOT persist across agent tool calls, so re-enter the resolved cwd (and
# re-derive $IW) at the top of every shell call, exactly as for with-repo-cwd.sh
# / issue-read.sh. This script classifies the host and ALM backend from the
# current cwd's `origin` remote; a wrong cwd means the wrong tracker.
#
# ALM / Jira config is the jira-adapter's (SGD_ALM_BACKEND, SGD_JIRA_BASE_URL,
# SGD_JIRA_HOSTS, SGD_JIRA_BEARER or SGD_JIRA_EMAIL + SGD_JIRA_API_TOKEN,
# SGD_JIRA_PROJECT, SGD_JIRA_CLOSE_TRANSITION_ID, JIRA_ADAPTER_ALLOW_CREATE) —
# see scripts/jira-adapter.sh. A missing credential or unlisted host fails loud
# before any network call.

set -euo pipefail

_IW_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_JA="${_IW_SCRIPT_DIR}/jira-adapter.sh"
_WRC="${_IW_SCRIPT_DIR}/with-repo-cwd.sh"

_iw_err() { printf 'issue-write: error: %s\n' "$*" >&2; }

# On the GitHub backend an issue ref is a positive integer. Validate it before
# it reaches `gh` so a flag-shaped ref ('--foo', '-X') can never be parsed as a
# gh option (option-injection) — the Jira path already validates the issueKey
# character class in the adapter.
_iw_require_github_ref() { # <ref>
  case "$1" in
    ''|*[!0-9]*)
      _iw_err "invalid GitHub issue ref '$1' — must be a positive integer"
      return 1
      ;;
  esac
}

# Resolve the declared ALM backend at the resolver seam. Prints `github`|`jira`;
# propagates the resolver's fail-loud non-zero for an unrecognised backend (DR1)
# — stderr (naming the value) is NOT swallowed, so the caller stops before any
# write. Never a silent GitHub fallback.
_iw_alm() { "$_WRC" alm | tr -d '\n'; }

# Classify the current checkout's git host: github | forgejo | unknown.
_iw_host() { "$_WRC" host 2>/dev/null | tr -d '\n' || printf 'unknown'; }

# On the github ALM backend, mutating tracker ops are wired for the github git
# host only. Forgejo/Gitea tracker WRITES are SPEC-094 scope, deliberately not
# routed by this S3 seam — fail loud rather than mis-route.
_iw_github_host_only() {
  local host
  host="$(_iw_host)"
  case "$host" in
    github) return 0 ;;
    *)
      _iw_err "host kind '${host}' has no mutating issue-write adapter — SPEC-105 S3 wires the github (gh) and jira backends; forgejo/gitea tracker writes are SPEC-094 scope, not routed here"
      return 1
      ;;
  esac
}

_iw_usage() {
  # `if`, not `[ -n … ] && …`: the short-circuit form returns non-zero when the
  # arg is empty, which would abort the caller under `set -e` if this ever
  # stopped being followed by `exit 2`.
  if [ -n "${1:-}" ]; then _iw_err "$1"; fi
  # awk, not sed: BSD/macOS sed rejects the `{ /re/d; p }` one-liner address form
  # ("extra characters at the end of p command"), the same trap fixed for the
  # sibling adapters in #1676.
  awk '/^# END_USAGE/{exit} f{sub(/^# ?/,""); print} /^# Usage:/{f=1; sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}" >&2
  exit 2
}

_iw_main() {
  local cmd="${1:-}"
  case "$cmd" in
    comment)
      # P5 — append a comment. ALM backend FIRST (fail loud on unrecognised).
      local ref="${2:-}" body="${3:-}"
      { [ -n "$ref" ] && [ "$#" -ge 3 ]; } || _iw_usage 'comment needs <issueRef> <body>'
      local alm
      alm="$(_iw_alm)" || exit 1
      if [ "$alm" = "jira" ]; then
        JIRA_ADAPTER_ALLOW_WRITE=1 bash "$_JA" comment-item "$ref" "$body"
      else
        _iw_github_host_only || exit 1
        _iw_require_github_ref "$ref" || exit 1
        gh issue comment "$ref" --body "$body"
      fi
      ;;
    create)
      # P6 — open a new work item. On Jira the DP3 create opt-in must already be
      # in the environment (this seam only supplies the write opt-in, never the
      # create one).
      local title="${2:-}" body="${3:-}"
      { [ -n "$title" ] && [ "$#" -ge 3 ]; } || _iw_usage 'create needs <title> <body>'
      local alm
      alm="$(_iw_alm)" || exit 1
      # Both backends print the SAME thing: the new item's bare REF on stdout —
      # an integer issue number on GitHub, an issueKey (PROJ-123) on Jira — so a
      # caller can pipe `create` straight into `comment`/`close-link` without
      # knowing the backend. The raw forms differ (Jira returns a REST body,
      # `gh` returns a URL), so each is normalised here rather than at every
      # call site.
      local _created _ref
      if [ "$alm" = "jira" ]; then
        local project="${SGD_JIRA_PROJECT:-}"
        [ -n "$project" ] || { _iw_err "no Jira project key — set SGD_JIRA_PROJECT (the project create-item opens into)"; exit 1; }
        _created="$(JIRA_ADAPTER_ALLOW_WRITE=1 bash "$_JA" create-item "$project" "$title" "$body")" || exit 1
        command -v jq >/dev/null 2>&1 || { _iw_err "jq not found — required to read the created item's key from the Jira response"; exit 1; }
        _ref="$(printf '%s' "$_created" | jq -er '.key' 2>/dev/null)" || {
          _iw_err "create: Jira response carried no .key — the item may or may not exist; response: $(printf '%s' "$_created" | head -c 300)"; exit 1; }
      else
        _iw_github_host_only || exit 1
        _created="$(gh issue create --title "$title" --body "$body")" || exit 1
        # Strip CR explicitly: on Windows/msys `gh` emits CRLF, and $(...) removes
        # only the trailing LF — the surviving CR would ride along inside the ref
        # and fail the digit class below (or, worse, reach a later call).
        _created="$(printf '%s' "$_created" | tr -d '\r')"
        # `gh issue create` prints the new issue's URL; the ref is its last path
        # segment. Validated so a surprising output shape fails loud rather than
        # returning a non-ref that a later `comment` would misuse.
        _ref="${_created##*/}"
        case "$_ref" in
          ''|*[!0-9]*)
            _iw_err "create: could not parse an issue number from gh output '$_created'"; exit 1 ;;
        esac
      fi
      printf '%s\n' "$_ref"
      ;;
    close-link)
      # P8 — express close-on-merge. GitHub is DECLARATIVE (`Closes #N` in the PR
      # body); Jira has no native PR link, so the adapter records a remote link.
      local ref="${2:-}" url="${3:-}"
      { [ -n "$ref" ] && [ -n "$url" ]; } || _iw_usage 'close-link needs <issueRef> <change-url>'
      local alm
      alm="$(_iw_alm)" || exit 1
      if [ "$alm" = "jira" ]; then
        JIRA_ADAPTER_ALLOW_WRITE=1 bash "$_JA" link-close-on-merge "$ref" "$url"
      else
        _iw_github_host_only || exit 1
        _iw_require_github_ref "$ref" || exit 1
        # No imperative GitHub call — close-on-merge is expressed as `Closes #N`
        # in the PR body. Emit the token for the caller to embed; this seam does
        # not edit the PR.
        printf 'Closes #%s\n' "$ref"
      fi
      ;;
    -h|--help|help|'')
      _iw_usage
      ;;
    *)
      _iw_usage "unknown command '$cmd'"
      ;;
  esac
}

_iw_main "$@"
