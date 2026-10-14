# shellcheck shell=bash
# pr-labels-forgejo-hold.sh — the hold slice of the Forgejo review-gate port
# (SPEC-094 §2.2a, slice S3 #3070 of #3029). Sourced by
# pr-labels-forgejo.d/hold.sh when pr-labels.sh runs on a `forgejo` host;
# GitHub and Azure Repos never load it. Not executable.
#
# Subcommands (pr-labels.sh's contract and exit codes):
#   held <pr>            review passed but `hold` is present: release
#                        pr-reviewing (and a stale changes-requested), NEVER
#                        apply pr-reviewed.
#   apply-hold <pr> [--reason r --head sha --categories csv --session id --order id]
#                        apply `hold`; with --reason also record a
#                        sge-hold-marker comment (reason, head, categories).
#   release-hold <pr> --order <id> --head <sha>
#                        exit 2 usage, 4 advisory, 9 shadow, then 9: no
#                        delegation policy is wired for Forgejo (the
#                        eligibility reader is GitHub-only), a human releases it.
#   sync-check <pr> <new-head>
#                        strip a verdict label (pr-reviewed, changes-requested,
#                        agent-reviewed) whose newest trusted verdict judged
#                        another head. Never touches `hold`.
#   stale <pr>           new commits after a pass: drop pr-reviewed and report
#                        a pr-reviewing claim that is still present.
#
# Fail closed throughout. A label read or write that errors is a non-zero exit,
# never a pass; an unreadable verdict list retains the label and exits 1. No
# `gh` call is made: labels go through fpr_add_label / fpr_remove_label
# (skills/lib/forgejo-pr-mutate.sh) and reads through forgejo-adapter.sh.
#
# Reading verdicts. A verdict is the fenced `sge-verdict` block of a review or
# an issue comment, judged by gate-labels.sh's GL_VERDICT_JQ exactly as on
# GitHub (one extraction and trust rule, never a second copy): only the review
# identity counts (REVIEW_DAEMON_TRUSTED_VERDICT_AUTHORS, else wtp-sge[bot]), a
# malformed / edited / ambiguous block is a blocking `malformed` row, never
# skipped. Gitea reviews carry no edit stamp (submitted_at == updated_at), so a
# review cannot be shown edited; a comment can, and an edited one is malformed.
#
# NOTE: pr-labels.sh runs a module as `_prl_forgejo_main ... || rc=$?`, which
# disables errexit for the whole call tree, so every command below is checked
# explicitly.

_prl_fjh_err() { printf 'pr-labels (forgejo): %s\n' "$*" >&2; }

_FJH_ADAPTER=""
_FJH_ORIGIN=""
_FJH_READY=0

# _prl_fjh_ctx — resolve the adapter, the origin and jq, and load the mutating
# label shim once. Non-zero (fail closed) when any of them is missing.
_prl_fjh_ctx() {
  [ "$_FJH_READY" = 1 ] && return 0
  command -v jq >/dev/null 2>&1 || { _prl_fjh_err "jq is required"; return 1; }
  local dir="${_PRL_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  _FJH_ADAPTER="${_PRL_ADAPTER:-$dir/../../scripts/forgejo-adapter.sh}"
  [ -f "$_FJH_ADAPTER" ] || { _prl_fjh_err "forgejo-adapter.sh not found at $_FJH_ADAPTER"; return 1; }
  if [ -n "${_PRL_ORIGIN:-}" ]; then
    _FJH_ORIGIN="$_PRL_ORIGIN"
  else
    _FJH_ORIGIN="$(git remote get-url origin 2>/dev/null)" \
      || { _prl_fjh_err "no 'origin' remote found"; return 1; }
  fi
  [ -n "$_FJH_ORIGIN" ] || { _prl_fjh_err "empty origin"; return 1; }
  local lib="$dir/../lib/forgejo-pr-mutate.sh" _e=0 _u=0 _pf=off
  [ -f "$lib" ] || { _prl_fjh_err "forgejo-pr-mutate.sh not found at $lib"; return 1; }
  case $- in *e*) _e=1 ;; esac
  case $- in *u*) _u=1 ;; esac
  case "$(set -o | awk '$1 == "pipefail" { print $2 }')" in on) _pf=on ;; esac
  # shellcheck source=skills/lib/forgejo-pr-mutate.sh
  . "$lib" || { _prl_fjh_err "could not load $lib"; return 1; }
  # The library sets -euo pipefail; hand the caller's shell options back.
  [ "$_e" = 1 ] || set +e
  [ "$_u" = 1 ] || set +u
  [ "$_pf" = on ] || set +o pipefail
  # Pin the shim to THIS tree's adapter and to the origin pr-labels.sh already
  # classified as forgejo (it honours FORGEJO_ORIGIN, which the shim does not).
  _FPR_ADAPTER="$_FJH_ADAPTER"
  _FPR_HOST_KIND="forgejo"
  _fpr_origin_url() { printf '%s' "$_FJH_ORIGIN"; }
  _FJH_READY=1
}

_prl_fjh_adapter() { bash "$_FJH_ADAPTER" "$@"; }

# _prl_fjh_labels <pr> -> the PR's label names, one per line (possibly none).
# Non-zero when the PR cannot be read or carries no `labels` array.
_prl_fjh_labels() {
  local pj out
  pj="$(_prl_fjh_adapter get-pr "$_FJH_ORIGIN" "$1")" || return 1
  out="$(printf '%s' "$pj" | jq -r 'if (.labels | type) == "array" then .labels[] | .name else error("no labels array") end')" \
    || return 1
  printf '%s' "$out" | tr -d '\r'
}

_prl_fjh_has() { printf '%s\n' "$1" | grep -qxF -- "$2"; }

# _prl_fjh_ensure_label <name> <color> <description>
_prl_fjh_ensure_label() {
  FORGEJO_ADAPTER_ALLOW_WRITE=1 _prl_fjh_adapter pr-ensure-label "$_FJH_ORIGIN" "$1" "$2" "$3" >/dev/null
}

# _prl_fjh_release_claim — best effort: drop THIS agent's review claim (the
# claim slice's pr-release-claim verb). The claim self-expires, so a failure
# (or a tree where the verb is absent) is a warning, never a refusal.
_prl_fjh_release_claim() { # <pr>
  if ! FORGEJO_ADAPTER_ALLOW_WRITE=1 _prl_fjh_adapter pr-release-claim "$_FJH_ORIGIN" "$1" reviewing >/dev/null 2>&1; then
    _prl_fjh_err "warning: the review claim of PR #$1 could not be released (it self-expires; release-review --force clears it)"
  fi
}

# _prl_fjh_comment <pr> <body-file> -- post one comment. Non-zero on failure.
_prl_fjh_comment() {
  FORGEJO_ADAPTER_ALLOW_WRITE=1 _prl_fjh_adapter pr-hold-comment-post "$_FJH_ORIGIN" "$1" "$2" >/dev/null
}

# _prl_fjh_verdict_rows <pr> -- "<ts>\t<sha>\t<verdict>" rows of every trusted
# verdict node, oldest first. Returns 3 when reviews or comments are unreadable
# (callers must not mistake an outage for "no verdict").
_prl_fjh_verdict_rows() {
  local pr="$1" reviews comments rv cm rr rc all dir
  dir="${_PRL_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  [ -f "$dir/gate-labels.sh" ] || { _prl_fjh_err "gate-labels.sh not found"; return 3; }
  # shellcheck source=skills/pr-review/gate-labels.sh
  . "$dir/gate-labels.sh" || return 3
  reviews="$(_prl_fjh_adapter pr-hold-reviews "$_FJH_ORIGIN" "$pr")" || return 3
  comments="$(_prl_fjh_adapter pr-hold-comments "$_FJH_ORIGIN" "$pr")" || return 3
  # Map Gitea's review shape onto the field names GL_VERDICT_JQ reads (the
  # GitHub REST shape): REQUEST_CHANGES is CHANGES_REQUESTED, a dismissed
  # review is DISMISSED (a withdrawn verdict, never a pass).
  rv="$(printf '%s' "$reviews" | jq -c 'map({body: (.body // ""),
      state: (if .dismissed == true then "DISMISSED"
              else ((.state // "") | ascii_upcase | if . == "REQUEST_CHANGES" then "CHANGES_REQUESTED" else . end) end),
      submitted_at, user: {login: (.user.login // "")}})')" || return 3
  cm="$(printf '%s' "$comments" | jq -c 'map({body: (.body // ""), created_at, updated_at,
      user: {login: (.user.login // "")}})')" || return 3
  rr="$(printf '%s' "$rv" | GL_PR_AUTHOR="" GL_NODE_SOURCE=review jq -r "$GL_VERDICT_JQ")" || return 3
  rc="$(printf '%s' "$cm" | GL_PR_AUTHOR="" GL_NODE_SOURCE=comment jq -r "$GL_VERDICT_JQ")" || return 3
  all="$(printf '%s\n%s\n' "$rr" "$rc" | tr -d '\r' | grep -v '^[[:space:]]*$' || true)"
  # Every row is <ts><TAB><sha><TAB><verdict>; anything else is a broken read.
  if [ -n "$all" ] && ! printf '%s\n' "$all" | awk -F'\t' 'NF != 3 { bad = 1 } END { exit bad }'; then
    return 3
  fi
  [ -z "$all" ] || printf '%s\n' "$all" | LC_ALL=C sort -s -t "$(printf '\t')" -k1,1
  return 0
}

# ---- held ------------------------------------------------------------------
_prl_fjh_held() { # <pr>
  local pr="$1" labels
  _prl_fjh_remove_label_checked "$pr" pr-reviewing || return 1
  # The review PASSED: it must not still read as failed (#2238).
  _prl_fjh_remove_label_checked "$pr" changes-requested || return 1
  # pr-reviewed is deliberately NOT applied while a hold is present.
  _prl_fjh_release_claim "$pr"
  labels="$(_prl_fjh_labels "$pr")" \
    || { _prl_fjh_err "PR #$pr: held — the label state is unreadable after the release (fail closed)"; return 1; }
  if _prl_fjh_has "$labels" pr-reviewing; then
    _prl_fjh_err "PR #$pr: held — pr-reviewing is still present after the release (fail closed)"
    return 1
  fi
  if _prl_fjh_has "$labels" hold; then
    echo "PR #$pr: review passed — held for human sign-off (hold=true)"
  else
    echo "PR #$pr: review passed — held for human sign-off (hold=false: no 'hold' label is present, so a pass is not blocked by it)"
  fi
  echo "Remove the 'hold' label once sign-off is obtained; the next review cycle will promote normally."
}

# _prl_fjh_remove_label_checked <pr> <label>
_prl_fjh_remove_label_checked() {
  fpr_remove_label "$1" "$2" >/dev/null || { _prl_fjh_err "could not remove '$2' from PR #$1 (fail closed)"; return 1; }
}

# ---- apply-hold ------------------------------------------------------------
_prl_fjh_apply_hold() { # <pr> [args...]
  local pr="$1" reason="" head="" cats="" session="" order="" body rc=0
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) reason="${2:-}"; shift 2 ;;
      --head) head="${2:-}"; shift 2 ;;
      --categories) cats="${2:-}"; shift 2 ;;
      --session) session="${2:-}"; shift 2 ;;
      --order) order="${2:-}"; shift 2 ;;
      *) _prl_fjh_err "apply-hold: unknown argument '$1'"; return 2 ;;
    esac
  done
  if [ -n "$head" ] && ! [[ "$head" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    _prl_fjh_err "apply-hold: --head '$head' is not a 7-40 hex commit id"
    return 2
  fi
  _prl_fjh_ensure_label hold B60205 "Held for human sign-off (SGE)" \
    || { _prl_fjh_err "could not ensure the 'hold' label exists (fail closed)"; return 1; }
  fpr_add_label "$pr" hold >/dev/null \
    || { _prl_fjh_err "could not add 'hold' to PR #$pr (fail closed)"; return 1; }
  if [ -n "$reason" ]; then
    local dir="${_PRL_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
    # shellcheck source=skills/pr-review/delegation-policy.sh
    . "$dir/delegation-policy.sh" || { _prl_fjh_err "delegation-policy.sh not found"; return 1; }
    [ -n "$session" ] || session="$(dp_session_id)"
    body="$(mktemp "${TMPDIR:-/tmp}/sge-fj-hold.XXXXXX")" || return 1
    if dp_hold_marker_body "$reason" "$head" "$cats" "$session" "$order" > "$body" && _prl_fjh_comment "$pr" "$body"; then
      :
    else
      rc=1
    fi
    rm -f "$body"
    if [ "$rc" -ne 0 ]; then
      _prl_fjh_err "PR #$pr: 'hold' applied but the hold marker (reason/head/categories) could not be recorded (fail closed; the label stands and a human must release it)"
      return 1
    fi
  fi
  echo "PR #$pr: 'hold' label applied — gate will not open until a human removes it"
}

# ---- release-hold ----------------------------------------------------------
_prl_fjh_release_hold() { # <pr> [args...]
  local pr="$1" order="" head=""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --order) order="${2:-}"; shift 2 ;;
      --head) head="${2:-}"; shift 2 ;;
      *) _prl_fjh_err "release-hold: unknown argument '$1'"; return 2 ;;
    esac
  done
  [ -n "$order" ] || { _prl_fjh_err "release-hold needs --order <id>"; return 2; }
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { _prl_fjh_err "release-hold needs --head <full 40-hex sha of the reviewed head>"; return 2; }
  # The same mechanical backstops as `pass`: an advisory or shadow dispatch
  # never moves a gate, and releasing a hold is one.
  if [ "${SGE_REVIEW_ADVISORY:-}" = "1" ]; then
    _prl_fjh_err "refusing: SGE_REVIEW_ADVISORY=1 — advisory (review-only) dispatch cannot release 'hold' (issue #754)"
    return 4
  fi
  if [ "${SGE_REVIEW_SHADOW:-}" = "1" ]; then
    _prl_fjh_err "refusing: SGE_REVIEW_SHADOW=1 — shadow-mode dispatch cannot release 'hold' (issue #2651)"
    return 9
  fi
  # A release is only ever made under a delegation policy's standing order,
  # re-derived from the policy and the PR (dp_hold_release_eligible), never
  # trusted from the caller. That reader is GitHub-only (gh api), so no
  # delegation policy is wired for Forgejo: refuse, a human removes the label.
  _prl_fjh_err "PR #$pr: refusing to release 'hold' under '$order' — no delegation policy is wired for Forgejo; a human removes the label (exit 9)"
  return 9
}

# ---- stale -----------------------------------------------------------------
_prl_fjh_stale() { # <pr>
  local pr="$1" labels
  # Drop the verdict first: a failure to read or write afterwards must not
  # leave pr-reviewed standing over commits it never judged.
  _prl_fjh_remove_label_checked "$pr" pr-reviewed || return 1
  _prl_fjh_release_claim "$pr"
  labels="$(_prl_fjh_labels "$pr")" \
    || { _prl_fjh_err "PR #$pr: stale — the label state is unreadable after the drop (fail closed)"; return 1; }
  if _prl_fjh_has "$labels" pr-reviewed; then
    _prl_fjh_err "PR #$pr: stale — pr-reviewed is still present after the drop (fail closed)"
    return 1
  fi
  echo "PR #$pr: pr-reviewed dropped (stale — new commits since last verdict)"
  if _prl_fjh_has "$labels" pr-reviewing; then
    echo "PR #$pr: stale claim — pr-reviewing is still present; release-review (or its TTL) clears it"
  fi
}

# ---- sync-check ------------------------------------------------------------
_prl_fjh_sync_check() { # <pr> <new-head>
  local pr="$1" nh="${2:-}" dir labels gl rows last vsha state on=() stripped=() failed=0 body
  [[ "$nh" =~ ^[0-9a-fA-F]{7,40}$ ]] || { _prl_fjh_err "sync-check requires <pr> <new-head-sha> (7-40 hex)"; return 2; }
  dir="${_PRL_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  [ -f "$dir/gate-labels.sh" ] || { _prl_fjh_err "gate-labels.sh not found"; return 1; }
  # shellcheck source=skills/pr-review/gate-labels.sh
  . "$dir/gate-labels.sh" || return 1
  # 1) Which verdict labels are on the PR NOW (API read, never the event payload)?
  labels="$(_prl_fjh_labels "$pr")" \
    || { _prl_fjh_err "PR #$pr: sync-check — labels unreadable; nothing stripped (fail closed)"; return 1; }
  for gl in "${GL_VERDICT_LABELS[@]}"; do
    _prl_fjh_has "$labels" "$gl" && on+=("$gl")
  done
  if [ "${#on[@]}" -eq 0 ]; then
    echo "PR #$pr: sync-check — no verdict gate label (${GL_VERDICT_LABELS[*]}), nothing to strip"
    return 0
  fi
  # 2) The newest trusted sge-verdict's commit, across reviews AND comments.
  rows="$(_prl_fjh_verdict_rows "$pr")" \
    || { _prl_fjh_err "PR #$pr: sync-check — verdicts unreadable; labels retained (fail closed)"; return 1; }
  last="$(printf '%s\n' "$rows" | tail -n 1)"
  vsha="$(printf '%s' "$last" | cut -f2)"
  [ "$vsha" = "-" ] && vsha=""
  if [ -z "$vsha" ]; then
    echo "PR #$pr: sync-check — no sge-verdict found; cannot determine coverage; labels retained"
    return 0
  fi
  # 3) Strip each provably stale verdict label; `hold` is not a verdict label.
  for gl in "${on[@]}"; do
    state="$(gl_classify "$gl" "$vsha" "$nh")"
    case "$state" in
      stale)
        if fpr_remove_label "$pr" "$gl" >/dev/null; then
          stripped+=("$gl")
        else
          _prl_fjh_err "could not strip $gl from PR #$pr (fail closed)"
          failed=1
        fi
        ;;
      current) echo "PR #$pr: sync-check — verdict covers head (${vsha:0:12}); $gl retained" ;;
      *) _prl_fjh_err "PR #$pr: sync-check — $gl $state (verdict '$vsha', head '$nh'); label retained" ;;
    esac
  done
  if [ "${#stripped[@]}" -gt 0 ]; then
    # Stripping reverses a completed review without pass/fail, so their claim
    # cleanup never runs: drop the orphaned claim (best effort).
    _prl_fjh_release_claim "$pr"
    echo "PR #$pr: ${stripped[*]} stripped — verdict was pinned to ${vsha:0:12}, new head is ${nh:0:12}"
    body="$(mktemp "${TMPDIR:-/tmp}/sge-fj-sync.XXXXXX")" || return 1
    printf '**%s stripped** (head-scoped gate labels; issue #1941)\n\nThe latest `sge-verdict` was pinned to `%s`; the new head after push is `%s`. A verdict label cannot describe a superseded commit.\n\nA re-review at the new head re-applies the right label.\n' \
      "${stripped[*]}" "$vsha" "$nh" > "$body"
    _prl_fjh_comment "$pr" "$body" \
      || _prl_fjh_err "warning: could not post the staleness comment on PR #$pr (best-effort)"
    rm -f "$body"
  fi
  return "$failed"
}

# ---- entry -----------------------------------------------------------------
_prl_fjh_main() { # <subcommand> <pr> [args...]
  local cmd="${1:-}" pr="${2:-}"
  [ "$#" -ge 2 ] || { _prl_fjh_err "usage: <subcommand> <pr> [args]"; return 2; }
  [[ "$pr" =~ ^[0-9]+$ ]] || { _prl_fjh_err "<pr> must be a PR number, got '$pr'"; return 2; }
  shift 2
  case "$cmd" in
    held|apply-hold|release-hold|stale|sync-check) ;;
    *) _prl_fjh_err "'$cmd' is not a hold-slice subcommand"; return 2 ;;
  esac
  # Arguments are validated before any network call (exit 2 / 4 / 9 backstops
  # make no API request at all).
  case "$cmd" in
    release-hold) _prl_fjh_release_hold "$pr" "$@"; return $? ;;
  esac
  _prl_fjh_ctx || return 1
  case "$cmd" in
    held)       _prl_fjh_held "$pr" ;;
    apply-hold) _prl_fjh_apply_hold "$pr" "$@" ;;
    stale)      _prl_fjh_stale "$pr" ;;
    sync-check) _prl_fjh_sync_check "$pr" "$@" ;;
  esac
}
