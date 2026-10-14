# shellcheck shell=bash
# pr-labels-forgejo.d/merge.sh — merge slice of the Forgejo review-gate port
# (#3029, slice S4 #3071). Sourced by pr-labels-forgejo.sh; not executable.
#
# `pass --auto-merge` arming has no subcommand of its own: the verdict slice
# calls this once a pass is recorded:
#   _prl_fj_merge pass|arm <pr> --expect-head <reviewed-head-sha>
# The reviewed head is REQUIRED (arming is pinned to it). All logic lives in
# pr-labels-forgejo-merge.sh; a missing library is a refusal, never a skip.
_PRL_FJM_LIB="${_PRL_FJ_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/../pr-labels-forgejo-merge.sh"
# shellcheck disable=SC1090
[ -f "$_PRL_FJM_LIB" ] && . "$_PRL_FJM_LIB"

_prl_fj_merge() { # <subcommand> <pr> [--expect-head <sha>]
  local sub="${1:-}" pr="${2:-}" expect="" a
  case "$sub" in pass|arm) ;; *)
    _prl_fj_err "merge: unsupported subcommand '$sub' (use: pass|arm <pr> --expect-head <sha>)"; return 2 ;;
  esac
  shift 2 || { _prl_fj_err "merge: usage: $sub <pr> --expect-head <sha>"; return 2; }
  while [ "$#" -gt 0 ]; do
    a="$1"
    case "$a" in
      --expect-head) [ "$#" -ge 2 ] || { _prl_fj_err "merge: --expect-head needs a value"; return 2; }
                     expect="$2"; shift 2 ;;
      --auto-merge) shift ;;   # implied: this module IS the arming step
      *) _prl_fj_err "merge: unknown argument '$a'"; return 2 ;;
    esac
  done
  command -v _prl_fj_merge_arm >/dev/null 2>&1 || {
    _prl_fj_err "merge library pr-labels-forgejo-merge.sh is missing — refusing to arm merge (fail closed)"
    return 1
  }
  _prl_fj_merge_arm "$pr" "$expect"
}
