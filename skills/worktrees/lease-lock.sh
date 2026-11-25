#!/usr/bin/env bash
# lease-lock.sh: the shared lock around the .sge-wt-claim lease (sge#3697).
#
# Every party that acts on a lease takes this lock: roc_claim (check-and-write),
# tidy's execute.sh (drop an expired lease, then remove the worktree) and
# admission.mjs (re-read the lease, then commit). So none of them acts on a
# lease state that another has changed since it read it.
#
# The lock is a directory, sge-wt-claim.lock, in the worktree's own git admin
# dir (`git rev-parse --absolute-git-dir`), never in the work tree, so it never
# shows in `git status`. mkdir is atomic on every platform, Windows included.
# `git worktree remove` deletes the admin dir, and the lock with it.
#
#   source lease-lock.sh
#   sge_lease_lock <worktree>   # 0 = held; 1 = busy past the wait; 2 = no git dir
#   sge_lease_touch             # refreshes the held lock's mtime (long holders)
#   sge_lease_unlock            # releases the lock this shell took (best effort)
#
# SGE_LEASE_LOCK_WAIT_DS  wait for a busy lock, in tenths of a second (default 50)
# SGE_LEASE_LOCK_STALE_S  a lock not touched for this long is a crashed holder's
#                         and is broken (default 600). A holder that works longer
#                         than a few seconds calls sge_lease_touch between steps.
# admission.mjs implements the same protocol in Node (same path, token, break
# lock and staleness).

# Ownership (CodeRabbit on #3701). The holder drops a token file h.<pid>.<rand>
# in the lock dir, and release/touch act only while that token is still there, so
# a holder whose lock was broken never removes or recreates a successor's lock.
# Breaking a stale lock is serialised by a second mkdir lock, <lock>.break: the
# breaker re-reads the age under it, so two contenders that both saw the same
# stale lock cannot each remove one (the second finds the first's fresh lock).
# A break lock is held for milliseconds; one older than 10 s is a crashed
# breaker's and is removed. The one residual interleaving needs a breaker that
# crashed inside that millisecond window AND three contenders racing on it.

SGE_LEASE_LOCK_HELD=""
SGE_LEASE_LOCK_TOKEN=""

sge_lease_lock_path() { # <worktree>
  local d
  d="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null | tr -d '\r')"
  [ -n "$d" ] && [ -d "$d" ] || return 1
  printf '%s/sge-wt-claim.lock\n' "$d"
}

_sge_lease_age() { # <path> -> seconds since its mtime; fails when it is gone
  local m
  m="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)"
  [ -n "$m" ] || return 1
  echo $(( $(date +%s) - m ))
}

_sge_lease_break() { # <lock> <stale-s> -> 0 when it removed that stale lock
  local l="$1" b="$1.break" a rc=1
  a="$(_sge_lease_age "$l")" && [ "$a" -ge "$2" ] || return 1
  if ! mkdir "$b" 2>/dev/null; then
    a="$(_sge_lease_age "$b")" && [ "$a" -ge 10 ] && rmdir "$b" 2>/dev/null
    return 1
  fi
  if a="$(_sge_lease_age "$l")" && [ "$a" -ge "$2" ]; then
    rm -f -- "$l"/h.* 2>/dev/null
    rmdir "$l" 2>/dev/null && rc=0
  fi
  rmdir "$b" 2>/dev/null
  return "$rc"
}

sge_lease_lock() { # <worktree>
  local l i=0 wait="${SGE_LEASE_LOCK_WAIT_DS:-50}" stale="${SGE_LEASE_LOCK_STALE_S:-600}" t
  l="$(sge_lease_lock_path "$1")" || return 2
  t="h.$$.$RANDOM$RANDOM"
  until mkdir "$l" 2>/dev/null; do
    [ -d "${l%/*}" ] || return 2
    # A crashed holder's lock is broken; a failed break still counts against the wait.
    _sge_lease_break "$l" "$stale" && continue
    i=$((i + 1)); [ "$i" -le "$wait" ] || return 1
    sleep 0.1
  done
  : >"$l/$t" 2>/dev/null || { rmdir "$l" 2>/dev/null; return 1; }
  SGE_LEASE_LOCK_HELD="$l"
  SGE_LEASE_LOCK_TOKEN="$t"
}

sge_lease_touch() {
  [ -n "$SGE_LEASE_LOCK_HELD" ] && [ -e "$SGE_LEASE_LOCK_HELD/$SGE_LEASE_LOCK_TOKEN" ] \
    && touch -c -- "$SGE_LEASE_LOCK_HELD" 2>/dev/null
  return 0
}

sge_lease_unlock() {
  [ -n "$SGE_LEASE_LOCK_HELD" ] || return 0
  rm -- "$SGE_LEASE_LOCK_HELD/$SGE_LEASE_LOCK_TOKEN" 2>/dev/null && rmdir "$SGE_LEASE_LOCK_HELD" 2>/dev/null
  SGE_LEASE_LOCK_HELD=""
  SGE_LEASE_LOCK_TOKEN=""
  return 0
}
