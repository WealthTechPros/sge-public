#!/usr/bin/env bash
# azdo-gh-pr.sh — host dispatch for `gh pr` reads (SPEC-110 S4, issue #2985).
#
# SOURCE it. It defines functions only: no `set` options, no side effects, so
# it is safe inside review-lib.sh / monitor-lib.sh, which deliberately run
# without `set -e` (the caller's shell options are never touched).
#
#   sge_gh_pr <gh-pr-args...>
#     Any host other than Azure Repos: runs `gh pr <args...>` EXACTLY — same
#     argv, same stdout, same exit status. GitHub behaviour is byte-for-byte
#     what it was before this file existed.
#     Azure Repos (`with-repo-cwd.sh host` classification of the cwd's origin
#     == azdo): emulates the gh read verbs over scripts/azdo-adapter.sh:
#       view   <n> [--json f,..] [--jq expr]      gh-shaped PR object
#       diff   <n> [--name-only]                  unified diff | changed paths
#       checks <n> [--json f,..] [--jq expr]      DP5-reduced check rows; exit
#                                                 0 green, 1 failing, 8 pending
#                                                 (gh's own exit convention)
#       list   [--state open] [--json f,..] [--jq expr] [--limit n]
#     --repo/-R must name the cwd's own Azure Repos repo (org/project/repo) or
#     is refused. Every other subcommand, flag or field fails closed: nothing on
#     an Azure Repos PR is ever silently sent to `gh`.
#   sge_repo_slug
#     `org/project/repo` of the cwd's Azure Repos origin (azdo only).
#   sge_pr_host
#     the cached host kind of the cwd's origin.
#   sge_pr_post_comment <pr> <body>
#   sge_pr_marker_count <pr> <marker>
#   sge_pr_comments_json <pr>
#     The PR-comment helpers (#2989). GitHub: EXACTLY the `gh pr comment` /
#     `gh api --paginate .../issues/N/comments` calls the monitor and review lanes
#     always made. Azure Repos: the adapter's pr-comment (a closed thread; the
#     write opt-in is set for that one call only) and pr-comments, so a stall
#     notice or marker lookup never goes to a `gh` that cannot see the repo.
#
# The DP5 contract (SPEC-110 §2.4, DR8): `checks` always ends with an
# `sge/ci-gate` row that is FAILURE for both not-green states, so a caller that
# counts FAILURE rows can never read indeterminate CI as zero failures.

_SGE_GHPR_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
_SGE_GHPR_AA="$_SGE_GHPR_ROOT/scripts/azdo-adapter.sh"
_SGE_GHPR_WRC="$_SGE_GHPR_ROOT/scripts/with-repo-cwd.sh"
_SGE_GHPR_HOST=""
_SGE_GHPR_HOST_DIR=""

_sge_ghpr_err() { printf 'sge_gh_pr: error: %s\n' "$*" >&2; }

# Host kind of the cwd's origin, cached per working directory. No origin, no
# checkout, or no classifier -> `unknown`, which routes to plain `gh` (the
# pre-#2985 behaviour), never to the Azure path.
sge_pr_host() {
  if [ -z "$_SGE_GHPR_HOST" ] || [ "$_SGE_GHPR_HOST_DIR" != "$PWD" ]; then
    local url=""
    url="$(git remote get-url origin 2>/dev/null)" || url=""
    _SGE_GHPR_HOST="unknown"
    if [ -n "$url" ] && [ -f "$_SGE_GHPR_WRC" ]; then
      _SGE_GHPR_HOST="$( . "$_SGE_GHPR_WRC" && _wrc_host_kind "$(_wrc_url_host "$url")" 2>/dev/null)" || _SGE_GHPR_HOST="unknown"
      [ -n "$_SGE_GHPR_HOST" ] || _SGE_GHPR_HOST="unknown"
    fi
    _SGE_GHPR_HOST_DIR="$PWD"
  fi
  printf '%s' "$_SGE_GHPR_HOST"
}

sge_gh_pr() {
  if [ "$(sge_pr_host)" = azdo ]; then
    _sge_ghpr_azdo "$@"
  else
    gh pr "$@"
  fi
}

sge_repo_slug() {
  local origin
  origin="$(git remote get-url origin 2>/dev/null)" || { _sge_ghpr_err "no origin remote"; return 1; }
  bash "$_SGE_GHPR_AA" repo-id "$origin"
}

_SGE_GHPR_VIEW_FIELDS=" number title body state isDraft headRefName baseRefName headRefOid baseRefOid mergeable author labels createdAt closedAt url files commits "
_SGE_GHPR_CHECK_FIELDS=" name state bucket link startedAt completedAt workflow description detailsUrl status conclusion sgeGate "

_sge_ghpr_fields_ok() { # <csv> <allowed-list>
  local f
  case "$1" in ''|*[!A-Za-z,]*|,*|*,|*,,*) _sge_ghpr_err "invalid --json field list '$1'"; return 1 ;; esac
  for f in ${1//,/ }; do
    case "$2" in *" $f "*) ;; *) _sge_ghpr_err "--json field '$f' is not available on an Azure Repos PR (SPEC-110 S4)"; return 1 ;; esac
  done
}

# Project an object or array to the requested fields, then apply --jq (raw
# output, as gh's --jq prints).
_sge_ghpr_shape() { # <fields-or-empty> <jq-or-empty>  (stdin JSON)
  local data
  data="$(cat)" || return 1
  if [ -n "$1" ]; then
    data="$(printf '%s' "$data" | jq -c --arg f "$1" '
      def pick($o): reduce ($f | split(","))[] as $k ({}; . + {($k): $o[$k]});
      if type == "array" then map(pick(.)) else pick(.) end')" || return 1
  fi
  if [ -n "$2" ]; then
    printf '%s' "$data" | jq -r "$2"
  else
    printf '%s\n' "$data"
  fi
}

_sge_ghpr_azdo() {
  local sub="${1:-}"
  [ "$#" -gt 0 ] && shift
  local num="" json="" jqx="" nameonly=0 repo="" state="open"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo|-R|--json|--jq|-q|--state|-s|--limit|-L)
        [ "$#" -ge 2 ] || { _sge_ghpr_err "$1 needs a value"; return 1; }
        case "$1" in
          --repo|-R) repo="$2" ;;
          --json) json="$2" ;;
          --jq|-q) jqx="$2" ;;
          --state|-s) state="$2" ;;
        esac
        shift 2 ;;
      --name-only) nameonly=1; shift ;;
      -*) _sge_ghpr_err "gh pr $sub: flag '$1' is not supported on an Azure Repos PR — refusing rather than calling gh"; return 1 ;;
      *)
        [ -z "$num" ] || { _sge_ghpr_err "gh pr $sub: unexpected argument '$1'"; return 1; }
        num="$1"; shift ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || { _sge_ghpr_err "jq is required on an Azure Repos PR"; return 1; }
  local origin slug
  origin="$(git remote get-url origin 2>/dev/null)" || { _sge_ghpr_err "no origin remote"; return 1; }
  if [ -n "$repo" ]; then
    slug="$(bash "$_SGE_GHPR_AA" repo-id "$origin")" || return 1
    [ "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" ] \
      || { _sge_ghpr_err "--repo '$repo' is not this checkout's Azure Repos repo ($slug) — refusing"; return 1; }
  fi
  case "$sub" in
    view|diff|checks)
      case "$num" in ''|*[!0-9]*) _sge_ghpr_err "gh pr $sub: needs a numeric PR id on Azure Repos (got '$num')"; return 1 ;; esac ;;
  esac
  case "$sub" in
    view)
      [ -z "$json" ] || _sge_ghpr_fields_ok "$json" "$_SGE_GHPR_VIEW_FIELDS" || return 1
      local obj extra
      obj="$(bash "$_SGE_GHPR_AA" get-pr "$origin" "$num")" || return 1
      case ",$json," in
        *,files,*)
          extra="$(bash "$_SGE_GHPR_AA" pr-files "$origin" "$num")" || return 1
          obj="$(printf '%s' "$obj" | jq -c --arg f "$extra" '. + {files: ($f | split("\n") | map(select(length > 0)) | map({path: ., additions: null, deletions: null}))}')" || return 1 ;;
      esac
      case ",$json," in
        *,commits,*)
          extra="$(bash "$_SGE_GHPR_AA" pr-commits "$origin" "$num")" || return 1
          obj="$(printf '%s' "$obj" | jq -c --argjson c "$extra" '. + {commits: $c}')" || return 1 ;;
      esac
      printf '%s' "$obj" | _sge_ghpr_shape "$json" "$jqx"
      ;;
    diff)
      [ -z "$json$jqx" ] || { _sge_ghpr_err "gh pr diff takes no --json/--jq"; return 1; }
      if [ "$nameonly" = 1 ]; then
        bash "$_SGE_GHPR_AA" pr-files "$origin" "$num"
      else
        bash "$_SGE_GHPR_AA" pr-diff "$origin" "$num"
      fi
      ;;
    checks)
      [ -z "$json" ] || _sge_ghpr_fields_ok "$json" "$_SGE_GHPR_CHECK_FIELDS" || return 1
      local ci gate rc
      ci="$(bash "$_SGE_GHPR_AA" pr-ci "$origin" "$num")" || return 1
      gate="$(printf '%s' "$ci" | jq -r '.result' | tr -d '\r')"
      printf '%s' "$ci" | jq -c '.checks' | _sge_ghpr_shape "$json" "$jqx" || return 1
      case "$gate" in
        green) rc=0 ;;
        not-green-indeterminate) rc=8 ;;
        *) rc=1 ;;
      esac
      return "$rc"
      ;;
    list)
      [ "$state" = open ] || { _sge_ghpr_err "gh pr list --state $state is not supported on Azure Repos (open only)"; return 1; }
      [ -z "$num" ] || { _sge_ghpr_err "gh pr list takes no PR id"; return 1; }
      [ -z "$json" ] || _sge_ghpr_fields_ok "$json" "$_SGE_GHPR_VIEW_FIELDS" || return 1
      case ",$json," in *,files,*|*,commits,*) _sge_ghpr_err "gh pr list: files/commits are per-PR fields — use view"; return 1 ;; esac
      # Captured, never piped: a failed list must not reach jq as empty input
      # and come out as a confident "no open PRs".
      local arr
      arr="$(bash "$_SGE_GHPR_AA" list-prs "$origin" --gh)" || return 1
      printf '%s' "$arr" | _sge_ghpr_shape "$json" "$jqx"
      ;;
    *)
      _sge_ghpr_err "gh pr $sub is not supported on an Azure Repos PR (SPEC-110 S4) — refusing rather than calling gh"
      return 1
      ;;
  esac
}

# --- PR comment helpers (#2989) ----------------------------------------------
# Post a PR comment. Exit status is the post's own; the output is discarded (as
# every caller already did with `>/dev/null 2>&1`).
sge_pr_post_comment() { # <pr> <body>
  if [ "$(sge_pr_host)" != azdo ]; then
    gh pr comment "$1" --body "$2" >/dev/null 2>&1
    return
  fi
  local origin f rc=0
  origin="$(git remote get-url origin 2>/dev/null)" || return 1
  f="$(mktemp "${TMPDIR:-/tmp}/sge-azdo-comment.XXXXXX")" || return 1
  printf '%s' "$2" > "$f"
  AZDO_ADAPTER_ALLOW_WRITE=1 bash "$_SGE_GHPR_AA" pr-comment "$origin" "$1" "$f" >/dev/null 2>&1 || rc=$?
  rm -f "$f"
  return "$rc"
}

# How many comments contain <marker> (a controlled `<!-- ... -->` string with no
# jq metacharacters). GitHub: the paginated gh-api count, unreadable -> 0 (as it
# always was). Azure Repos: an UNREADABLE comment list counts as "already posted"
# (1), so a notice that cannot be de-duplicated is withheld rather than spammed
# every cycle.
sge_pr_marker_count() { # <pr> <marker>
  if [ "$(sge_pr_host)" != azdo ]; then
    gh api --paginate "repos/{owner}/{repo}/issues/$1/comments" \
      --jq "[.[] | select(.body | contains(\"$2\"))] | length" 2>/dev/null \
      | awk '{s+=$1} END{print s+0}'
    return
  fi
  local origin n
  origin="$(git remote get-url origin 2>/dev/null)" || { echo 1; return 0; }
  n="$(bash "$_SGE_GHPR_AA" pr-comments "$origin" "$1" 2>/dev/null | jq --arg m "$2" '[.[] | select(.body | contains($m))] | length' 2>/dev/null)" || n=""
  [[ "$n" =~ ^[0-9]+$ ]] || n=1
  echo "$n"
}

# The PR's comments as a JSON array in the GitHub issue-comment shape
# ({id, body, user:{login}, created_at}); Azure Repos only (GitHub callers keep
# their own `gh api` pipelines). Non-zero on any read failure.
sge_pr_comments_json() { # <pr>
  local origin
  origin="$(git remote get-url origin 2>/dev/null)" || return 1
  bash "$_SGE_GHPR_AA" pr-comments "$origin" "$1"
}
