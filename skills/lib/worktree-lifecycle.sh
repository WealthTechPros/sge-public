#!/usr/bin/env bash
# worktree-lifecycle.sh — deterministic, NON-DESTRUCTIVE worktree lifecycle
# primitives shared by hooks and /sge:tidy-worktrees (issue #3233, epic #3216).
#
#   source skills/lib/worktree-lifecycle.sh
#   wl_register  <worktree> <session-id>   # claim a linked worktree (idempotent)
#   wl_unregister <worktree> <session-id>  # drop OUR registry entry only
#   wl_list [<repo-path>]                  # "<session>\t<path>\t<branch>" rows
#   wl_audit <worktree> <session-id>       # verdict block (see below)
#   bash worktree-lifecycle.sh <register|unregister|list|audit> <args...>
#
# Registry: one file per owned worktree under <git-common-dir>/sge-worktrees/,
# so every linked worktree of a repo shares ONE registry. Entries are written
# atomically (temp file + mv -n). Only a linked worktree of THIS common dir can
# be registered (the main checkout never can), and only the owning session may
# unregister it: a foreign claim is never overwritten or released.
#
# Audit verdict (stdout, exactly two lines):
#   verdict:KEEP|VALUABLE|candidate
#   reason:<token>
# KEEP / VALUABLE are the safe defaults. `candidate` means only "may be offered
# to the user in a deletion plan"; it never authorises deletion, and this file
# deletes nothing. Any uncertainty (open-PR lookup failed or truncated, auth,
# host-adapter error, unresolvable base) yields KEEP/VALUABLE with the reason.
# Cached or empty-on-error PR results never establish safety: the open-PR set
# is read live through hpr_open_pr_heads, which fails closed.
#
# All branch names, paths and ids are untrusted DATA: they are only ever passed
# as quoted arguments, never interpolated into eval/shell text.
#
# Exit codes: 0 ok, 3 not a git worktree, 4 foreign claim, 5 bad session id,
#             6 not a linked worktree of this repo.

_WL_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_WL_HERE/host-pr-read.sh"
# shellcheck source=/dev/null
source "$_WL_HERE/../worktrees/rescue-guard.sh"

_wl_common_dir() { # <path> -> absolute common git dir
  local c
  c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 3
  printf '%s\n' "$c"
}

_wl_abs() { (cd "$1" 2>/dev/null && pwd -P); }

_wl_key() { # stable filename for a path (data, never shell text)
  printf '%s' "$1" | cksum | awk '{print $1 "-" $2}'
}

_wl_valid_session() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

# 0 if <wt> is a LINKED worktree of the repo (not the main checkout).
_wl_is_linked() {
  local wt="$1" common main want p
  common="$(_wl_common_dir "$wt")" || return 3
  main="$(_wl_abs "$(dirname "$common")")"
  want="$(_wl_abs "$wt")"
  [ "$want" != "$main" ] || return 1
  while IFS= read -r p; do
    [ "$(_wl_abs "$p" 2>/dev/null)" = "$want" ] && return 0
  done < <(git -C "$wt" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  return 1
}

_wl_entry_field() { sed -n "s/^$2=//p" "$1" | head -n1; }

wl_register() {
  local wt="$1" sid="${2:-}" common dir f owner abs branch tmp
  _wl_valid_session "$sid" || { echo "error:bad-session-id" >&2; return 5; }
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error:not-a-git-worktree" >&2; return 3; }
  _wl_is_linked "$wt" || { echo "error:not-a-linked-worktree" >&2; return 6; }
  common="$(_wl_common_dir "$wt")" || return 3
  abs="$(_wl_abs "$wt")"
  dir="$common/sge-worktrees"
  mkdir -p "$dir" || return 1
  f="$dir/$(_wl_key "$abs").entry"
  branch="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || echo "(detached)")"
  tmp="$(mktemp "$dir/.tmp.XXXXXX")" || return 1
  printf 'session=%s\npath=%s\nbranch=%s\n' "$sid" "$abs" "$branch" >"$tmp"
  # mv -n never overwrites: a concurrent claim of the same path cannot win silently.
  mv -n "$tmp" "$f" 2>/dev/null
  if [ -e "$tmp" ]; then # entry already existed
    rm -f "$tmp"
    owner="$(_wl_entry_field "$f" session)"
    if [ "$owner" = "$sid" ]; then echo "registered:already"; return 0; fi
    echo "error:foreign-claim" >&2
    return 4
  fi
  echo "registered:new"
}

wl_unregister() {
  local wt="$1" sid="${2:-}" common f
  _wl_valid_session "$sid" || { echo "error:bad-session-id" >&2; return 5; }
  common="$(_wl_common_dir "$wt")" || { echo "error:not-a-git-worktree" >&2; return 3; }
  f="$common/sge-worktrees/$(_wl_key "$(_wl_abs "$wt")").entry"
  [ -f "$f" ] || { echo "unregistered:absent"; return 0; }
  [ "$(_wl_entry_field "$f" session)" = "$sid" ] || { echo "error:foreign-claim" >&2; return 4; }
  rm -f "$f"
  echo "unregistered:ok"
}

wl_list() {
  local common f
  common="$(_wl_common_dir "${1:-.}")" || { echo "error:not-a-git-worktree" >&2; return 3; }
  for f in "$common"/sge-worktrees/*.entry; do
    [ -f "$f" ] || continue
    printf '%s\t%s\t%s\n' "$(_wl_entry_field "$f" session)" "$(_wl_entry_field "$f" path)" "$(_wl_entry_field "$f" branch)"
  done
}

_wl_verdict() { printf 'verdict:%s\nreason:%s\n' "$1" "$2"; }

wl_audit() {
  local wt="$1" sid="${2:-}" common f branch heads sup status
  _wl_valid_session "$sid" || { echo "error:bad-session-id" >&2; return 5; }
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error:not-a-git-worktree" >&2; return 3; }
  common="$(_wl_common_dir "$wt")" || return 3
  f="$common/sge-worktrees/$(_wl_key "$(_wl_abs "$wt")").entry"
  [ -f "$f" ] || { _wl_verdict KEEP not-registered-foreign; return 0; }
  [ "$(_wl_entry_field "$f" session)" = "$sid" ] || { _wl_verdict KEEP owned-by-other-session; return 0; }

  status="$(git -C "$wt" status --porcelain 2>/dev/null)" || { _wl_verdict VALUABLE status-unreadable; return 0; }
  [ -z "$status" ] || { _wl_verdict VALUABLE uncommitted-changes; return 0; }

  branch="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" || { _wl_verdict VALUABLE detached-head; return 0; }

  # Open-PR set: live and fail-closed. Any failure => KEEP, never "no PRs".
  if ! heads="$(cd "$wt" && hpr_open_pr_heads 2>/dev/null)"; then
    _wl_verdict KEEP open-pr-lookup-failed; return 0
  fi
  if printf '%s\n' "$heads" | awk -F'\t' -v b="$branch" '$2==b{f=1} END{exit !f}'; then
    _wl_verdict KEEP open-pr; return 0
  fi

  sup="$(rg_supersession "$wt" 2>/dev/null | sed -n 's/^verdict://p')"
  case "$sup" in
    superseded) _wl_verdict candidate superseded-by-base ;;
    live)       _wl_verdict VALUABLE unmerged-work ;;
    *)          _wl_verdict KEEP supersession-unknown ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    register)   wl_register "$@" ;;
    unregister) wl_unregister "$@" ;;
    list)       wl_list "$@" ;;
    audit)      wl_audit "$@" ;;
    *) echo "usage: worktree-lifecycle.sh register|unregister|list|audit ..." >&2; exit 2 ;;
  esac
fi
