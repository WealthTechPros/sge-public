#!/usr/bin/env bash
# pr-labels-azdo.sh — the pr-labels.sh gate state machine on Azure Repos
# (SPEC-110 S4, issue #2985). Sourced by pr-labels.sh ONLY when the origin
# classifies as `azdo`; the GitHub/Forgejo paths never load it.
#
# Mapping:
#   labels          -> PR tags (pr-reviewing, pr-reviewed, changes-requested, hold)
#   review claim    -> azdo-adapter.sh pr-claim: a git ref created by compare-
#                      and-swap, so two racers resolve to exactly one winner
#                      (PR tags have no revision guard; the tag is display only)
#   verdict         -> azdo-adapter.sh pr-verdict: a closed thread + reviewer
#                      vote (pass 10, fail -5) bound to the --expect-head commit
#   CI gate         -> azdo-adapter.sh pr-ci: the DP5 tri-state; ONLY `green`
#                      passes (indeterminate is never green, DR3/DR8)
#
# Supported subcommands: start-review, release-review, status, pass, fail.
# Every other pr-labels.sh subcommand REFUSES on Azure Repos (exit 2) rather
# than falling through to `gh` against a repo gh cannot see.
#
#   start-review <pr> [--force-claim]                         exit 3 = claim lost
#   release-review <pr> [--force]
#   status <pr>                     "reviewing=<b> reviewed=<b>" + claim line
#   pass <pr> --expect-head <sha> [--verdict-file <f>] [--skip-thread-check] [--skip-claim-check]
#       refuses: advisory (4) / shadow (9) dispatch, hold tag (8), this agent
#       not holding the current claim generation (7; pass AND fail), draft,
#       head moved, CI not green, unresolved
#       threads. --auto-merge is refused: Azure DevOps auto-complete is not
#       wired (merge via fpr_merge, which re-checks every gate).
#   fail <pr> --expect-head <sha> [--verdict-file <f>]
#
# Exit codes follow pr-labels.sh's: 3 claim, 4 advisory, 7 claim-check,
# 8 hold, 9 shadow, 1 any other refusal, 2 usage / not ported.

_prl_azdo_err() { printf 'pr-labels (azdo): %s\n' "$*" >&2; }

_prl_azdo_main() {
  local cmd="$1" pr="$2"
  shift 2
  local aa origin
  aa="$_PRL_SCRIPT_DIR/../../scripts/azdo-adapter.sh"
  origin="$_PRL_ORIGIN"
  [ -f "$aa" ] || { _prl_azdo_err "azdo-adapter.sh not found"; return 1; }
  command -v jq >/dev/null 2>&1 || { _prl_azdo_err "jq is required"; return 1; }
  # This script IS the review lane's explicit write path (the forgejo block in
  # pr-labels.sh makes the same decision for FORGEJO_ADAPTER_ALLOW_WRITE).
  export AZDO_ADAPTER_ALLOW_WRITE=1

  _prl_azdo_labels() { # -> one label per line, or non-zero
    bash "$aa" get-pr "$origin" "$pr" | jq -r '.labels[].name' | tr -d '\r'
  }
  _prl_azdo_has() { printf '%s\n' "$1" | grep -qxF -- "$2"; }
  _prl_azdo_status() {
    local l rv=false rd=false
    l="$(_prl_azdo_labels)" || { _prl_azdo_err "could not read labels for PR #$pr"; return 1; }
    _prl_azdo_has "$l" pr-reviewing && rv=true
    _prl_azdo_has "$l" pr-reviewed && rd=true
    printf 'reviewing=%s reviewed=%s\n' "$rv" "$rd"
  }
  _prl_azdo_body() { # <verdict-file-or-empty> <default-text> -> path of a body file
    local f
    if [ -n "$1" ]; then
      [ -f "$1" ] || { _prl_azdo_err "--verdict-file '$1' not found"; return 1; }
      printf '%s' "$1"; return 0
    fi
    f="$(mktemp "${TMPDIR:-/tmp}/sge-azdo-verdict.XXXXXX")" || return 1
    printf '%s\n' "$2" > "$f"
    printf '%s' "$f"
  }

  case "$cmd" in
    start-review)
      local force=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --force-claim) force="--force"; shift ;;
          *) _prl_azdo_err "unknown option '$1' for start-review"; return 2 ;;
        esac
      done
      local rc=0
      bash "$aa" pr-claim "$origin" "$pr" reviewing $force >/dev/null || rc=$?
      case "$rc" in
        0) : ;;
        3) _prl_azdo_err "refusing: PR #$pr is claimed by another review (exit 3)"; return 3 ;;
        *) _prl_azdo_err "could not claim PR #$pr"; return 1 ;;
      esac
      bash "$aa" pr-add-label "$origin" "$pr" pr-reviewing || { _prl_azdo_err "claim won but the pr-reviewing tag could not be added"; return 1; }
      bash "$aa" pr-remove-label "$origin" "$pr" pr-reviewed || _prl_azdo_err "warning: could not remove pr-reviewed"
      echo "PR #$pr: review claimed ($(_prl_azdo_status 2>/dev/null || echo 'label_status unavailable'))"
      ;;
    release-review)
      local force=""
      [ "${1:-}" = "--force" ] && force="--force"
      bash "$aa" pr-release-claim "$origin" "$pr" reviewing $force || return 1
      bash "$aa" pr-remove-label "$origin" "$pr" pr-reviewing || return 1
      echo "PR #$pr: review claim released"
      ;;
    status)
      _prl_azdo_status || return 1
      bash "$aa" pr-claim-status "$origin" "$pr" reviewing || return 1
      ;;
    pass|fail)
      local expect="" vfile="" skip_threads=false skip_claim=false
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --expect-head) [ "$#" -ge 2 ] || { _prl_azdo_err "--expect-head needs a sha"; return 2; }; expect="$2"; shift 2 ;;
          --verdict-file) [ "$#" -ge 2 ] || { _prl_azdo_err "--verdict-file needs a path"; return 2; }; vfile="$2"; shift 2 ;;
          --skip-thread-check) skip_threads=true; shift ;;
          --skip-claim-check) skip_claim=true; shift ;;
          --auto-merge) _prl_azdo_err "refusing: --auto-merge is not wired on Azure DevOps (merge with fpr_merge, which re-checks every gate)"; return 1 ;;
          *) _prl_azdo_err "unknown option '$1' for $cmd"; return 2 ;;
        esac
      done
      # Same mechanical backstops as the GitHub path (#754, #2651).
      if [ "$cmd" = pass ] && [ "${SGE_REVIEW_ADVISORY:-}" = "1" ]; then
        _prl_azdo_err "refusing: SGE_REVIEW_ADVISORY=1 — advisory dispatch cannot move the gate"; return 4
      fi
      if [ "$cmd" = pass ] && [ "${SGE_REVIEW_SHADOW:-}" = "1" ]; then
        _prl_azdo_err "refusing: SGE_REVIEW_SHADOW=1 — shadow dispatch never applies pr-reviewed"; return 9
      fi
      [ -n "$expect" ] || { _prl_azdo_err "refusing: $cmd needs --expect-head on Azure DevOps (the verdict is bound to the head judged)"; return 1; }
      local pj head labels
      pj="$(bash "$aa" get-pr "$origin" "$pr")" || { _prl_azdo_err "could not read PR #$pr"; return 1; }
      head="$(printf '%s' "$pj" | jq -r '.headRefOid' | tr -d '\r')"
      labels="$(printf '%s' "$pj" | jq -r '.labels[].name' | tr -d '\r')"
      # A verdict needs THIS agent to hold the current claim generation, not
      # just a pr-reviewing tag (tags are display only): an agent that lost the
      # claim race must never record a verdict (PR #2986 review).
      if [ "$skip_claim" != true ]; then
        local cs
        cs="$(bash "$aa" pr-claim-status "$origin" "$pr" reviewing)" \
          || { _prl_azdo_err "refusing: claim state for PR #$pr is unreadable (fail closed)"; return 1; }
        case " $cs " in
          *" claimed=true "*" mine=true "*) : ;;
          *) _prl_azdo_err "refusing: this agent does not hold PR #$pr's review claim ($cs) — run start-review first (exit 7)"; return 7 ;;
        esac
      fi
      if [ "$cmd" = pass ]; then
        _prl_azdo_has "$labels" hold && { _prl_azdo_err "refusing: PR #$pr carries the hold tag (exit 8)"; return 8; }
        [ "$(printf '%s' "$pj" | jq -r '.isDraft')" != "true" ] || { _prl_azdo_err "refusing: PR #$pr is a draft"; return 1; }
        local ci result
        ci="$(bash "$aa" pr-ci "$origin" "$pr")" || { _prl_azdo_err "refusing: CI state for PR #$pr is unreadable (fail closed)"; return 1; }
        result="$(printf '%s' "$ci" | jq -r '.result' | tr -d '\r')"
        if [ "$result" != green ]; then
          _prl_azdo_err "refusing: PR #$pr CI is $result — $(printf '%s' "$ci" | jq -r '.reasons | join("; ")') (DP5: only green passes)"
          return 1
        fi
        if [ "$skip_threads" != true ]; then
          local th
          th="$(bash "$aa" pr-threads "$origin" "$pr")" || { _prl_azdo_err "refusing: unresolved-thread state unreadable (fail closed)"; return 1; }
          [ "$(printf '%s' "$th" | jq 'length')" -eq 0 ] || { _prl_azdo_err "refusing: PR #$pr has unresolved threads"; return 1; }
        fi
      fi
      local body rc=0 verdict=approve
      [ "$cmd" = fail ] && verdict=wait
      body="$(_prl_azdo_body "$vfile" "SGE PR review: $(printf '%s' "$cmd" | tr 'a-z' 'A-Z') at $head")" || return 1
      bash "$aa" pr-verdict "$origin" "$pr" "$verdict" "$expect" "$body" >/dev/null || rc=$?
      [ -n "$vfile" ] || rm -f "$body"
      case "$rc" in
        0) : ;;
        6) _prl_azdo_err "refusing: PR #$pr head moved since review (reviewed $expect, now $head) — re-review the new head"; return 1 ;;
        *) _prl_azdo_err "could not record the $cmd verdict on PR #$pr"; return 1 ;;
      esac
      if [ "$cmd" = pass ]; then
        bash "$aa" pr-add-label "$origin" "$pr" pr-reviewed || { _prl_azdo_err "vote recorded but pr-reviewed could not be added"; return 1; }
        bash "$aa" pr-remove-label "$origin" "$pr" changes-requested || true
      else
        bash "$aa" pr-add-label "$origin" "$pr" changes-requested || { _prl_azdo_err "vote recorded but changes-requested could not be added"; return 1; }
        bash "$aa" pr-remove-label "$origin" "$pr" pr-reviewed || true
      fi
      bash "$aa" pr-remove-label "$origin" "$pr" pr-reviewing || true
      bash "$aa" pr-release-claim "$origin" "$pr" reviewing >/dev/null 2>&1 \
        || _prl_azdo_err "warning: the review claim ref could not be released (release-review --force clears it)"
      echo "PR #$pr: $cmd recorded at ${head:0:9} ($(_prl_azdo_status 2>/dev/null || echo 'label_status unavailable'))"
      ;;
    *)
      _prl_azdo_err "'$cmd' is not ported to Azure DevOps (SPEC-110 S4 ports start-review, release-review, status, pass, fail) — refusing rather than calling gh"
      return 2
      ;;
  esac
}
