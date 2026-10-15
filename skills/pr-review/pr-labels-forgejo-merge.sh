#!/usr/bin/env bash
# pr-labels-forgejo-merge.sh — arm the merge for `pass --auto-merge` on a
# Forgejo/Gitea host (SPEC-094 §2.2a, issue #3071, slice S4 of the #3029 port).
# Sourced by pr-labels-forgejo.d/merge.sh; defines functions only, never runs.
#
# Contract (`_prl_fj_merge_arm <pr> <expect-head>`):
#   * Called ONLY by the verdict slice, after the pass is recorded (the
#     `pr-reviewed` label is on the PR). It never writes a label and never
#     removes one: the recorded pass stands whether arming succeeds or not.
#   * <expect-head> is the FULL 40-hex head the review judged. It is REQUIRED and
#     compared by exact equality (never a prefix, CWE-863). The merge is pinned
#     to that SHA, and Gitea refuses it if the head moves (head_commit_id).
#   * A moved head, a missing protection rule, a rule that cannot enforce the
#     gate, a non-green required context, or any adapter/API error is a
#     refusal (non-zero), never a merge. A refusal and a failed merge request
#     both cancel any scheduled auto-merge, so nothing is left armed.
#   * No `gh` call anywhere: reads and writes go through forgejo-adapter.sh and
#     skills/lib/forgejo-pr-mutate.sh's fpr_merge_ready (in a subshell, so its
#     `set -e` never leaks into pr-labels.sh).
#
# Why fpr_merge_ready + a pinned adapter call rather than fpr_merge: fpr_merge
# resolves the head at call time, so it would pin to whatever head exists then,
# not to the head the review judged (a push between the review and the call
# would be merged unreviewed). The readiness rule is shared; the pin is ours.
#
# Exit codes follow pr-labels.sh: 1 refusal, 2 usage, 4 advisory dispatch,
# 8 hold present, 9 shadow dispatch or PR not eligible (draft, closed, merged).

_PRL_FJM_NAME="pr-labels (forgejo)"
_prl_fjm_err() { printf '%s: %s\n' "$_PRL_FJM_NAME" "$*" >&2; }

# _prl_fjm_paths — resolve the adapter, origin and shim; sets _PRL_FJM_*.
_prl_fjm_paths() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _PRL_FJM_ADAPTER="${_PRL_ADAPTER:-$here/../../scripts/forgejo-adapter.sh}"
  _PRL_FJM_SHIM="${CLAUDE_PLUGIN_ROOT:-$here/../..}/skills/lib/forgejo-pr-mutate.sh"
  _PRL_FJM_ORIGIN="${_PRL_ORIGIN:-}"
  [ -n "$_PRL_FJM_ORIGIN" ] || _PRL_FJM_ORIGIN="$(git remote get-url origin 2>/dev/null)" || _PRL_FJM_ORIGIN=""
  [ -f "$_PRL_FJM_ADAPTER" ] || { _prl_fjm_err "forgejo-adapter.sh not found at $_PRL_FJM_ADAPTER — refusing to arm merge"; return 1; }
  [ -f "$_PRL_FJM_SHIM" ]    || { _prl_fjm_err "forgejo-pr-mutate.sh not found at $_PRL_FJM_SHIM — refusing to arm merge"; return 1; }
  [ -n "$_PRL_FJM_ORIGIN" ]  || { _prl_fjm_err "no origin URL — refusing to arm merge"; return 1; }
}

# _prl_fjm_cancel <pr> — best-effort: make sure no scheduled auto-merge is left
# behind. Idempotent (a 404 means none was scheduled). Never changes the result.
_prl_fjm_cancel() {
  FORGEJO_ADAPTER_ALLOW_WRITE=1 bash "$_PRL_FJM_ADAPTER" pr-automerge-cancel \
    "$_PRL_FJM_ORIGIN" "$1" >/dev/null 2>&1 \
    || _prl_fjm_err "PR #$1: could not confirm that no scheduled merge is left (pr-automerge-cancel failed)"
  return 0
}

# _prl_fjm_protection_gate <branch> <head-sha> — refuse unless the base branch's
# protection can enforce the gate and every required context is green at head.
_prl_fjm_protection_gate() {
  local branch="$1" head="$2" bp ctxs_n approvals en statuses pat missing bad
  local bp_errf bp_code
  bp_errf="$(mktemp 2>/dev/null)" || bp_errf=""
  bp="$(bash "$_PRL_FJM_ADAPTER" branch-protection "$_PRL_FJM_ORIGIN" "$branch" 2>"${bp_errf:-/dev/null}")" || {
    # Surface ONLY a 3-digit status parsed from the adapter's fixed-form line;
    # never echo adapter stderr itself (it is not ours to forward verbatim).
    bp_code=""
    [ -z "$bp_errf" ] || bp_code="$(sed -n 's/.*branch-protection read failed: HTTP \([0-9][0-9][0-9]\).*/\1/p' "$bp_errf" | head -n 1)"
    [ -z "$bp_errf" ] || rm -f "$bp_errf"
    _prl_fjm_err "no readable branch protection for '$branch' (HTTP ${bp_code:-unknown}) — the gate cannot be enforced; refusing to arm merge. Branch protection is readable only by repo admins on Forgejo/Gitea (403, or 404 when hidden from a non-admin): the reviewing identity needs admin on the repo. The merge arm never skips this check for a write-permission identity."
    return 1
  }
  [ -z "$bp_errf" ] || rm -f "$bp_errf"
  en="$(printf '%s' "$bp" | jq -r '.enable_status_check // false' 2>/dev/null)" || en=""
  ctxs_n="$(printf '%s' "$bp" | jq -r '(.status_check_contexts // []) | length' 2>/dev/null)" || ctxs_n=""
  approvals="$(printf '%s' "$bp" | jq -r '.required_approvals // empty' 2>/dev/null)" || approvals=""
  case "$ctxs_n" in ''|*[!0-9]*) _prl_fjm_err "branch protection for '$branch' is unparseable — refusing to arm merge"; return 1 ;; esac
  case "$approvals" in ''|*[!0-9]*) _prl_fjm_err "branch protection for '$branch' has no readable required_approvals — refusing to arm merge"; return 1 ;; esac
  if [ "$en" != "true" ] || [ "$ctxs_n" -eq 0 ]; then
    _prl_fjm_err "branch protection for '$branch' requires no status checks (enable_status_check=$en, contexts=$ctxs_n) — the gate cannot be enforced; refusing to arm merge"
    return 1
  fi
  # #3127: branch protection must itself require the review verdict, or it does
  # not enforce "no merge without a pass". Name defaults to sge/pr-review and is
  # configurable per repo; SGE_FORGEJO_ALLOW_UNREQUIRED_REVIEW_CONTEXT=1 is the
  # explicit operator override.
  if [ "${SGE_FORGEJO_ALLOW_UNREQUIRED_REVIEW_CONTEXT:-}" != "1" ]; then
    local rctx="${SGE_FORGEJO_REVIEW_CONTEXT:-sge/pr-review}" rpat found=0
    while IFS= read -r rpat; do
      rpat="$(printf '%s' "$rpat" | tr -d '\r')"
      # shellcheck disable=SC2254  # Gitea contexts allow glob patterns
      case "$rctx" in $rpat) [ -z "$rpat" ] || found=1 ;; esac
    done < <(printf '%s' "$bp" | jq -r '.status_check_contexts[]?' 2>/dev/null)
    if [ "$found" -ne 1 ]; then
      _prl_fjm_err "branch protection for '$branch' does not require the '$rctx' status context — branch protection would not enforce the review verdict; add it to the required status checks (or set SGE_FORGEJO_ALLOW_UNREQUIRED_REVIEW_CONTEXT=1 to override); refusing to arm merge"
      return 1
    fi
  fi
  statuses="$(bash "$_PRL_FJM_ADAPTER" pr-statuses "$_PRL_FJM_ORIGIN" "$head" 2>/dev/null)" || {
    _prl_fjm_err "could not read commit statuses for ${head:0:9} — refusing to arm merge"
    return 1
  }
  missing=""; bad=""
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    local seen=0 c s
    while IFS=$'\t' read -r c s; do
      # shellcheck disable=SC2254  # glob match is intended (Gitea contexts allow patterns)
      case "$c" in $pat) seen=1; [ "$s" = "success" ] || bad="$bad $c($s)" ;; esac
    done < <(printf '%s' "$statuses" | jq -r '.[] | [(.context // ""), (.state // "")] | @tsv' 2>/dev/null | tr -d '\r')
    [ "$seen" -eq 1 ] || missing="$missing $pat"
  done < <(printf '%s' "$bp" | jq -r '.status_check_contexts[]' 2>/dev/null | tr -d '\r')
  if [ -n "$missing" ] || [ -n "$bad" ]; then
    _prl_fjm_err "required context(s) not green at ${head:0:9} — missing:[${missing# }] not-success:[${bad# }]; refusing to arm merge"
    return 1
  fi
  return 0
}

# _prl_fjm_eligible <pr> <expect-head> — read the PR once and require, against
# THAT read, every precondition: open, not draft, a recorded pass, no hold, and
# the head EXACTLY equal to the reviewed head. Sets _PRL_FJM_HEAD / _PRL_FJM_BASE.
# Called before the gates and again immediately before the merge, so a head push
# or a hold landing while the gates ran is caught (and the merge request itself
# is additionally pinned server-side to the same SHA via head_commit_id).
_prl_fjm_eligible() {
  local pr="$1" expect="$2" pr_json state draft merged head base labels
  pr_json="$(bash "$_PRL_FJM_ADAPTER" get-pr "$_PRL_FJM_ORIGIN" "$pr" 2>/dev/null)" || {
    _prl_fjm_err "PR #$pr: could not read the PR — refusing to arm merge"; return 1; }
  state="$(printf '%s' "$pr_json" | jq -r '.state // empty' 2>/dev/null)" || state=""
  draft="$(printf '%s' "$pr_json" | jq -r 'if .draft == true then "true" else "false" end' 2>/dev/null)" || draft=""
  merged="$(printf '%s' "$pr_json" | jq -r 'if .merged == true then "true" else "false" end' 2>/dev/null)" || merged=""
  head="$(printf '%s' "$pr_json" | jq -r '.head.sha // empty' 2>/dev/null | tr -d '\r' | tr 'A-F' 'a-f')" || head=""
  base="$(printf '%s' "$pr_json" | jq -r '.base.ref // empty' 2>/dev/null | tr -d '\r')" || base=""
  labels="$(printf '%s' "$pr_json" | jq -r '.labels[]?.name' 2>/dev/null | tr -d '\r')" || labels=""
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [ -n "$base" ] && [ -n "$state" ] || {
    _prl_fjm_err "PR #$pr: head SHA / base branch / state not resolvable — refusing to arm merge"; return 1; }

  if [ "$merged" = "true" ] || [ "$state" != "open" ]; then
    _prl_fjm_err "PR #$pr: not open (state=$state merged=$merged) — nothing to arm"; return 9
  fi
  if [ "$draft" = "true" ]; then
    _prl_fjm_err "PR #$pr: is a DRAFT — drafts never auto-merge"; return 9
  fi
  # Only after the verdict is recorded: the pass is the pr-reviewed label.
  if ! printf '%s
' "$labels" | grep -qxF -- "pr-reviewed"; then
    _prl_fjm_err "PR #$pr: no recorded pass (no 'pr-reviewed' label) — merge is armed only after the verdict is recorded"; return 1
  fi
  if printf '%s
' "$labels" | grep -qxF -- "hold"; then
    _prl_fjm_err "PR #$pr: the 'hold' label is present — refusing to arm merge"; return 8
  fi
  # EXACT equality of two full SHAs: a prefix match would let a different commit
  # that merely starts with the reviewed digits ride the review (CWE-863).
  if [ "$head" != "$expect" ]; then
    _prl_fjm_err "PR #$pr: head moved since review (reviewed $expect, now $head) — refusing to arm; run a delta re-review"
    return 1
  fi
  _PRL_FJM_HEAD="$head"; _PRL_FJM_BASE="$base"
  return 0
}

# _prl_fj_merge_arm <pr> <expect-head>   (<expect-head> = the FULL 40-hex SHA)
_prl_fj_merge_arm() {
  local pr="${1:-}" expect="${2:-}" head base rc=0 ready

  [[ "$pr" =~ ^[0-9]+$ ]] || { _prl_fjm_err "merge: <pr> must be a PR number"; return 2; }
  if ! [[ "$expect" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    _prl_fjm_err "merge: the full reviewed head SHA (--expect-head, 40 hex) is required — arming is pinned to the head the review judged"
    return 2
  fi
  expect="$(printf '%s' "$expect" | tr 'A-F' 'a-f')"
  # Defence in depth: the verdict slice refuses these first, but arming is the
  # one irreversible step, so it re-checks and never relies on the caller.
  if [ "${SGE_REVIEW_ADVISORY:-}" = "1" ]; then
    _prl_fjm_err "refusing: SGE_REVIEW_ADVISORY=1 — an advisory dispatch never arms merge (#754)"; return 4
  fi
  if [ "${SGE_REVIEW_SHADOW:-}" = "1" ]; then
    _prl_fjm_err "refusing: SGE_REVIEW_SHADOW=1 — a shadow dispatch never arms merge (#2651)"; return 9
  fi
  command -v jq >/dev/null 2>&1 || { _prl_fjm_err "jq is required to arm merge — refusing"; return 1; }
  _prl_fjm_paths || return 1

  _prl_fjm_eligible "$pr" "$expect"; rc=$?
  if [ "$rc" -ne 0 ]; then
    _prl_fjm_cancel "$pr"
    return "$rc"
  fi
  head="$_PRL_FJM_HEAD"; base="$_PRL_FJM_BASE"   # == $expect, from here on the pin

  _prl_fjm_protection_gate "$base" "$head" || { _prl_fjm_cancel "$pr"; return 1; }

  # Shared readiness rule (linked issue, CI green with a positive signal). It
  # re-reads the PR itself, so it is bracketed: the PR is re-read below and must
  # still be eligible at the SAME head before anything is merged.
  rc=0
  ready="$( ( . "$_PRL_FJM_SHIM" >/dev/null 2>&1 && fpr_merge_ready "$pr" ) 2>/dev/null )" || rc=$?
  if [ "$rc" -ne 0 ] || [ "$ready" != "READY" ]; then
    _prl_fjm_err "PR #$pr: not merge-ready (${ready:-exit $rc}) — refusing to arm merge"
    _prl_fjm_cancel "$pr"
    return 1
  fi
  rc=0
  _prl_fjm_eligible "$pr" "$expect" || rc=$?
  if [ "$rc" -ne 0 ] || [ "$_PRL_FJM_HEAD" != "$head" ]; then
    _prl_fjm_err "PR #$pr: the PR changed while the gates ran — refusing to arm merge"
    _prl_fjm_cancel "$pr"
    return "$([ "$rc" -ne 0 ] && echo "$rc" || echo 1)"
  fi

  rc=0
  FORGEJO_ADAPTER_ALLOW_WRITE=1 bash "$_PRL_FJM_ADAPTER" pr-merge-squash     "$_PRL_FJM_ORIGIN" "$pr" "$head" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    _prl_fjm_err "PR #$pr: merge request failed (exit $rc; a moved head, an unmet server-side rule or an API error) — the recorded pass stands, nothing is armed"
    _prl_fjm_cancel "$pr"
    return 1
  fi
  printf 'PR #%s: merged (squash, Forgejo, pinned to %s)
' "$pr" "${head:0:9}"
  return 0
}
