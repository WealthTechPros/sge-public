# shellcheck shell=bash
# pr-labels-forgejo.d/hold.sh — hold slice of the Forgejo review-gate port
# (#3029, slice S3 #3070; enabler #3067). Sourced by pr-labels-forgejo.sh; not
# executable.
#
# Owns held, apply-hold, release-hold, and (per the #3070 split) stale and
# sync-check. The implementation is pr-labels-forgejo-hold.sh; this file only
# wires it in. A missing implementation is a refusal (exit 1), never a skipped
# step and never a fall-through to the inline gh path.
_PRL_FJ_HOLD_IMPL="$_PRL_FJ_DIR/../pr-labels-forgejo-hold.sh"
if [ -f "$_PRL_FJ_HOLD_IMPL" ]; then
  # shellcheck source=skills/pr-review/pr-labels-forgejo-hold.sh
  . "$_PRL_FJ_HOLD_IMPL"
fi

_prl_fj_hold() { # <subcommand> <pr> [args...]
  if ! declare -F _prl_fjh_main >/dev/null 2>&1; then
    _prl_fj_err "hold module implementation is missing — refusing (fail closed)"
    return 1
  fi
  _prl_fjh_main "$@"
}
