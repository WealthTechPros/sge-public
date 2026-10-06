#!/usr/bin/env bash
# /sge:reap-orphans — POSIX (macOS/Linux) zombie reaper.
#
# Moved here from env-health's Component A (#2915): env-health now calls this
# instead of carrying its own reaper. The Windows reaper is reap-orphans.ps1.
#
# A process is reaped only when ALL THREE hold (any doubt -> leave it alone):
#   1. its command matches a known-reapable test/dev-server or hung-install
#      pattern (ZOMBIE_NAME_RE),
#   2. its parent is PID 1 or no longer alive (orphaned),
#   3. it has run longer than the grace window (GRACE_MIN, default 30).
# Never reaped: anything matching PROTECT_RE (MCP servers, claude, language
# servers, ...) and the current session tree (this shell and its ancestors).
# CLAUDE.md may extend ZOMBIE_NAME_RE / PROTECT_RE / GRACE_MIN via env.
#
# Usage: reap-orphans.sh [--dry-run]
#   Kills with TERM, re-checks after a short grace, then KILL; oldest first.
#   Every kill (or would-kill) is logged as "pid=.. age=..s ppid=.. :: args".
#
# Test seams: SGE_REAP_PS_FIXTURE (a file of "pid ppid etimes args" lines in
# place of ps), SGE_REAP_SELF_PIDS (extra pids to protect).
set -uo pipefail

DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-DryRun) DRY=1; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "reap-orphans.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

ZOMBIE_NAME_RE="${ZOMBIE_NAME_RE:-playwright.*(test-server|test server)|(next|vite|webpack|nuxt|remix) (dev|serve)|pnpm .*install}"
PROTECT_RE="${PROTECT_RE:-mcp|claude|anthropic|tsserver|eslint_d|gopls|language-server}"
GRACE_MIN="${GRACE_MIN:-30}"

# Current session tree: this shell and every ancestor up to PID 1.
SELF_TREE="$$ ${SGE_REAP_SELF_PIDS:-}"
p=$$
while [ -z "${SGE_REAP_PS_FIXTURE:-}" ] && [ "$p" -gt 1 ] 2>/dev/null; do
  p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  [ -n "$p" ] || break
  SELF_TREE="$SELF_TREE $p"
done

list() {
  if [ -n "${SGE_REAP_PS_FIXTURE:-}" ]; then cat "$SGE_REAP_PS_FIXTURE"
  else ps -eo pid=,ppid=,etimes=,args= 2>/dev/null
  fi
}

CANDIDATES=()
while read -r pid ppid etimes args; do
  [ -n "${pid:-}" ] || continue
  case " $SELF_TREE " in *" $pid "*) continue ;; esac                  # self / ancestor
  printf '%s' "$args" | grep -qiE "$PROTECT_RE" && continue             # never-kill
  printf '%s' "$args" | grep -qiE "$ZOMBIE_NAME_RE" || continue         # 1. reapable name
  if [ "$ppid" -ne 1 ] && kill -0 "$ppid" 2>/dev/null; then continue; fi # 2. orphaned
  [ "$etimes" -ge $(( GRACE_MIN * 60 )) ] || continue                   # 3. aged
  CANDIDATES+=("$etimes $pid $ppid $args")
done < <(list)

echo "=== reap-orphans (posix)$([ "$DRY" -eq 1 ] && echo ' — dry run, nothing will be killed') ==="
if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "No orphaned debris found. Clean."
  exit 0
fi

reaped=0
# Oldest first: killing a parent often takes its children with it.
while read -r etimes pid ppid args; do
  [ -n "${pid:-}" ] || continue
  if [ "$DRY" -eq 1 ]; then
    echo "  WOULD KILL pid=$pid age=${etimes}s ppid=$ppid :: $args"
    continue
  fi
  kill -0 "$pid" 2>/dev/null || continue   # already gone with its parent
  echo "  KILL pid=$pid age=${etimes}s ppid=$ppid :: $args"
  kill -TERM "$pid" 2>/dev/null
  sleep 2
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  reaped=$((reaped + 1))
done < <(printf '%s\n' "${CANDIDATES[@]}" | sort -rn)

[ "$DRY" -eq 1 ] && echo "(dry run) ${#CANDIDATES[@]} reapable." || echo "Reaped $reaped."
