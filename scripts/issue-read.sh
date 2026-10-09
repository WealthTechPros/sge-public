#!/usr/bin/env bash
# issue-read.sh — host-aware read-only issue operations (ADR-0010, #1237).
# Slice 2 of the #1146 non-GitHub-host epic: route read-only issue ops through
# the forgejo-adapter seam (#1236) so /sge:sge-align and /sge:available-issues
# work against Forgejo/Gitea-hosted repos.
#
# Two independent routing dimensions are resolved here:
#
#   1. ALM (issue-tracker) backend — SPEC-105 S2 (#1700). Resolved FIRST, via
#      scripts/with-repo-cwd.sh alm (SGE_ALM_BACKEND). A repo may be GitHub-HOSTED
#      yet track its work in Jira, so the tracker is orthogonal to the git host.
#      Unset/empty = `github` (the status quo — this dimension is dark until a
#      repo declares a non-GitHub tracker, SPEC-105 §3). `jira` routes the read
#      ops (P1 list-dispatchable, P2 view-item) through scripts/jira-adapter.sh,
#      normalising the Jira JSON to the SAME gh-compatible output shape. An
#      UNRECOGNISED backend FAILS LOUD (SPEC-105 DR1) and issues NO gh call and
#      NO Jira REST call — never a silent GitHub fallback against the wrong tracker.
#   2. Git host — only when the ALM backend is `github`: route through
#      scripts/forgejo-adapter.sh when the git host is forgejo/gitea (as
#      classified by scripts/with-repo-cwd.sh host), else delegate to `gh`
#      unchanged (byte-identical to before this change).
#
# This is the ONLY seam for read-only issue list/view operations; all mutating
# ops (create, close, edit, comment) remain in the calling skill (the Jira
# mutating verbs are SPEC-105 S3, not routed here).
#
# Usage:
#   issue-read.sh list  [--state open|closed|all] [--label <name>] [--limit N]
#       JSON array: [{number,title,body,labels:[{name}],assignees:[{login}],state}]
#       `state` is OPEN|CLOSED (gh-compatible) for both GitHub and Forgejo backends.
#       Forgejo: paginated automatically; `--limit 0` means "all" (no cap).
#       GitHub: delegates to `gh issue list --json number,title,body,labels,assignees,state`.
#   issue-read.sh view  <number>
#       Same JSON object shape for a single issue.
#       `state` is OPEN|CLOSED for both backends.
#   issue-read.sh dependencies  <number>
#       Print one line per dependency: `<id>\t<open|closed>`.
#       GitHub: parses Depends on #N / Blocked by #N / Requires #N / DependsOn: #N
#       from the issue body, then resolves each dependency's state.
#       Jira: structural `is blocked by` issue links resolved via status CATEGORY
#       (DR2) — never a localised status name. Routes through jira-adapter.sh P7.
#   issue-read.sh search <text> [--state open|closed|all] [--limit N]
#       JSON array of items whose title contains <text> (free-text search).
#       GitHub: `gh issue list --search "<text> in:title"`.
#       Jira: JQL `summary ~ "<text>"` scoped to SGE_JIRA_PROJECT, with
#       injection-safe escaping so the text cannot break out of the JQL string.
#       Forgejo: Gitea search API with `q=<text>&type=issues`.
#       `--state` defaults to "open"; `--limit` defaults to 0 (no cap).
#   issue-read.sh dispatch-label
#       Print the repo-configurable dispatch-label name on stdout.
#       GitHub: reads the `dispatch-label:` key from CLAUDE.md (empty = no filter).
#       Jira: routes through jira-adapter.sh P9 dispatch-label-config (default
#       sge-ready, configurable via SGE_DISPATCH_LABEL). (SPEC-105 S4, DP2.)
#
# SPEC-057: always run from the target repo's checkout cwd — shell state does
# NOT persist across agent tool calls, so re-enter the resolved cwd at the top
# of every shell call. This script classifies the host from the current cwd's
# `origin` remote; a wrong cwd means wrong data (the gh/forgejo-adapter will
# fail loud). Never falls back to the ambient cwd.
#
# ALM (issue-tracker) backend — SPEC-105:
#   SGE_ALM_BACKEND   unset/empty|github (default) | jira. `jira` routes reads
#                     through scripts/jira-adapter.sh; `azdo` routes them
#                     through scripts/azdo-adapter.sh (SPEC-110 S2: list, view,
#                     dependencies, search, dispatch-label; SGE_AZDO_PROJECT
#                     names the Boards project). Any other value fails loud (DR1)
#                     — never a GitHub fall-through. See with-repo-cwd.sh alm.
#   SGE_JIRA_PROJECT  the Jira project key P1 list-dispatchable enumerates
#                     (REQUIRED for `list` on the jira backend; `view` takes an
#                     issueKey argument so it does not need the project).
#   Jira credential / host allow-list / dispatch-label env are the jira-adapter's
#   (SGE_JIRA_BASE_URL, SGE_JIRA_HOSTS, SGE_JIRA_BEARER or SGE_JIRA_EMAIL +
#   SGE_JIRA_API_TOKEN, SGE_DISPATCH_LABEL) — see scripts/jira-adapter.sh. On the
#   jira backend the item id is a Jira issueKey (PROJ-123), so the normalised
#   `.number` field is that key string, and `.state` is derived from the Jira
#   status CATEGORY (DR2), never a localised status name.
#
# Auth:
#   GitHub:        `gh auth` (unchanged, exactly as before).
#   Forgejo/Gitea: FORGEJO_API_TOKEN (preferred) or GITEA_TOKEN. The host must
#                  be explicitly trusted via SGE_FORGEJO_HOSTS (';'-separated)
#                  or SGE_FORGEJO_DEFAULT_HOST. See scripts/forgejo-adapter.sh
#                  and docs/decisions/0010-non-github-host-adapter.md (ADR-0010).
# END_USAGE

set -euo pipefail
# SGD_ fallback: remove in SGD rename Phase 6
# shellcheck source=sge-env-compat.sh
. "$(dirname "${BASH_SOURCE[0]}")/sge-env-compat.sh"
sge_env_compat DISPATCH_LABEL JIRA_PROJECT JIRA_BASE_URL JIRA_HOSTS JIRA_BEARER JIRA_EMAIL JIRA_API_TOKEN JIRA_CLAIM_TRANSITION_ID JIRA_RELEASE_TRANSITION_ID JIRA_CLAIM_STATUS JIRA_ISSUETYPE JIRA_CLOSE_TRANSITION_ID

_IR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FA="${_IR_SCRIPT_DIR}/forgejo-adapter.sh"
_JA="${_IR_SCRIPT_DIR}/jira-adapter.sh"
_AA="${_IR_SCRIPT_DIR}/azdo-adapter.sh"
_WRC="${_IR_SCRIPT_DIR}/with-repo-cwd.sh"

_ir_err() { printf 'issue-read: error: %s\n' "$*" >&2; }

# mktemp helper for _ir_forgejo_list's per-page accumulation buffers.
# Mirrors the _ja_mktemp / _aa_mktemp convention (jira-adapter.sh,
# azdo-adapter.sh): fail loud when a temp file cannot be created, never
# silently proceed without a buffer.
_ir_mktemp() {
  mktemp "${TMPDIR:-/tmp}/issue-read.XXXXXX" 2>/dev/null \
    || { _ir_err "mktemp failed — cannot buffer a Forgejo issue-list page"; return 1; }
}

# Resolve the declared ALM (issue-tracker) backend at the resolver seam
# (SPEC-105). Prints `github` | `jira` on stdout; propagates the resolver's
# fail-loud non-zero exit for an unrecognised SGE_ALM_BACKEND (DR1) so the
# caller can stop BEFORE any gh/Jira call — never a silent GitHub fallback.
_ir_alm() {
  "$_WRC" alm | tr -d '\n'
}

_ir_usage() {
  [ -n "${1:-}" ] && _ir_err "$1"
  sed -n '/^# Usage:/,/^# SPEC-057/{ /^# SPEC-057/d; p }' "${BASH_SOURCE[0]}" \
    | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# Classify the current checkout's git host.
# Returns: github | forgejo | unknown
_ir_host() {
  "$_WRC" host 2>/dev/null | tr -d '\n' || printf 'unknown'
}

# Print the current checkout's origin URL, or fail loud.
_ir_origin() {
  git remote get-url origin 2>/dev/null \
    || { _ir_err "no 'origin' remote in cwd '$(pwd)'"; exit 1; }
}

# jq expression that maps a single Forgejo/Gitea issue JSON object to the
# gh-compatible output shape used by `gh issue list --json ...` and
# `gh issue view --json ...`.  `state` is normalised to OPEN|CLOSED so both
# backends look the same to callers that compare `.state` to "OPEN".
_IR_JQ_NORMALISE='{
  number: .number,
  title: (.title // ""),
  body: (.body // ""),
  labels: [.labels[]? | {name: .name}],
  assignees: [.assignees[]? | {login: .login}],
  state: (.state // "open" | ascii_upcase)
}'

# Fetch and normalise one page of Forgejo issues.
# Prints a JSON array on stdout.
_ir_forgejo_page() { # <origin> <qs>
  bash "$_FA" list-issues-filtered "$1" "$2" \
    | jq "[.[] | ${_IR_JQ_NORMALISE}]"
}

# Paginate Forgejo issues, accumulating into a single JSON array.
# Stops when: the page is short (last page), OR collected >= limit (when > 0).
#
# Each page is buffered to its OWN temp file rather than folded into a shell
# variable via `jq --argjson` on every iteration. `--argjson` passes its value
# as a command-line argument, so accumulating the WHOLE running array through
# it every loop makes the argv grow with every page — confirmed to crash with
# `jq: Argument list too long` on 36+ issues (Windows/Git-Bash ARG_MAX).
# Slurping the per-page temp files with `jq -s` at the end reads them via
# stdin/file, which has no such argv ceiling.
_ir_forgejo_list() { # <origin> <state> <label> <limit>
  local origin="$1" state="$2" label="$3" limit="$4"
  local page=1 page_size=50 collected=0
  local page_files=() result rc=0

  # Cleaned up on every exit path (success, early break, or a failure below) —
  # never leaves page buffers behind, and the trap is cleared once handled so
  # it cannot refire on an unrelated outer return.
  _ir_forgejo_list_cleanup() {
    [ "${#page_files[@]}" -eq 0 ] || rm -f "${page_files[@]}"
    trap - INT TERM
  }
  trap '_ir_forgejo_list_cleanup' INT TERM

  while true; do
    local qs="state=${state}&type=issues&limit=${page_size}&page=${page}"
    [ -n "$label" ] && qs="${qs}&labels=${label}"

    local chunk
    chunk="$(_ir_forgejo_page "$origin" "$qs")" || { rc=1; break; }

    local chunk_len
    chunk_len="$(printf '%s' "$chunk" | jq 'length')" || { rc=1; break; }
    [ "$chunk_len" -eq 0 ] && break

    local pf
    pf="$(_ir_mktemp)" || { rc=1; break; }
    printf '%s' "$chunk" > "$pf"
    page_files+=("$pf")

    collected=$((collected + chunk_len))
    # Stop when we have enough.
    [ "$limit" -gt 0 ] && [ "$collected" -ge "$limit" ] && break
    # Stop when the page was short (no more pages).
    [ "$chunk_len" -lt "$page_size" ] && break
    page=$((page + 1))
  done

  if [ "$rc" -eq 0 ]; then
    if [ "${#page_files[@]}" -eq 0 ]; then
      result='[]'
    else
      # Slurp every page file and flatten (each file holds a JSON array, not a
      # single object) into one array — file-based input, no argv growth.
      result="$(jq -s '[.[][]]' "${page_files[@]}")" || rc=1
    fi
  fi

  _ir_forgejo_list_cleanup

  [ "$rc" -eq 0 ] || return 1

  # Trim to limit when requested. --argjson keeps the caller value out of the
  # jq program text (limit is the one arg that reaches an interpreter); the
  # already-slurped, size-bounded result is safe to pass this way.
  if [ "$limit" -gt 0 ]; then
    printf '%s' "$result" | jq --argjson n "$limit" '.[0:$n]'
  else
    printf '%s' "$result"
  fi
}

# Fetch and normalise a single Forgejo issue by index.
_ir_forgejo_view() { # <origin> <number>
  bash "$_FA" view-issue "$1" "$2" \
    | jq "${_IR_JQ_NORMALISE}"
}

# jq expression that maps a single Jira issue object (the shape jira-adapter.sh
# view-item / list-dispatchable returns) to the SAME gh-compatible output shape
# the forgejo path produces, so callers stay backend-agnostic:
#   number   — the Jira issueKey string ("PROJ-123"), the item's identity on Jira
#   labels   — Jira labels are bare strings; lift each to {name: <string>}
#   assignee — Jira Cloud carries displayName/accountId, Server carries name;
#              prefer name, then displayName, then emailAddress for a login proxy
#   state    — OPEN|CLOSED derived from the status CATEGORY key (DR2 — "done" =>
#              CLOSED, anything else OPEN), never a localised status NAME
_IR_JQ_JIRA_ITEM='{
  number: .key,
  title: (.fields.summary // ""),
  body: (.fields.description // ""),
  labels: [ .fields.labels[]? | {name: .} ],
  assignees: (
    if (.fields.assignee // null) != null
    then [ { login: ( [ .fields.assignee.name, .fields.assignee.displayName, .fields.assignee.emailAddress ]
                      | map(select(. != null and . != "")) | (.[0] // "") ) } ]
    else [] end
  ),
  state: ( if (.fields.status.statusCategory.key // "") == "done" then "CLOSED" else "OPEN" end )
}'

# P1 list-dispatchable via the Jira backend, normalised to the gh array shape.
# The dispatchable set is inherently open + unassigned + dispatch-labelled, so
# the git-host --state knob does not map here; --label (when given) overrides the
# adapter's default dispatch label, and --limit is honoured as an upper bound.
_ir_jira_list() { # <state> <label> <limit>
  local label="$2" limit="$3" project raw arr
  command -v jq >/dev/null 2>&1 || { _ir_err "jq not found — required for the Jira issue-read path"; exit 1; }
  project="${SGE_JIRA_PROJECT:-}"
  [ -n "$project" ] || {
    _ir_err "no Jira project key — set SGE_JIRA_PROJECT (the project P1 list-dispatchable enumerates); refusing to list without it (SPEC-105 S2)"
    exit 1
  }
  if [ -n "$label" ]; then
    raw="$(bash "$_JA" list-dispatchable "$project" "$label")" || exit 1
  else
    raw="$(bash "$_JA" list-dispatchable "$project")" || exit 1
  fi
  arr="$(printf '%s' "$raw" | jq "[.issues[]? | ${_IR_JQ_JIRA_ITEM}]")"
  if [ "$limit" -gt 0 ]; then
    printf '%s' "$arr" | jq --argjson n "$limit" '.[0:$n]'
  else
    printf '%s' "$arr"
  fi
}

# P2 view-item via the Jira backend, normalised to the gh object shape. The
# adapter validates the issueKey character class before URL construction.
_ir_jira_view() { # <issueKey>
  local raw
  command -v jq >/dev/null 2>&1 || { _ir_err "jq not found — required for the Jira issue-read path"; exit 1; }
  raw="$(bash "$_JA" view-item "$1")" || exit 1
  printf '%s' "$raw" | jq "${_IR_JQ_JIRA_ITEM}"
}

# P7 item-dependencies via the Jira backend. jira-adapter.sh already outputs
# the target format: KEY\topen|closed per line (status category, DR2).
_ir_jira_dependencies() { # <issueKey>
  bash "$_JA" item-dependencies "$1"
}

# ── Azure Boards (SPEC-110 S2, issue #2985) ────────────────────────────────
# The same gh-compatible shape as the Jira/Forgejo paths. `number` is the
# integer work-item id; labels are the System.Tags tokens; `state` is derived
# from the state CATEGORY when present (DR2), else a closed-name heuristic.
_IR_JQ_AZDO_ITEM='{
  number: .id,
  title: (.fields["System.Title"] // ""),
  body: (.fields["System.Description"] // ""),
  labels: [ (.fields["System.Tags"] // "") | split(";")[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) | {name: .} ],
  assignees: ( if (.fields["System.AssignedTo"] // null) == null then []
               else [ { login: ( .fields["System.AssignedTo"] | if type == "object" then (.uniqueName // .displayName // "") else tostring end ) } ] end ),
  state: ( (.fields["System.StateCategory"] // .fields["System.State"] // "") | ascii_downcase
           | if IN("completed", "removed", "done", "closed", "resolved") then "CLOSED" else "OPEN" end )
}'

_ir_azdo_project() {
  [ -n "${SGE_AZDO_PROJECT:-}" ] || {
    _ir_err "no Azure DevOps project — set SGE_AZDO_PROJECT (the Boards project to read); refusing (SPEC-110 S2)"
    exit 1
  }
  printf '%s' "$SGE_AZDO_PROJECT"
}

_ir_azdo_trim() { # <json-array> <limit>
  if [ "$2" -gt 0 ]; then printf '%s' "$1" | jq --argjson n "$2" '.[0:$n]'; else printf '%s' "$1"; fi
}

_ir_azdo_list() { # <state> <label> <limit>
  local project raw
  command -v jq >/dev/null 2>&1 || { _ir_err "jq not found — required for the Azure Boards issue-read path"; exit 1; }
  project="$(_ir_azdo_project)"
  if [ -n "$2" ]; then
    raw="$(bash "$_AA" list-dispatchable "$project" "$2")" || exit 1
  else
    raw="$(bash "$_AA" list-dispatchable "$project")" || exit 1
  fi
  _ir_azdo_trim "$(printf '%s' "$raw" | jq "[.value[]? | ${_IR_JQ_AZDO_ITEM}]")" "$3"
}

_ir_azdo_view() { # <id>
  local raw
  command -v jq >/dev/null 2>&1 || { _ir_err "jq not found — required for the Azure Boards issue-read path"; exit 1; }
  raw="$(bash "$_AA" view-item "$1")" || exit 1
  printf '%s' "$raw" | jq "${_IR_JQ_AZDO_ITEM}"
}

_ir_azdo_search() { # <text> <state> <limit>
  local project raw
  command -v jq >/dev/null 2>&1 || { _ir_err "jq not found — required for the Azure Boards search path"; exit 1; }
  project="$(_ir_azdo_project)"
  raw="$(bash "$_AA" search-items "$project" "$1" "$2")" || exit 1
  _ir_azdo_trim "$(printf '%s' "$raw" | jq "[.value[]? | ${_IR_JQ_AZDO_ITEM}]")" "$3"
}

# Any ALM token other than github/jira/azdo. with-repo-cwd.sh alm already fails
# loud on an unrecognised SGE_ALM_BACKEND; this is the second line, so a future
# resolver token can never fall through to a GitHub call (DR1).
_ir_unknown_alm() {
  _ir_err "ALM backend '$1' has no issue-read route — refusing rather than falling back to GitHub (SPEC-105 DR1)"
  exit 1
}

# P7 item-dependencies via the GitHub backend. Parse the issue body for
# dependency references (Depends on #N / Blocked by #N / Requires #N /
# DependsOn: #N), then resolve each dep's state via `gh issue view`.
#
# Cross-repo refs (org/repo#N) are recognised and emitted as `unknown`
# (fail-closed) — they cannot be resolved repo-locally. Spaced refs
# like `# 12` are NOT matched (not a standard GitHub form).
#
# FAILS CLOSED (issue #1726). This output gates whether an autonomous worker
# may start an issue, so "I could not determine the state" must never be
# reported as "nothing blocks this". An indeterminate lookup emits the
# sentinel `<id>\tunknown`, which the caller treats exactly like `open`:
#   - body fetch fails (expired token, rate-limit, 5xx) -> exit non-zero AND
#     emit `<id>\tunknown`, so a backend outage cannot silently mark the whole
#     backlog dispatchable;
#   - a single dep's state fetch fails -> `<dep>\tunknown` rather than dropping
#     it, which would otherwise be attacker-selectable by citing a private or
#     deleted issue number.
_ir_github_dependencies() { # <number>
  local body dep_nums n state
  command -v jq >/dev/null 2>&1 || { _ir_err "jq not found — required for dependency resolution"; exit 1; }
  if ! body="$(gh issue view "$1" --json body --jq '.body' 2>/dev/null)"; then
    _ir_err "dependencies: could not read issue #$1 body — reporting UNKNOWN (fail-closed, #1726)"
    printf '%s\tunknown\n' "$1"
    return 3
  fi
  # Extract all dependency references — both local (#N) and cross-repo (org/repo#N).
  # Cross-repo refs are emitted as unknown (fail-closed, #1732) since they cannot
  # be resolved repo-locally; local refs are resolved via `gh issue view`.
  local dep_refs
  dep_refs="$(printf '%s' "$body" \
    | grep -ioE '(depends[ -]?on|blocked[ -]?by|requires)[[:space:]:]+[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+' \
    | grep -oE '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+' | sort -u)" || true
  local xref
  for xref in $dep_refs; do
    _ir_err "dependencies: cross-repo ref '$xref' cannot be resolved repo-locally — reporting UNKNOWN (fail-closed, #1732)"
    printf '%s\tunknown\n' "$xref"
  done
  dep_nums="$(printf '%s' "$body" \
    | grep -ioE '(depends[ -]?on|blocked[ -]?by|requires)[[:space:]:]+#[0-9]+' \
    | grep -oE '[0-9]+' | sort -un)" || true
  for n in $dep_nums; do
    if ! state="$(gh issue view "$n" --json state --jq '.state' 2>/dev/null)"; then
      _ir_err "dependencies: could not resolve dependency #$n — reporting UNKNOWN (fail-closed, #1726)"
      printf '%s\tunknown\n' "$n"
      continue
    fi
    case "$state" in
      CLOSED|closed) printf '%s\tclosed\n' "$n" ;;
      OPEN|open)     printf '%s\topen\n' "$n" ;;
      *)             printf '%s\tunknown\n' "$n" ;;
    esac
  done
}

# P7 item-dependencies via the Forgejo backend. Same body-text parsing as
# GitHub (including cross-repo ref detection, #1732), but state resolution
# uses issue-read view (which routes through forgejo-adapter).
# Fails closed on an indeterminate lookup exactly as the GitHub backend does
# (issue #1726) — see that function's header for the rationale.
_ir_forgejo_dependencies() { # <number>
  local body dep_nums n state
  command -v jq >/dev/null 2>&1 || { _ir_err "jq not found — required for dependency resolution"; exit 1; }
  local origin
  origin="$(_ir_origin)" || exit 1
  # NB: the pipeline's exit status is jq's, so check the fetch separately —
  # `_ir_forgejo_view ... | jq` would mask a failed fetch behind a successful jq.
  local raw
  if ! raw="$(_ir_forgejo_view "$origin" "$1")"; then
    _ir_err "dependencies: could not read issue #$1 body — reporting UNKNOWN (fail-closed, #1726)"
    printf '%s\tunknown\n' "$1"
    return 3
  fi
  body="$(printf '%s' "$raw" | jq -r '.body // ""')" || body=""
  # Cross-repo refs: emit as unknown (fail-closed, #1732).
  local dep_refs xref
  dep_refs="$(printf '%s' "$body" \
    | grep -ioE '(depends[ -]?on|blocked[ -]?by|requires)[[:space:]:]+[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+' \
    | grep -oE '[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+' | sort -u)" || true
  for xref in $dep_refs; do
    _ir_err "dependencies: cross-repo ref '$xref' cannot be resolved repo-locally — reporting UNKNOWN (fail-closed, #1732)"
    printf '%s\tunknown\n' "$xref"
  done
  dep_nums="$(printf '%s' "$body" \
    | grep -ioE '(depends[ -]?on|blocked[ -]?by|requires)[[:space:]:]+#[0-9]+' \
    | grep -oE '[0-9]+' | sort -un)" || true
  for n in $dep_nums; do
    if ! raw="$(_ir_forgejo_view "$origin" "$n")"; then
      _ir_err "dependencies: could not resolve dependency #$n — reporting UNKNOWN (fail-closed, #1726)"
      printf '%s\tunknown\n' "$n"
      continue
    fi
    state="$(printf '%s' "$raw" | jq -r '.state // ""')" || state=""
    case "$state" in
      CLOSED|closed) printf '%s\tclosed\n' "$n" ;;
      OPEN|open)     printf '%s\topen\n' "$n" ;;
      *)             printf '%s\tunknown\n' "$n" ;;
    esac
  done
}

# P10 `search` via the Jira backend, normalised to the gh array shape. (Naming:
# the PORT/seam operation is `search`; `search-items` is the jira-adapter's own
# verb — the same two-level split every other operation avoids by using one name.)
# The search text is passed to jira-adapter.sh search-items, which JQL-escapes
# it. State filter is forwarded; limit is applied client-side (Jira's search
# endpoint honours maxResults, but the adapter does not expose it — trim here).
_ir_jira_search() { # <text> <state> <limit>
  local text="$1" state="$2" limit="$3" project raw arr
  command -v jq >/dev/null 2>&1 || { _ir_err "jq not found — required for the Jira search path"; exit 1; }
  project="${SGE_JIRA_PROJECT:-}"
  [ -n "$project" ] || {
    _ir_err "no Jira project key — set SGE_JIRA_PROJECT; refusing to search without it (SPEC-105 S4)"
    exit 1
  }
  raw="$(bash "$_JA" search-items "$project" "$text" "$state")" || exit 1
  arr="$(printf '%s' "$raw" | jq "[.issues[]? | ${_IR_JQ_JIRA_ITEM}]")"
  if [ "$limit" -gt 0 ]; then
    printf '%s' "$arr" | jq --argjson n "$limit" '.[0:$n]'
  else
    printf '%s' "$arr"
  fi
}

# P10 search via the Forgejo backend. Gitea's issue search API accepts a `q`
# parameter for free-text matching. State and limit forwarded.
_ir_forgejo_search() { # <origin> <text> <state> <limit>
  local origin="$1" text="$2" state="$3" limit="$4"
  local page_size=50 qs
  # URL-encode the query text via jq (safe) or percent-encode fallback.
  # The fallback encodes everything outside the unreserved set byte-by-byte
  # (same approach as jira-adapter.sh _ja_urlencode) so characters like &, =,
  # +, # cannot corrupt the query string.
  local encoded
  if command -v jq >/dev/null 2>&1; then
    encoded="$(printf '%s' "$text" | jq -sRr '@uri')"
  else
    local i c out=''
    for (( i=0; i<${#text}; i++ )); do
      c="${text:$i:1}"
      case "$c" in
        [A-Za-z0-9.~_-]) out="$out$c" ;;
        *) out="$out$(printf '%%%02X' "'$c")" ;;
      esac
    done
    encoded="$out"
  fi
  qs="state=${state}&type=issues&limit=${page_size}&q=${encoded}"
  local chunk
  chunk="$(_ir_forgejo_page "$origin" "$qs")"
  if [ "$limit" -gt 0 ]; then
    printf '%s' "$chunk" | jq --argjson n "$limit" '.[0:$n]'
  else
    printf '%s' "$chunk"
  fi
}

# P9 dispatch-label-config via the Jira backend. Routes through jira-adapter.sh
# which reads SGE_DISPATCH_LABEL (default sge-ready, DP2).
_ir_jira_dispatch_label() {
  bash "$_JA" dispatch-label-config
}

# P9 dispatch-label-config via the GitHub/Forgejo backend. Reads the
# `dispatch-label:` key from CLAUDE.md in the current checkout (the same
# convention available-issues uses). Validates the extracted label against
# the same character class the Jira path enforces ([A-Za-z0-9._-]+).
#
# The value is REJECTED, never reinterpreted (issues #1726, #1732). Two earlier
# attempts both failed the same way — quietly turning a misconfigured value into
# a different, valid-looking one that matches no label, silently emptying the
# ready pool:
#   `tr -d '[:space:]'`  rewrote `sge-ready --label` -> `sge-ready--label`
#   `awk '{print $1}'`   truncated `sge ready`       -> `sge`
# Truncation is not validation. A label containing whitespace is a
# misconfiguration, so the residue is checked and the whole value refused.
#
# A leading dash is rejected too — the value is interpolated into
# `--label "$DISPATCH_LABEL"`, and a flag-shaped label is one refactor away
# from argument injection while CLAUDE.md is PR-influencable.
#
# An invalid value FAILS LOUD rather than returning empty: empty means "no
# label filter", so silently widening the dispatch pool because of a typo is
# the wrong direction for a gate (DR1 — never a silent fallback).
_ir_github_dispatch_label() {
  local raw lbl rest
  raw="$(grep -E '^dispatch-label:[[:space:]]*\S' CLAUDE.md 2>/dev/null | head -1)" || true
  if [ -z "$raw" ]; then
    # Only a line-start key counts. A bulleted/indented one (`- **dispatch-label:
    # x**`) is still ignored, but no longer silently (#2793). Only a
    # declaration-shaped line warns (indent, `>`, `-`, `*`, bold or a backtick
    # before the key) — not prose that merely mentions the key. Bold or code
    # closing after the colon (`**dispatch-label:** x`) counts too (#2796).
    if grep -qE '^[[:space:]>*-]*[*]*`?dispatch-label:[*`]*[[:space:]]*[*`]*[A-Za-z0-9._-]' CLAUDE.md 2>/dev/null; then
      printf 'issue-read: warning: CLAUDE.md has a dispatch-label line not at line start — ignored, so no dispatch label applies; write it as `dispatch-label: <label>` at column 0\n' >&2
    fi
    printf ''   # unset = no filter, documented default
    return 0
  fi
  # Strip the key and any surrounding whitespace, then split into first token
  # and residue. Residue is a hard error, NOT something to discard.
  raw="$(printf '%s' "$raw" | sed -e 's/^dispatch-label:[[:space:]]*//' -e 's/[[:space:]]*$//')"
  lbl="${raw%%[[:space:]]*}"
  rest="${raw#"$lbl"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"   # trim leading whitespace off the residue
  case "${lbl:-}" in
    '')
      printf ''
      return 0
      ;;
    -*|*[!A-Za-z0-9._-]*)
      _ir_err "dispatch-label: '${lbl}' is not a valid label (allowed: [A-Za-z0-9._-], no leading '-') — refusing rather than silently disabling the dispatch gate (#1726)"
      return 2
      ;;
  esac
  if [ -n "$rest" ]; then
    _ir_err "dispatch-label: '${raw}' contains whitespace — a label is a single token, and silently using only '${lbl}' would match no label and empty the ready pool (#1732). Fix the value in CLAUDE.md."
    return 2
  fi
  printf '%s\n' "$lbl"
}

# When GH_REPO names a target repo, resolve it to a local checkout and cd
# there before any host/ALM classification runs (issue #2207, PR #2266
# review). `_ir_host`/`_ir_origin`/`_ir_alm` all classify from the CURRENT
# CWD's git origin — setting GH_REPO alone (the prior convention, copied from
# `gh`'s own --repo handling) does nothing for the Forgejo/Jira paths, and a
# cwd-mismatched GH_REPO on the GitHub path silently reads the WRONG
# same-numbered issue from cwd's repo instead of GH_REPO's. `with-repo-cwd.sh
# resolve` already fast-paths "cwd already matches" as its own step 0, so this
# is a no-op whenever cwd already matches GH_REPO (the common case); it only
# changes behaviour when they diverge, which was previously either silently
# wrong (GitHub path) or a hard, hard-to-diagnose adapter error (Forgejo
# path). Never silently continues in the wrong cwd: an unresolvable GH_REPO
# fails loud via _wrc_resolve's own fail-closed error (SPEC-057), not a
# fall-through.
_ir_cd_to_gh_repo() {
  [ -n "${GH_REPO:-}" ] || return 0
  local target_dir
  target_dir="$(bash "$_WRC" resolve "$GH_REPO")" || exit 1
  cd "$target_dir" || { _ir_err "GH_REPO='$GH_REPO' resolved to '$target_dir' but cd failed"; exit 1; }
}

_ir_main() {
  _ir_cd_to_gh_repo
  local cmd="${1:-}"
  case "$cmd" in
    list)
      shift
      local state="open" label="" limit=0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --state)
            [ -n "${2:-}" ] || { _ir_err '--state needs a value'; exit 2; }
            state="$2"; shift 2
            ;;
          --label)
            [ -n "${2:-}" ] || { _ir_err '--label needs a value'; exit 2; }
            label="$2"; shift 2
            ;;
          --limit)
            [ -n "${2:-}" ] || { _ir_err '--limit needs a value'; exit 2; }
            limit="$2"; shift 2
            ;;
          *) _ir_err "list: unknown flag '$1'"; exit 2 ;;
        esac
      done
      # ALM (tracker) backend FIRST — fail loud on an unrecognised backend (DR1)
      # before any gh/Jira call; `jira` routes P1 list-dispatchable through the
      # Jira adapter, `github` falls through to the unchanged git-host switch.
      local alm
      alm="$(_ir_alm)" || exit 1
      if [ "$alm" = "jira" ]; then
        _ir_jira_list "$state" "$label" "$limit"
      elif [ "$alm" = "azdo" ]; then
        _ir_azdo_list "$state" "$label" "$limit"
      elif [ "$alm" != "github" ]; then
        _ir_unknown_alm "$alm"
      else
        local host
        host="$(_ir_host)"
        case "$host" in
          github)
            local gh_args=(--state "$state" --json "number,title,body,labels,assignees,state")
            [ -n "$label" ]  && gh_args+=(--label "$label")
            [ "$limit" -gt 0 ] && gh_args+=(--limit "$limit")
            gh issue list "${gh_args[@]}"
            ;;
          forgejo)
            _ir_forgejo_list "$(_ir_origin)" "$state" "$label" "$limit"
            ;;
          *)
            _ir_err "host kind '${host}' has no issue-read adapter — only github and forgejo are supported." \
                    "Add the host to SGE_FORGEJO_HOSTS (';'-separated) or SGE_FORGEJO_DEFAULT_HOST."
            exit 1
            ;;
        esac
      fi
      ;;

    view)
      local n="${2:-}"
      [ -n "$n" ] || _ir_usage 'view needs <number>'
      # ALM (tracker) backend FIRST — fail loud on an unrecognised backend (DR1).
      # On the jira backend the id is an issueKey (PROJ-123), not an integer, so
      # the integer validation below is scoped to the github backend; jira-adapter
      # applies its own strict issueKey character-class check before URL build.
      local alm
      alm="$(_ir_alm)" || exit 1
      if [ "$alm" = "jira" ]; then
        _ir_jira_view "$n"
      elif [ "$alm" = "azdo" ]; then
        _ir_azdo_view "$n"
      elif [ "$alm" != "github" ]; then
        _ir_unknown_alm "$alm"
      else
        case "$n" in
          *[!0-9]*) _ir_err "view: issue number must be a positive integer, got '${n}'"; exit 2 ;;
        esac
        local host
        host="$(_ir_host)"
        case "$host" in
          github)
            gh issue view "$n" --json "number,title,body,labels,assignees,state"
            ;;
          forgejo)
            _ir_forgejo_view "$(_ir_origin)" "$n"
            ;;
          *)
            _ir_err "host kind '${host}' has no issue-read adapter"
            exit 1
            ;;
        esac
      fi
      ;;

    dependencies)
      local n="${2:-}"
      [ -n "$n" ] || _ir_usage 'dependencies needs <number>'
      local alm
      alm="$(_ir_alm)" || exit 1
      if [ "$alm" = "jira" ]; then
        _ir_jira_dependencies "$n"
      elif [ "$alm" = "azdo" ]; then
        bash "$_AA" item-dependencies "$n"
      elif [ "$alm" != "github" ]; then
        _ir_unknown_alm "$alm"
      else
        case "$n" in
          *[!0-9]*) _ir_err "dependencies: issue number must be a positive integer, got '${n}'"; exit 2 ;;
        esac
        local host
        host="$(_ir_host)"
        case "$host" in
          github)  _ir_github_dependencies "$n" ;;
          forgejo) _ir_forgejo_dependencies "$n" ;;
          *)       _ir_err "host kind '${host}' has no issue-read adapter"; exit 1 ;;
        esac
      fi
      ;;

    search)
      shift
      local search_text="${1:-}"
      [ -n "$search_text" ] || _ir_usage 'search needs <text>'
      shift
      local state="open" limit=0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --state)
            [ -n "${2:-}" ] || { _ir_err '--state needs a value'; exit 2; }
            state="$2"; shift 2
            ;;
          --limit)
            [ -n "${2:-}" ] || { _ir_err '--limit needs a value'; exit 2; }
            limit="$2"; shift 2
            case "$limit" in
              *[!0-9]*) _ir_err "--limit must be a non-negative integer, got '${limit}'"; exit 2 ;;
            esac
            ;;
          *) _ir_err "search: unknown flag '$1'"; exit 2 ;;
        esac
      done
      local alm
      alm="$(_ir_alm)" || exit 1
      if [ "$alm" = "jira" ]; then
        _ir_jira_search "$search_text" "$state" "$limit"
      elif [ "$alm" = "azdo" ]; then
        _ir_azdo_search "$search_text" "$state" "$limit"
      elif [ "$alm" != "github" ]; then
        _ir_unknown_alm "$alm"
      else
        local host
        host="$(_ir_host)"
        case "$host" in
          github)
            local gh_args=(--search "$search_text in:title" --state "$state"
                           --json "number,title,body,labels,assignees,state")
            [ "$limit" -gt 0 ] && gh_args+=(--limit "$limit")
            gh issue list "${gh_args[@]}"
            ;;
          forgejo)
            _ir_forgejo_search "$(_ir_origin)" "$search_text" "$state" "$limit"
            ;;
          *)
            _ir_err "host kind '${host}' has no issue-read adapter"
            exit 1
            ;;
        esac
      fi
      ;;

    dispatch-label)
      local alm
      alm="$(_ir_alm)" || exit 1
      if [ "$alm" = "jira" ]; then
        _ir_jira_dispatch_label
      elif [ "$alm" = "azdo" ]; then
        bash "$_AA" dispatch-label-config
      elif [ "$alm" != "github" ]; then
        _ir_unknown_alm "$alm"
      else
        _ir_github_dispatch_label
      fi
      ;;

    -h|--help|help|'')
      _ir_usage
      ;;
    *)
      _ir_err "unknown command '$cmd'"; exit 2
      ;;
  esac
}

_ir_main "$@"
