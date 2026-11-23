#!/usr/bin/env bash
# worktree-lifecycle.sh — deterministic, NON-DESTRUCTIVE worktree lifecycle
# primitives shared by hooks and /sge:tidy-worktrees (issue #3233, epic #3216).
#
#   source skills/lib/worktree-lifecycle.sh
#   wl_register  <worktree> <session-id>   # claim a linked worktree (idempotent)
#   wl_unregister <worktree> <session-id>  # drop OUR registry entry only
#   wl_list [<repo-path>]                  # "<session>\t<path>\t<branch>" rows
#   wl_audit <worktree> <session-id>       # verdict block (see below)
#   wl_recovery_preview <worktree>         # inspect a candidate, no changes
#   wl_recover <worktree> <owner> <entry-hash> <head> <status-hash>
#   wl_recover_many <registration-entry>... # explicitly authorised selection
#   bash worktree-lifecycle.sh <register|unregister|list|audit|recovery-preview|recover|recover-many> <args...>
#
# Registry: one file per owned worktree under <git-common-dir>/sge-worktrees/,
# so every linked worktree of a repo shares ONE registry. Entries are written
# atomically (temp file + mv -n). Only a linked worktree of THIS common dir can
# be registered (the main checkout never can), and only the owning session may
# unregister it. Explicitly authorised recovery is a separate operator action;
# it does not add a second terminal confirmation to the caller's approval.
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
#             6 not a linked worktree, 8 changed evidence,
#             9 registry busy.

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

_wl_lock() {
  mkdir "$1" 2>/dev/null || { echo "error:registry-busy" >&2; return 9; }
}

_wl_status_hash() {
  (set -o pipefail; git -C "$1" status --porcelain=v1 -z --untracked-files=all | git hash-object --stdin)
}

_wl_archive_registration() (
  local f="$1" dir="$2" key="$3" expected="$4" archive saved current
  [ ! -L "$dir/recovered" ] || { echo "error:unsafe-archive" >&2; return 1; }
  mkdir -p "$dir/recovered" || return 1
  archive="$(mktemp -d "$dir/recovered/$key.XXXXXX")" || return 1
  saved="$archive/entry"
  if ! mv -- "$f" "$saved"; then
    rmdir "$archive" 2>/dev/null || :
    echo "error:archive-failed" >&2
    return 1
  fi
  current="$(git hash-object "$saved" 2>/dev/null)" || current=''
  if [ ! -f "$saved" ] || [ -L "$saved" ] || [ "$current" != "$expected" ]; then
    if ln -T -- "$saved" "$f" 2>/dev/null; then
      printf 'error:evidence-changed; changed claim restored and archived: %q\n' "$saved" >&2
    else
      printf 'error:evidence-changed; active path not overwritten; reconcile archive: %q\n' "$saved" >&2
    fi
    return 8
  fi
  printf 'recovered: %q\n' "$saved"
)

wl_register() (
  local wt="$1" sid="${2:-}" common dir f owner abs branch tmp lock
  _wl_valid_session "$sid" || { echo "error:bad-session-id" >&2; return 5; }
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error:not-a-git-worktree" >&2; return 3; }
  _wl_is_linked "$wt" || { echo "error:not-a-linked-worktree" >&2; return 6; }
  common="$(_wl_common_dir "$wt")" || return 3
  abs="$(_wl_abs "$wt")"
  dir="$common/sge-worktrees"
  mkdir -p "$dir" || return 1
  f="$dir/$(_wl_key "$abs").entry"
  lock="$dir/$(_wl_key "$abs").lock"
  _wl_lock "$lock" || return $?
  trap 'rmdir "$lock" 2>/dev/null || :' EXIT
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
)

wl_unregister() (
  local wt="$1" sid="${2:-}" common f abs lock
  _wl_valid_session "$sid" || { echo "error:bad-session-id" >&2; return 5; }
  common="$(_wl_common_dir "$wt")" || { echo "error:not-a-git-worktree" >&2; return 3; }
  abs="$(_wl_abs "$wt")" || return 3
  f="$common/sge-worktrees/$(_wl_key "$abs").entry"
  [ -f "$f" ] || { echo "unregistered:absent"; return 0; }
  lock="$common/sge-worktrees/$(_wl_key "$abs").lock"
  _wl_lock "$lock" || return $?
  trap 'rmdir "$lock" 2>/dev/null || :' EXIT
  [ -f "$f" ] || { echo "unregistered:absent"; return 0; }
  [ "$(_wl_entry_field "$f" session)" = "$sid" ] || { echo "error:foreign-claim" >&2; return 4; }
  rm "$f" || return 1
  echo "unregistered:ok"
)

wl_recovery_preview() {
  local wt="$1" common abs f owner hash head status
  _wl_is_linked "$wt" || { echo "error:not-a-linked-worktree" >&2; return 6; }
  common="$(_wl_common_dir "$wt")" || return 3
  abs="$(_wl_abs "$wt")" || return 3
  f="$common/sge-worktrees/$(_wl_key "$abs").entry"
  [ -f "$f" ] && [ ! -L "$f" ] || { echo "error:registration-unavailable" >&2; return 4; }
  owner="$(_wl_entry_field "$f" session)"
  _wl_valid_session "$owner" || { echo "error:bad-registration" >&2; return 4; }
  [ "$(_wl_entry_field "$f" path)" = "$abs" ] || { echo "error:bad-registration" >&2; return 4; }
  hash="$(git hash-object "$f")" || return 1
  head="$(git -C "$wt" rev-parse --verify HEAD)" || return 1
  status="$(_wl_status_hash "$wt")" || return 1
  printf 'path: %s\nowner: %s\nbranch: %s\nentry-hash: %s\nhead: %s\nstatus-hash: %s\n' \
    "$abs" "$owner" "$(_wl_entry_field "$f" branch)" "$hash" "$head" "$status"
  echo 'Operator must establish that no writer is active; status hash does not capture file contents.'
}

wl_recover() (
  local wt="$1" owner="${2:-}" expected="${3:-}" head="${4:-}" status="${5:-}"
  local common abs dir key f lock current
  _wl_valid_session "$owner" || { echo "error:bad-session-id" >&2; return 5; }
  _wl_is_linked "$wt" || { echo "error:not-a-linked-worktree" >&2; return 6; }
  common="$(_wl_common_dir "$wt")" || return 3
  abs="$(_wl_abs "$wt")" || return 3
  dir="$common/sge-worktrees"
  key="$(_wl_key "$abs")"
  f="$dir/$key.entry"
  printf 'Recover registration for %s owned by %s.\nentry-hash: %s\nhead: %s\nstatus-hash: %s\n' \
    "$abs" "$owner" "$expected" "$head" "$status" >&2
  echo 'Caller must establish that writers stopped and preserve the original worktree; recovery archives registration only.' >&2
  lock="$dir/$key.lock"
  _wl_lock "$lock" || return $?
  trap 'rmdir "$lock" 2>/dev/null || :' EXIT
  _wl_is_linked "$wt" || { echo "error:not-a-linked-worktree" >&2; return 6; }
  [ -f "$f" ] && [ ! -L "$f" ] || { echo "error:registration-unavailable" >&2; return 4; }
  [ "$(_wl_entry_field "$f" session)" = "$owner" ] &&
    [ "$(_wl_entry_field "$f" path)" = "$abs" ] || { echo "error:foreign-claim" >&2; return 4; }
  current="$(git hash-object "$f")" || return 1
  [ "$current" = "$expected" ] || { echo "error:evidence-changed" >&2; return 8; }
  current="$(git -C "$wt" rev-parse --verify HEAD)" || return 1
  [ "$current" = "$head" ] || { echo "error:evidence-changed" >&2; return 8; }
  current="$(_wl_status_hash "$wt")" || return 1
  [ "$current" = "$status" ] || { echo "error:evidence-changed" >&2; return 8; }
  _wl_archive_registration "$f" "$dir" "$key" "$expected"
)

wl_recover_many() (
  local candidate wt abs common dir f owner hash head status branch seen
  local lock current i rc skipped=0 failed=0
  local -a paths=() owners=() hashes=() heads=() statuses=() branches=() entries=() commons=()
  [ "$#" -gt 0 ] || { echo "error:registration-entries-required" >&2; return 2; }
  for candidate in "$@"; do
    if [ ! -f "$candidate" ] || [ -L "$candidate" ]; then
      printf 'skipped invalid entry: %q\n' "$candidate" >&2; skipped=$((skipped + 1)); continue
    fi
    wt="$(_wl_entry_field "$candidate" path)"
    if [ -z "$wt" ] || ! _wl_is_linked "$wt"; then
      printf 'skipped unavailable worktree: %q\n' "$wt" >&2; skipped=$((skipped + 1)); continue
    fi
    abs="$(_wl_abs "$wt")" || return 1
    common="$(_wl_common_dir "$abs")" || return 3
    dir="$common/sge-worktrees"
    f="$dir/$(_wl_key "$abs").entry"
    if [ "$(_wl_abs "$(dirname "$candidate")")" != "$(_wl_abs "$dir")" ] ||
       [ "$(basename "$candidate")" != "$(basename "$f")" ] ||
       [ ! -f "$f" ] || [ -L "$f" ] || [ "$(_wl_entry_field "$f" path)" != "$abs" ]; then
      printf 'skipped mismatched entry: %q\n' "$candidate" >&2; skipped=$((skipped + 1)); continue
    fi
    for seen in "${paths[@]}"; do
      [ "$seen" != "$abs" ] || { echo "error:duplicate-target" >&2; return 4; }
    done
    owner="$(_wl_entry_field "$f" session)"
    _wl_valid_session "$owner" || { printf 'skipped invalid owner: %q\n' "$abs" >&2; skipped=$((skipped + 1)); continue; }
    hash="$(git hash-object "$f")" || return 1
    head="$(git -C "$abs" rev-parse --verify HEAD)" || return 1
    status="$(_wl_status_hash "$abs")" || return 1
    branch="$(git -C "$abs" symbolic-ref -q --short HEAD 2>/dev/null || echo '(detached)')"
    paths+=("$abs"); owners+=("$owner"); hashes+=("$hash")
    heads+=("$head"); statuses+=("$status"); branches+=("$branch"); entries+=("$f"); commons+=("$common")
  done
  [ "${#paths[@]}" -gt 0 ] || { echo "error:no-recoverable-entries" >&2; return 4; }

  echo 'Caller must authorise this exact selection and establish that all its writers stopped.' >&2
  echo 'Status hashes do not capture file contents; preserve the original worktrees.' >&2
  for ((i=0; i<${#paths[@]}; i++)); do
    printf 'path=%q owner=%q branch=%q entry=%s head=%s status=%s\n' \
      "${paths[i]}" "${owners[i]}" "${branches[i]}" "${hashes[i]}" "${heads[i]}" "${statuses[i]}" >&2
  done
  printf 'Skipped: %s. Each entry is rechecked separately; partial recovery is possible.\n' "$skipped" >&2

  for ((i=0; i<${#paths[@]}; i++)); do
    if (
      wt="${paths[i]}"; owner="${owners[i]}"; f="${entries[i]}"
      common="$(_wl_common_dir "$wt")" || exit 3
      [ "$(_wl_abs "$common")" = "$(_wl_abs "${commons[i]}")" ] ||
        { echo "error:evidence-changed" >&2; exit 8; }
      dir="$common/sge-worktrees"; lock="$dir/$(_wl_key "$wt").lock"
      _wl_lock "$lock" || exit $?
      trap 'rmdir "$lock" 2>/dev/null || :' EXIT
      _wl_is_linked "$wt" || { echo "error:not-a-linked-worktree" >&2; exit 6; }
      [ -f "$f" ] && [ ! -L "$f" ] || { echo "error:registration-unavailable" >&2; exit 4; }
      [ "$(_wl_entry_field "$f" session)" = "$owner" ] &&
        [ "$(_wl_entry_field "$f" path)" = "$wt" ] || { echo "error:foreign-claim" >&2; exit 4; }
      current="$(git hash-object "$f")" || exit 1
      [ "$current" = "${hashes[i]}" ] || { echo "error:evidence-changed" >&2; exit 8; }
      current="$(git -C "$wt" rev-parse --verify HEAD)" || exit 1
      [ "$current" = "${heads[i]}" ] || { echo "error:evidence-changed" >&2; exit 8; }
      current="$(_wl_status_hash "$wt")" || exit 1
      [ "$current" = "${statuses[i]}" ] || { echo "error:evidence-changed" >&2; exit 8; }
      current="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || echo '(detached)')"
      [ "$current" = "${branches[i]}" ] || { echo "error:evidence-changed" >&2; exit 8; }
      _wl_archive_registration "$f" "$dir" "$(_wl_key "$wt")" "${hashes[i]}" || exit $?
      printf 'released: %q\n' "$wt"
    ); then
      :
    else
      rc=$?; failed=$((failed + 1))
      printf 'not recovered; inspect errors: %q (exit %s)\n' "${paths[i]}" "$rc" >&2
    fi
  done
  printf 'recovery summary: %s recovered, %s not recovered, %s skipped\n' \
    "$(( ${#paths[@]} - failed ))" "$failed" "$skipped"
  [ "$failed" -eq 0 ] && [ "$skipped" -eq 0 ]
)

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
    recovery-preview) wl_recovery_preview "$@" ;;
    recover)    wl_recover "$@" ;;
    recover-many) wl_recover_many "$@" ;;
    *) echo "usage: worktree-lifecycle.sh register|unregister|list|audit|recovery-preview|recover|recover-many ..." >&2; exit 2 ;;
  esac
fi
