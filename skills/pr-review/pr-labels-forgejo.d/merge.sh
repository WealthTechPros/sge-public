# shellcheck shell=bash
# pr-labels-forgejo.d/merge.sh — merge slice of the Forgejo review-gate port
# (#3029, enabler #3067). Sourced by pr-labels-forgejo.sh; not executable.
#
# `pass --auto-merge` arming has no subcommand of its own: the verdict slice
# calls this once a pass is recorded. Fail-closed stub: refuses, never arms.
_prl_fj_merge() { # <subcommand> <pr> [args...]
  _prl_fj_not_implemented merge "$1"
}
