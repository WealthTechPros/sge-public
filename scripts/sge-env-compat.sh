#!/usr/bin/env bash
# sge-env-compat.sh — SGD_ -> SGE_ env-var fallback shim.
# SGD_ fallback: remove in SGD rename Phase 6 (delete this file and its sourcing).
#
# Usage (sourced):  sge_env_compat JIRA_PROJECT DISPATCH_LABEL ...
# For each NAME: if SGE_<NAME> is unset/empty and SGD_<NAME> is set, export
# SGE_<NAME> from it and print ONE deprecation line to stderr. SGE_ wins when set.
#
# ALL Jira settings (every JIRA_* name passed) are ONE unit, so values from two
# environments are never mixed (a colliding project key or transition id across
# tenants would otherwise be silent): SGD_ fallback applies only when NO SGE_JIRA_*
# member is set; if some SGE_ member is set and an SGD_ member would fill another,
# it fails closed (exit 1, variable names only, never values).
sge_env_compat() {
  # Never trace: the loop expands credential values (SGE_JIRA_BEARER etc.); under
  # `bash -x` or SHELLOPTS=xtrace those expansions would echo secrets to stderr.
  local - n s d any_sge=0
  { set +x; } 2>/dev/null
  for n in "$@"; do
    case "$n" in JIRA_*) s="SGE_$n"; [ -z "${!s:-}" ] || any_sge=1;; esac
  done
  for n in "$@"; do
    s="SGE_$n"; d="SGD_$n"
    case "$n" in JIRA_*)
      if [ "$any_sge" = 1 ] && [ -z "${!s:-}" ] && [ -n "${!d:-}" ]; then
        printf 'error: %s is set but a mixed SGE_/SGD_ Jira connection is refused; set the whole SGE_JIRA_* group (or unset it to use the SGD_ group)
' "$d" >&2
        exit 1
      fi;;
    esac
    s="SGE_$n"; d="SGD_$n"
    if [ -z "${!s:-}" ] && [ -n "${!d:-}" ]; then
      export "$s=${!d}"
      printf 'deprecated: %s is read as %s; set %s\n' "$d" "$s" "$s" >&2
    fi
  done
}
