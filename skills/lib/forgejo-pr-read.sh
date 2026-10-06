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
# Forgejo-only merge helpers (issue #2650 part 2): the mutating slice's
# `fpr_merge_ready` / `fpr_merge` (skills/lib/forgejo-pr-mutate.sh, #2582) are
# FORGEJO-ONLY. Their reviewed-label gate keys on SGE_FORGEJO_REVIEWED_LABEL and
# never consults the repo's $MERGE_GATE_LABEL, so on a GitHub remote they would
# skip the review gate. GitHub merge loops keep using monitor-lib.sh's
# `pr_ready_for_merge` + the pr-monitor three-gate model; never route a GitHub
# PR through fpr_merge*.
#
# Usage (source, then call wrappers):
#   source "${CLAUDE_PLUGIN_ROOT}/skills/lib/forgejo-pr-read.sh"
#   HOST_KIND="$(fpr_host_kind)"   # "github" | "forgejo" | "azdo" | "unknown"
#
#   # List open PRs — JSON array output:
#   #   GitHub path  → gh pr list --state open --json number,title,...
#   #   Forgejo path → forgejo-adapter.sh list-prs <origin-url>
#   #   Azure DevOps → azdo-adapter.sh list-prs <origin-url> (issue #2946):
#   #                  [{number, headRefName}] only, fail-closed on truncation
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
#   # Open-PR head branches, FAIL-CLOSED (for destructive callers, e.g.
#   # tidy-worktrees' "open-PR branches are always preserved" rule):
#   #   GitHub path  → gh pr list --state open --limit N --json number,headRefName
#   #   Forgejo path → forgejo-adapter.sh list-prs <origin-url>
#   #   Azure DevOps → azdo-adapter.sh list-prs <origin-url> (issue #2946)
#   # Prints "<number><TAB><head-branch>" per open PR. Exits non-zero when the
#   # list cannot be obtained OR may be truncated — the caller MUST then refuse
#   # to delete anything (an empty/partial list reads every branch as "not open").
#   fpr_open_pr_heads
#
# Environment:
#   CLAUDE_PLUGIN_ROOT    — must be set (standard SGE harness var).
#   FORGEJO_API_TOKEN /
#   GITEA_TOKEN           — required for Forgejo paths (see forgejo-adapter.sh).
#   SGE_FORGEJO_HOSTS /
#   SGE_FORGEJO_DEFAULT_HOST — host allow-list (see forgejo-adapter.sh / ADR-0010).
#   SGE_AZDO_TOKEN        — required for Azure DevOps paths; SGE_AZDO_ORG
#                           (optional, must match the origin's org) and the
#                           SGE_AZDO_HOSTS allow-list — see azdo-adapter.sh.
#   GH_REPO               — optional; overrides the origin-derived repo slug for
#                           GitHub paths (standard SGE convention, #662).
#
# NOTE: shell state does NOT persist across agent tool calls; source this file
# at the top of each tool call where it is needed. See docs/skill-authoring-repo-context.md.

set -euo pipefail

_FPR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FPR_ADAPTER="${CLAUDE_PLUGIN_ROOT:-$_FPR_SCRIPT_DIR/../..}/scripts/forgejo-adapter.sh"
_FPR_WRC="${CLAUDE_PLUGIN_ROOT:-$_FPR_SCRIPT_DIR/../..}/scripts/with-repo-cwd.sh"
_FPR_AZDO_ADAPTER="${CLAUDE_PLUGIN_ROOT:-$_FPR_SCRIPT_DIR/../..}/scripts/azdo-adapter.sh"

_fpr_err()  { printf 'forgejo-pr-read: error: %s\n' "$*" >&2; }

# Resolve and cache the host kind for this shell invocation. Re-sourcing the file
# in the same shell resets it (safe: same repo, same origin, same result).
_FPR_HOST_KIND=""

# fpr_host_kind — print the host kind for the current repo's origin:
#   "github" | "forgejo" | "azdo" | "unknown"
# Uses with-repo-cwd.sh's canonical classifier (the single source of truth for
# the SGE_FORGEJO_HOSTS / SGE_GITHUB_HOSTS allow-list).
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
    azdo)
      local origin; origin="$(_fpr_origin_url)"
      [ -f "$_FPR_AZDO_ADAPTER" ] || { _fpr_err "azdo-adapter.sh not found at $_FPR_AZDO_ADAPTER"; return 1; }
      bash "$_FPR_AZDO_ADAPTER" list-prs "$origin"
      ;;
    *)
      _fpr_err "unknown host kind '$host' — cannot list PRs (add host to SGE_FORGEJO_HOSTS or SGE_GITHUB_HOSTS)"
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
# shape that every SGE consumer already understands. The critical field is
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
# Field + history (sge#2626): real Forgejo carries the value in `status` (state
# is null) and lists superseded entries; the adapter's pr-statuses already
# reduces to the newest entry per context and sets `.state`, and this
# normaliser reads `status` first as defence in depth.
#
# gh's `name` maps from Gitea's `context`; `detailsUrl` from `target_url`. There
# is no per-check `status`/`conclusion` split in Gitea (state carries both), so
# `conclusion` mirrors the normalised state and `status` is COMPLETED for any
# terminal state, IN_PROGRESS for PENDING.
_FPR_STATUS_NORMALISE='{
  name: (.context // ""),
  state: (
    (.status // .state // "" | ascii_downcase) as $s
    | if   $s == "success" then "SUCCESS"
      elif $s == "pending" then "PENDING"
      elif $s == "warning" then "SUCCESS"
      else "FAILURE" end
  ),
  detailsUrl: (.target_url // ""),
  link: (.target_url // ""),
  description: (.description // "")
} | .bucket = (if .state == "PENDING" then "pending" elif .state == "SUCCESS" then "pass" else "fail" end)
  | .status = (if .state == "PENDING" then "IN_PROGRESS" else "COMPLETED" end)
  | .conclusion = (if .state == "PENDING" then "" else .state end)'

# Fields requested from `gh pr checks --json` on the GitHub path. ONLY fields
# real `gh pr checks` accepts (gh 2.x: bucket, completedAt, description, event,
# link, name, startedAt, state, workflow). `status`/`conclusion`/`detailsUrl` are
# NOT valid there (they belong to `gh pr view --json statusCheckRollup`) and
# make gh exit with `Unknown JSON field` — issue #2650, which made
# fpr_check_is_failing return 2 on every GitHub PR.
_FPR_GH_CHECKS_FIELDS='name,state,bucket,link,startedAt,completedAt,workflow,description'

# jq filter adding the legacy convenience keys (detailsUrl/status/conclusion)
# to ONE real `gh pr checks` object so both hosts emit the same superset shape.
# `.state` is left exactly as gh reports it (SUCCESS/FAILURE/PENDING/...).
_FPR_GH_CHECK_NORMALISE='. + {
  detailsUrl: (.link // ""),
  status: (if (.bucket // "") == "pending" then "IN_PROGRESS" else "COMPLETED" end),
  conclusion: (if (.bucket // "") == "pending" then "" else (.state // "") end)
}'

# fpr_checks <pr-index>
# Get CI check statuses for a PR, normalised to gh's `pr checks --json` shape.
# Output (both hosts): JSON array of {name,state,bucket,link,detailsUrl,status,
# conclusion,...}. `.state` is gh's UPPERCASE enum; `.bucket` is gh's
# pass/fail/pending/skipping/cancel grouping.
# GitHub path:  gh pr checks <N> --json $_FPR_GH_CHECKS_FIELDS, then jq-enriched
# Forgejo path: resolve the PR head SHA via get-pr, call pr-statuses, then map the
#               raw Gitea CommitStatus array through _FPR_STATUS_NORMALISE so the
#               output `state` is gh's UPPERCASE enum (SUCCESS/PENDING/FAILURE) —
#               NOT the raw lowercase Gitea state. Consumers compare `.state`
#               against gh enums; returning raw lowercase made a red Forgejo PR
#               read clean (issue #1238 follow-up).
#
# Page cap: the Forgejo path lists at most the first 50 commit statuses for the
# head SHA (the adapter's pr-statuses is `?page=1&limit=50`). A head with more
# than 50 distinct check contexts would be truncated; SGE PRs are far below this.
fpr_checks() {
  local pr="${1:-}"
  [ -n "$pr" ] || { _fpr_err "fpr_checks: <pr-index> required"; return 1; }
  local host; host="$(fpr_host_kind)"
  case "$host" in
    github)
      command -v jq >/dev/null 2>&1 || { _fpr_err "jq is required for fpr_checks"; return 1; }
      # `gh pr checks` exits 8 when checks are merely pending (1 on a real
      # error) while still printing valid JSON for the pending case. Accept a
      # non-zero exit only when stdout is a well-formed JSON array.
      local gh_out gh_rc=0
      gh_out="$(gh pr checks "$pr" --json "$_FPR_GH_CHECKS_FIELDS")" || gh_rc=$?
      if [ "$gh_rc" -ne 0 ] && ! printf '%s' "$gh_out" | jq -e 'type == "array"' >/dev/null 2>&1; then
        _fpr_err "gh pr checks $pr failed (exit $gh_rc)"; return 1
      fi
      printf '%s' "$gh_out" | jq "[.[] | ${_FPR_GH_CHECK_NORMALISE}]"
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
  # `.state == "ERROR"` (a GitHub commit-status error) and `.bucket == "fail"`
  # (gh's own failing grouping) are included so no red GitHub check reads green.
  failing="$(printf '%s' "$checks" | jq '[.[] | select(
      .state == "FAILURE" or .state == "TIMED_OUT" or .state == "CANCELLED"
      or .state == "ACTION_REQUIRED" or .state == "STARTUP_FAILURE" or .state == "STALE"
      or .state == "ERROR" or .bucket == "fail"
    )] | length' 2>/dev/null)" || failing=''
  case "$failing" in
    ''|*[!0-9]*) _fpr_err "fpr_check_is_failing: non-numeric failing count '$failing'"; return 2 ;;
  esac
  [ "$failing" -gt 0 ]
}

# fpr_open_pr_heads — list open PRs as "<number><TAB><head-branch>" lines.
#
# FAIL-CLOSED by contract (sge-public#47): this is the list tidy-worktrees uses
# to decide which branches are "in flight" and therefore never deleted. A
# silently empty or truncated list would classify a live PR's branch as safe to
# remove, so every uncertainty is an error, never an empty success:
#   - unknown host (not GitHub/Azure DevOps/allow-listed Forgejo) → exit 1
#   - gh / adapter call fails                                   → exit 1
#   - payload is not a JSON array                               → exit 1
#   - payload length reaches the page cap (possible truncation) → exit 1
# Exit 0 with no output means "confirmed zero open PRs".
#
# Page caps: GitHub asks for SGE_OPEN_PR_LIMIT (default 1000) — `gh pr list`'s
# own default of 30 silently truncated busy repos. Forgejo's adapter list-prs
# returns at most 50 (page=1&limit=50); a full page is treated as truncated.
# Azure DevOps' adapter list-prs paginates itself and exits non-zero when its
# own page cap may have truncated the list (issue #2946), so no cap here.
fpr_open_pr_heads() {
  command -v jq >/dev/null 2>&1 || { _fpr_err "jq is required for fpr_open_pr_heads"; return 1; }
  local host raw cap jqf n origin
  host="$(fpr_host_kind)"
  case "$host" in
    github)
      cap="${SGE_OPEN_PR_LIMIT:-1000}"
      case "$cap" in ''|*[!0-9]*|0) _fpr_err "SGE_OPEN_PR_LIMIT must be a positive integer"; return 1 ;; esac
      raw="$(gh pr list --state open --limit "$cap" --json number,headRefName)" \
        || { _fpr_err "gh pr list failed — open-PR set unknown"; return 1; }
      jqf='.[] | "\(.number)\t\(.headRefName)"'
      ;;
    forgejo)
      cap=50
      origin="$(_fpr_origin_url)" || return 1
      [ -f "$_FPR_ADAPTER" ] || { _fpr_err "forgejo-adapter.sh not found at $_FPR_ADAPTER"; return 1; }
      raw="$(bash "$_FPR_ADAPTER" list-prs "$origin")" \
        || { _fpr_err "forgejo-adapter.sh list-prs failed — open-PR set unknown"; return 1; }
      jqf='.[] | "\(.number)\t\(.head.ref)"'
      ;;
    azdo)
      cap=""
      origin="$(_fpr_origin_url)" || return 1
      [ -f "$_FPR_AZDO_ADAPTER" ] || { _fpr_err "azdo-adapter.sh not found at $_FPR_AZDO_ADAPTER"; return 1; }
      raw="$(bash "$_FPR_AZDO_ADAPTER" list-prs "$origin")" \
        || { _fpr_err "azdo-adapter.sh list-prs failed or may be truncated — open-PR set unknown"; return 1; }
      jqf='.[] | "\(.number)\t\(.headRefName)"'
      ;;
    *)
      _fpr_err "unknown host kind '$host' — open-PR set unknown (add host to SGE_FORGEJO_HOSTS or SGE_GITHUB_HOSTS)"
      return 1
      ;;
  esac
  n="$(printf '%s' "$raw" | jq -e 'if type == "array" then length else error("not an array") end' 2>/dev/null)" \
    || { _fpr_err "open-PR payload is not a JSON array — open-PR set unknown"; return 1; }
  n="${n%$'\r'}"
  if [ -n "$cap" ] && [ "$n" -ge "$cap" ]; then
    _fpr_err "open-PR list hit the page cap ($n >= $cap) — may be truncated; open-PR set unknown"
    return 1
  fi
  # tr: jq.exe on Windows emits CRLF; a stray \r would corrupt branch names.
  printf '%s' "$raw" | jq -r "$jqf" | tr -d '\r'
}
