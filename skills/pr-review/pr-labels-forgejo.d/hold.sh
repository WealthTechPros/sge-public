# shellcheck shell=bash
# pr-labels-forgejo.d/hold.sh — hold slice of the Forgejo review-gate port
# (#3029, enabler #3067). Sourced by pr-labels-forgejo.sh; not executable.
#
# Fail-closed stub. The slice that owns "hold" replaces the body with a
# `case "$1"` over its subcommands returning pr-labels.sh's exit codes.
# Until then every subcommand routed here is refused, never passed.
_prl_fj_hold() { # <subcommand> <pr> [args...]
  _prl_fj_not_implemented hold "$1"
}
