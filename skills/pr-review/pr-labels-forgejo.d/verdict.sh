# shellcheck shell=bash
# pr-labels-forgejo.d/verdict.sh — verdict slice of the Forgejo review-gate port
# (#3029, slice S2 #3069; enabler #3067). Sourced by pr-labels-forgejo.sh; not
# executable.
#
# Owns `pass`, `fail` and `shadow-pass` (logic in ../pr-labels-forgejo-verdict.sh,
# REST verbs in scripts/forgejo-adapter.d/verdict.sh). The other two verdict
# subcommands (review-coverage, excluded-reviewer) belong to
# other slices and remain fail-closed stubs: exit 75 with the stub marker, so
# pr-labels.sh runs its pre-existing inline path for them.
_prl_fj_verdict() { # <subcommand> <pr> [args...]
  local lib="$_PRL_FJ_DIR/../pr-labels-forgejo-verdict.sh" cmd="$1" pr="$2"
  case "$cmd" in
    pass|fail|shadow-pass) : ;;
    *) _prl_fj_not_implemented verdict "$cmd"; return ;;
  esac
  [[ "$pr" =~ ^[0-9]+$ ]] || { _prl_fj_err "<pr> must be a PR number, got '$pr'"; return 2; }
  # A missing library is a refusal, never a skipped verdict.
  [ -f "$lib" ] || { _prl_fj_err "verdict library pr-labels-forgejo-verdict.sh is missing — refusing"; return 1; }
  # shellcheck disable=SC1090
  . "$lib" || { _prl_fj_err "verdict library could not be loaded — refusing"; return 1; }
  shift 2
  _prl_fj_vd_dispatch "$cmd" "$pr" "$@"
}
