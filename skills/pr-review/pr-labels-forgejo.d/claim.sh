# shellcheck shell=bash
# pr-labels-forgejo.d/claim.sh — claim slice of the Forgejo review-gate port
# (#3029, slice S1 #3068; enabler #3067). Sourced by pr-labels-forgejo.sh; not
# executable.
#
# Owns start-review, release-review, claim-fix, release-fix, heartbeat and
# status (logic in ../pr-labels-forgejo-claim.sh, mutex in
# scripts/forgejo-adapter.d/claim.sh). The four subcommands the work lane and
# the orphan reconciler need (claim-status, claim-work, release-work,
# reconcile-orphaned-claim) remain fail-closed stubs: exit 75 with the stub
# marker, so pr-labels.sh runs its pre-existing inline path for them.
_prl_fj_claim() { # <subcommand> <pr> [args...]
  local lib="$_PRL_FJ_DIR/../pr-labels-forgejo-claim.sh" cmd="$1" pr="$2"
  case "$cmd" in
    start-review|release-review|claim-fix|release-fix|heartbeat|status) : ;;
    *) _prl_fj_not_implemented claim "$cmd"; return ;;
  esac
  [[ "$pr" =~ ^[0-9]+$ ]] || { _prl_fj_err "<pr> must be a PR number, got '$pr'"; return 2; }
  # A missing library is a refusal, never a skipped claim.
  [ -f "$lib" ] || { _prl_fj_err "claim library pr-labels-forgejo-claim.sh is missing — refusing"; return 1; }
  # shellcheck disable=SC1090
  . "$lib" || { _prl_fj_err "claim library could not be loaded — refusing"; return 1; }
  shift 2
  case "$cmd" in
    start-review)   _prl_fj_cl_start_review "$pr" "$@" ;;
    release-review) _prl_fj_cl_release_review "$pr" "$@" ;;
    claim-fix)      _prl_fj_cl_claim_fix "$pr" "$@" ;;
    release-fix)    _prl_fj_cl_release_fix "$pr" "$@" ;;
    heartbeat)      _prl_fj_cl_heartbeat "$pr" ;;
    status)         _prl_fj_cl_status "$pr" ;;
  esac
}
