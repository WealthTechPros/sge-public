#!/usr/bin/env bash
# forgejo-pr-read.sh — routing shim for read-only PR operations on non-GitHub hosts.
#
# Slice 3 of the #1146 non-GitHub-host epic (#1238). Provides a UNIFIED INTERFACE
# for PR read operations that routes to the Forgejo/Gitea REST adapter when the
# repo's `origin` is a non-GitHub host, and falls back to `gh` for GitHub remotes.
#
# Skills that previously called `gh pr list/view/diff/checks` directly can instead
# source this file and call the corresponding `fpr_*` wrappers — the routing
# decision is hidden behind the seam. MUTATING operations (labels, merges, approvals)
# are NOT in scope here; they remain `gh`-only until a future mutating slice.
#
# Usage (source, then call wrappers):
#   source "${CLAUDE_PLUGIN_ROOT}/skills/lib/forgejo-pr-read.sh"
#   HOST_KIND="$(fpr_host_kind)"   # "github" | "forgejo" | "unknown"
#
#   # List open PRs — JSON array output:
#   #   GitHub path  → gh pr list --state open --json number,title,...
#   #   Forgejo path → forgejo-adapter.sh list-prs <origin-url>
#   fpr_list [--json <fields>]
#
#   # View a single PR — JSON object output:
#   #   GitHub path  → gh pr view <N> --json <fields>
#   #   Forgejo path → forgejo-adapter.sh get-pr <origin-url> <N>
#   fpr_view <pr-index> [--json <fields>]
#
#   # Get PR diff — unified diff on stdout:
#   #   GitHub path  → gh pr diff <N>
#   #   Forgejo path → forgejo-adapter.sh pr-diff <origin-url> <N>
#   fpr_diff <pr-index>
#
#   # Get PR checks / commit statuses — JSON array output:
#   #   GitHub path  → gh pr checks <N> --json ...
#   #   Forgejo path → forgejo-adapter.sh pr-statuses <origin-url> <sha>
#   #                  (sha resolved from `fpr_view` .head.sha)
#   fpr_checks <pr-index>
#
# Environment:
#   CLAUDE_PLUGIN_ROOT    — must be set (standard SGD harness var).
#   FORGEJO_API_TOKEN /
#   GITEA_TOKEN           — required for Forgejo paths (see forgejo-adapter.sh).
#   SGD_FORGEJO_HOSTS /
#   SGD_FORGEJO_DEFAULT_HOST — host allow-list (see forgejo-adapter.sh / ADR-0010).
#   GH_REPO               — optional; overrides the origin-derived repo slug for
#                           GitHub paths (standard SGD convention, #662).
#
# NOTE: shell state does NOT persist across agent tool calls; source this file
# at the top of each tool call where it is needed. See docs/skill-authoring-repo-context.md.

set -euo pipefail

_FPR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FPR_ADAPTER="${CLAUDE_PLUGIN_ROOT:-$_FPR_SCRIPT_DIR/../..}/scripts/forgejo-adapter.sh"
_FPR_WRC="${CLAUDE_PLUGIN_ROOT:-$_FPR_SCRIPT_DIR/../..}/scripts/with-repo-cwd.sh"

_fpr_err()  { printf 'forgejo-pr-read: error: %s\n' "$*" >&2; }

# Resolve and cache the host kind for this shell invocation. Re-sourcing the file
# in the same shell resets it (safe: same repo, same origin, same result).
_FPR_HOST_KIND=""

# fpr_host_kind — print the host kind for the current repo's origin:
#   "github" | "forgejo" | "unknown"
# Uses with-repo-cwd.sh's canonical classifier (the single source of truth for
# the SGD_FORGEJO_HOSTS / SGD_GITHUB_HOSTS allow-list).
fpr_host_kind() {
  if [ -z "$_FPR_HOST_KIND" ]; then
    [ -f "$_FPR_WRC" ] || { _fpr_err "with-repo-cwd.sh not found at $_FPR_WRC"; return 1; }
    _FPR_HOST_KIND="$("$_FPR_WRC" host 2>/dev/null || echo 'unknown')"
  fi
  printf '%s' "$_FPR_HOST_KIND"
}

# Resolve the origin URL of the current repo.
_fpr_origin_url() {
  git remote get-url origin 2>/dev/null || { _fpr_err "no 'origin' remote found"; return 1; }
}

# fpr_list — enumerate open pull requests.
# GitHub path:  gh pr list --state open [--json <fields>]
# Forgejo path: forgejo-adapter.sh list-prs <origin-url>
#
# Output (both paths): JSON array on stdout.
# Optional --json <fields> is passed through to `gh pr list` on the GitHub path;
# on the Forgejo path the full Gitea PR schema is always returned (callers select
# what they need from the JSON array).
fpr_list() {
  local host; host="$(fpr_host_kind)"
  case "$host" in
    github)
      gh pr list --state open "$@"
      ;;
    forgejo)
      local origin; origin="$(_fpr_origin_url)"
      [ -f "$_FPR_ADAPTER" ] || { _fpr_err "forgejo-adapter.sh not found at $_FPR_ADAPTER"; return 1; }
      bash "$_FPR_ADAPTER" list-prs "$origin"
      ;;
    *)
      _fpr_err "unknown host kind '$host' — cannot list PRs (add host to SGD_FORGEJO_HOSTS or SGD_GITHUB_HOSTS)"
      return 1
      ;;
  esac
}

# fpr_view <pr-index> [--json <fields>]
# View a single PR.
# GitHub path:  gh pr view <N> [--json <fields>]
# Forgejo path: forgejo-adapter.sh get-pr <origin-url> <N>
#
# Output (both paths): JSON object on stdout.
fpr_view() {
  local pr="${1:-}"; shift || true
  [ -n "$pr" ] || { _fpr_err "fpr_view: <pr-index> required"; return 1; }
  local host; host="$(fpr_host_kind)"
  case "$host" in
    github)
      gh pr view "$pr" "$@"
      ;;
    forgejo)
      local origin; origin="$(_fpr_origin_url)"
      [ -f "$_FPR_ADAPTER" ] || { _fpr_err "forgejo-adapter.sh not found at $_FPR_ADAPTER"; return 1; }
      bash "$_FPR_ADAPTER" get-pr "$origin" "$pr"
      ;;
    *)
      _fpr_err "unknown host kind '$host' — cannot view PR $pr"
      return 1
      ;;
  esac
}

# fpr_diff <pr-index>
# Fetch the unified diff for a PR (plain text on stdout).
# GitHub path:  gh pr diff <N>
# Forgejo path: forgejo-adapter.sh pr-diff <origin-url> <N>
fpr_diff() {
  local pr="${1:-}"
  [ -n "$pr" ] || { _fpr_err "fpr_diff: <pr-index> required"; return 1; }
  local host; host="$(fpr_host_kind)"
  case "$host" in
    github)
      gh pr diff "$pr"
      ;;
    forgejo)
      local origin; origin="$(_fpr_origin_url)"
      [ -f "$_FPR_ADAPTER" ] || { _fpr_err "forgejo-adapter.sh not found at $_FPR_ADAPTER"; return 1; }
      bash "$_FPR_ADAPTER" pr-diff "$origin" "$pr"
      ;;
    *)
      _fpr_err "unknown host kind '$host' — cannot fetch diff for PR $pr"
      return 1
      ;;
  esac
}

# jq filter mapping ONE Gitea CommitStatus object to the gh `pr checks --json`
# shape that every SGD consumer already understands. The critical field is
# `state`, normalised to gh's UPPERCASE check enum so comparisons in
# monitor-lib.sh (FAILING_CHECK_JQ) and review-lib.sh (rl_pass_gate's
# `.state == "SUCCESS"` etc.) work identically on both hosts.
#
#   Gitea state → gh state (traffic-light):
#     success            → SUCCESS   (green)
#     pending            → PENDING   (in-flight — not failing)
#     warning            → SUCCESS   (Gitea's non-blocking neutral; gh's neutral
#                                     lands in the pass bucket, never FAILURE)
#     failure            → FAILURE   (red)
#     error              → FAILURE   (red — a red check must read as failing, not
#                                     be dropped into a silent "unknown" state)
#     (anything else)    → FAILURE   (fail closed: an unrecognised state is treated
#                                     as failing so a red PR never reads clean)
#
# gh's `name` maps from Gitea's `context`; `detailsUrl` from `target_url`. There
# is no per-check `status`/`conclusion` split in Gitea (state carries both), so
# `conclusion` mirrors the normalised state and `status` is COMPLETED for any
# terminal state, IN_PROGRESS for PENDING.
_FPR_STATUS_NORMALISE='{
  name: (.context // ""),
  state: (
    (.state // "" | ascii_downcase) as $s
    | if   $s == "success" then "SUCCESS"
      elif $s == "pending" then "PENDING"
      elif $s == "warning" then "SUCCESS"
      else "FAILURE" end
  ),
  detailsUrl: (.target_url // ""),
  description: (.description // "")
} | .status = (if .state == "PENDING" then "IN_PROGRESS" else "COMPLETED" end)
  | .conclusion = (if .state == "PENDING" then "" else .state end)'

# fpr_checks <pr-index>
# Get CI check statuses for a PR, normalised to gh's `pr checks --json` shape.
# GitHub path:  gh pr checks <N> --json name,status,conclusion,startedAt,completedAt,detailsUrl
# Forgejo path: resolve the PR head SHA via get-pr, call pr-statuses, then map the
#               raw Gitea CommitStatus array through _FPR_STATUS_NORMALISE so the
#               output `state` is gh's UPPERCASE enum (SUCCESS/PENDING/FAILURE) —
#               NOT the raw lowercase Gitea state. Consumers compare `.state`
#               against gh enums; returning raw lowercase made a red Forgejo PR
#               read clean (issue #1238 follow-up).
#
# Page cap: the Forgejo path lists at most the first 50 commit statuses for the
# head SHA (the adapter's pr-statuses is `?page=1&limit=50`). A head with more
# than 50 distinct check contexts would be truncated; SGD PRs are far below this.
fpr_checks() {
  local pr="${1:-}"
  [ -n "$pr" ] || { _fpr_err "fpr_checks: <pr-index> required"; return 1; }
  local host; host="$(fpr_host_kind)"
  case "$host" in
    github)
      gh pr checks "$pr" --json name,status,conclusion,startedAt,completedAt,detailsUrl
      ;;
    forgejo)
      local origin; origin="$(_fpr_origin_url)"
      [ -f "$_FPR_ADAPTER" ] || { _fpr_err "forgejo-adapter.sh not found at $_FPR_ADAPTER"; return 1; }
      # Resolve the HEAD SHA from the PR object. jq is required here: a grep
      # fallback that scraped the first "sha" in the JSON could return the base
      # ref's SHA (or a nested user/repo sha) — field order is not guaranteed —
      # and silently query checks for the wrong commit. Fail loud if jq is absent.
      command -v jq >/dev/null 2>&1 || { _fpr_err "jq is required to resolve the PR head SHA on a Forgejo host"; return 1; }
      local pr_json sha
      pr_json="$(bash "$_FPR_ADAPTER" get-pr "$origin" "$pr")"
      sha="$(printf '%s' "$pr_json" | jq -r '.head.sha // empty')"
      [ -n "$sha" ] || { _fpr_err "could not resolve head SHA for PR $pr"; return 1; }
      bash "$_FPR_ADAPTER" pr-statuses "$origin" "$sha" \
        | jq "[.[] | ${_FPR_STATUS_NORMALISE}]"
      ;;
    *)
      _fpr_err "unknown host kind '$host' — cannot fetch checks for PR $pr"
      return 1
      ;;
  esac
}

# fpr_check_is_failing <pr-index>
# Single source of truth for "does this PR have a red required-ish check?".
# Exit 0 (true) iff at least one check on the PR head is in a terminal FAILURE
# state; exit 1 (false) if all checks are SUCCESS or PENDING; exit 2 on an
# unresolvable error (fail closed — the caller must treat a resolution failure
# as "cannot confirm green", never as "green").
#
# Works on both hosts because it consumes fpr_checks' normalised gh-shaped
# output. Matches the terminal-failure enum set monitor-lib.sh already treats as
# failing (FAILURE/TIMED_OUT/CANCELLED/ACTION_REQUIRED/STARTUP_FAILURE/STALE) so
# a GitHub PR and a Forgejo PR are judged by exactly the same rule.
#
# THREE-VALUED — the caller MUST distinguish exit 2 from exit 1, or a resolution
# failure collapses into "not failing". The natural `if fpr_check_is_failing N`
# idiom folds 1 and 2 into the else branch. To honour fail-closed, capture $?:
#     if fpr_check_is_failing "$N"; then red=1
#     else case $? in 2) echo "cannot confirm CI — treat as red"; red=1;; *) red=0;; esac
#     fi
fpr_check_is_failing() {
  local pr="${1:-}"
  [ -n "$pr" ] || { _fpr_err "fpr_check_is_failing: <pr-index> required"; return 2; }
  command -v jq >/dev/null 2>&1 || { _fpr_err "jq is required for fpr_check_is_failing"; return 2; }
  local checks failing
  checks="$(fpr_checks "$pr")" || { _fpr_err "fpr_check_is_failing: could not fetch checks for PR $pr"; return 2; }
  # A jq parse failure prints nothing AND exits non-zero. The trailing
  # `|| failing=''` is load-bearing: under the sourced file's `set -e`, a BARE
  # call to this function (not in an if/&&/|| context) would otherwise abort at
  # the failing pipeline before the numeric guard runs, skipping `return 2`. With
  # the `||`, the assignment always succeeds and the guard below fails closed
  # (return 2) on the empty/broken payload — so a red PR is never read as green.
  failing="$(printf '%s' "$checks" | jq '[.[] | select(
      .state == "FAILURE" or .state == "TIMED_OUT" or .state == "CANCELLED"
      or .state == "ACTION_REQUIRED" or .state == "STARTUP_FAILURE" or .state == "STALE"
    )] | length' 2>/dev/null)" || failing=''
  case "$failing" in
    ''|*[!0-9]*) _fpr_err "fpr_check_is_failing: non-numeric failing count '$failing'"; return 2 ;;
  esac
  [ "$failing" -gt 0 ]
}
