#!/usr/bin/env bash
# pr-labels-forgejo.sh — the pr-labels.sh gate state machine on Forgejo/Gitea
# (SPEC-094 §2.2a, enabler #3067 of the #3029 port). Sourced by pr-labels.sh
# ONLY when the origin classifies as `forgejo`; GitHub and Azure Repos never
# load it. Mirrors pr-labels-azdo.sh's shape: one `_prl_forgejo_main`.
#
# This is the SKELETON. Each slice of the port owns one module under
# pr-labels-forgejo.d/ so slices never edit one shared file:
#
#   claim.sh    start-review release-review claim-fix release-fix heartbeat
#               status claim-status claim-work release-work
#               reconcile-orphaned-claim
#   verdict.sh  pass fail shadow-pass review-coverage
#               excluded-reviewer
#   hold.sh     held apply-hold release-hold sync-check stale
#   merge.sh    `pass --auto-merge` arming (no subcommand of its own; called
#               by the verdict slice)
#
# Every module ships as a fail-closed stub: its handler prints a clear "not
# implemented on forgejo" message and returns $_PRL_FJ_NOT_IMPLEMENTED (75),
# never 0. A subcommand outside the list above refuses with exit 2 and makes no
# `gh` call. The exit-code contract is pr-labels.sh's: 2 usage / not ported,
# 3 claim lost, 4 advisory, 6 follow-up, 7 claim not held, 8 hold, 9 shadow /
# not eligible, 1 any other refusal. An adapter or API error is non-zero,
# never a pass (fail closed).
#
# Transitional rule (until every slice has landed): pr-labels.sh treats
# $_PRL_FJ_NOT_IMPLEMENTED together with _PRL_FJ_STUB_HIT=1 (set only by
# _prl_fj_not_implemented) as "this subcommand is not ported yet" and runs its pre-existing inline Forgejo path (#1239) for it, so a
# Forgejo repo keeps today's behaviour. Any other exit code is final. A slice
# that implements a subcommand returns real codes and so takes over from the
# inline path.

_PRL_FJ_NOT_IMPLEMENTED=75
_PRL_FJ_STUB_HIT=0
_PRL_FJ_DIR="${_PRL_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/pr-labels-forgejo.d"

_prl_fj_err() { printf 'pr-labels (forgejo): %s\n' "$*" >&2; }

# _prl_fj_not_implemented <slice> <what> — the shared fail-closed stub body.
_prl_fj_not_implemented() {
  _prl_fj_err "'$2' is not implemented on forgejo yet (slice '$1' of #3029) — refusing rather than guessing a pass"
  _PRL_FJ_STUB_HIT=1   # the marker pr-labels.sh requires before it falls through
  return "$_PRL_FJ_NOT_IMPLEMENTED"
}

_prl_fj_slice_of() { # <subcommand> -> slice name, or non-zero when unsupported
  case "$1" in
    start-review|release-review|claim-fix|release-fix|heartbeat|status|claim-status|claim-work|release-work|reconcile-orphaned-claim) echo claim ;;
    pass|fail|shadow-pass|review-coverage|excluded-reviewer) echo verdict ;;
    held|apply-hold|release-hold|sync-check|stale) echo hold ;;
    *) return 1 ;;
  esac
}

_prl_fj_slice_file=""
for _prl_fj_slice_file in claim verdict hold merge; do
  # A missing module is itself a refusal at dispatch time, never a skipped one.
  # shellcheck disable=SC1090
  [ -f "$_PRL_FJ_DIR/$_prl_fj_slice_file.sh" ] && . "$_PRL_FJ_DIR/$_prl_fj_slice_file.sh"
done
unset _prl_fj_slice_file

_prl_forgejo_main() {
  local cmd="${1:-}" pr="${2:-}" slice
  [ "$#" -ge 2 ] || { _prl_fj_err "usage: <subcommand> <pr> [args]"; return 2; }
  shift 2
  slice="$(_prl_fj_slice_of "$cmd")" || {
    _prl_fj_err "'$cmd' is not ported to Forgejo (ports: start-review, release-review, claim-fix, release-fix, heartbeat, status, claim-status, claim-work, release-work, reconcile-orphaned-claim, pass, fail, shadow-pass, sync-check, stale, review-coverage, excluded-reviewer, held, apply-hold, release-hold) — refusing rather than calling gh"
    return 2
  }
  command -v "_prl_fj_$slice" >/dev/null 2>&1 || {
    _prl_fj_err "module '$slice' is missing — refusing (fail closed)"
    return 1
  }
  "_prl_fj_$slice" "$cmd" "$pr" "$@"
}
