#!/usr/bin/env bash
# copilot-session-record.sh — write the minimal per-user lifecycle record that lets
# /sge:reap-orphans (issue #3367) prove a Copilot CLI process is an abandoned
# orphan. BEST-EFFORT and NON-DESTRUCTIVE: it only writes one small file in the
# caller's own record store, never signals or inspects anything else, and always
# exits 0 so it can never break a session. Called from the Copilot lifecycle hook
# (hooks/copilot/worktree-lifecycle.sh) on sessionStart / agentStop / sessionEnd.
#
#   bash copilot-session-record.sh <start|beat|end> <session-id>
#
# It walks up from this process to the nearest recognised Copilot client
# (copilot-signature.sh) and binds that exact PID + start identity + owner to the
# session id with the intent it can prove at this moment:
#   interactive  the client has a live parent (a shell / terminal launched it)
#   detached     the client was already orphaned (PPID 1) when recorded, or
#                SGE_COPILOT_INTENT=detached — the reaper never touches these
#   server       the client is an ACP/server/headless host — never touched
# No Copilot ancestor found -> nothing is written (the reaper then stays
# report-only). Records hold NO prompt text, command line, path or credential.
#
# Record (<dir>/<session-id>.rec, key=value, mode 600, dir mode 700):
#   schema=1 session= pid= start= owner= intent= state=active|ended updated=<epoch>
# <dir> = $SGE_COPILOT_SESSION_DIR, else ${XDG_STATE_HOME:-~/.local/state}/sge/copilot-sessions
# (Windows: copilot-session-record.ps1 -> %LOCALAPPDATA%\sge\copilot-sessions).
#
# Test seams: SGE_COPILOT_REC_PS_FIXTURE ("pid ppid etimes args" rows), SGE_COPILOT_REC_FROM
# (start pid), SGE_REAP_IDENT_FIXTURE ("pid|user|start"), SGE_REAP_NOW, SGE_REAP_USER.
set -uo pipefail

main() {
  local here ev sid now dir me tbl p row kind ppid args id start user intent state rec tmp depth f proc_uid my_uid
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 0
  ev="${1:-}"; sid="${2:-}"
  if [ "$sid" = --hook-input ]; then
    sid="$(node "$here/copilot-hooks.mjs" --session-id 2>/dev/null)" || return 0
  fi
  case "$ev" in start|beat|end) ;; *) return 0 ;; esac
  case "$sid" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  [ "${#sid}" -le 128 ] || return 0

  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      if [ -z "${SGE_COPILOT_REC_PS_FIXTURE:-}" ]; then
        local sh; sh="$(command -v pwsh || command -v powershell || true)"
        [ -n "$sh" ] || return 0
        "$sh" -NoProfile -NonInteractive -File "$here/copilot-session-record.ps1" -Event "$ev" -Session "$sid" >/dev/null 2>&1 </dev/null
        return 0
      fi ;;
  esac

  # shellcheck source=/dev/null
  source "$here/copilot-signature.sh" 2>/dev/null || return 0
  now="${SGE_REAP_NOW:-}"; case "$now" in ''|*[!0-9]*) now="$(date +%s)" ;; esac
  dir="${SGE_COPILOT_SESSION_DIR:-${XDG_STATE_HOME:-${HOME:-}/.local/state}/sge/copilot-sessions}"
  [ -n "${HOME:-}${SGE_COPILOT_SESSION_DIR:-}" ] || return 0
  me="${SGE_REAP_USER:-$(id -un 2>/dev/null)}"
  [ -n "$me" ] || return 0

  tbl="$(mktemp)" || return 0
  if [ -n "${SGE_COPILOT_REC_PS_FIXTURE:-}" ]; then classify_table <"$SGE_COPILOT_REC_PS_FIXTURE" >"$tbl"
  # macOS `ps` drops an unsupported `etimes=` keyword silently rather than erroring, which
  # shifts args left and loses the executable field the classifier expects. The writer never
  # needs elapsed time, so skip requesting it and splice in a placeholder instead.
  else ps -eo pid=,ppid=,args= 2>/dev/null | awk '{ pid=$1; ppid=$2; sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+/, ""); print pid, ppid, 0, $0 }' | classify_table >"$tbl"; fi

  p="${SGE_COPILOT_REC_FROM:-$PPID}"; depth=0; kind=none; ppid=""
  while [ "$depth" -lt 32 ] && [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    row="$(awk -v p="$p" '$1 == p { print; exit }' "$tbl")"
    [ -n "$row" ] || break
    read -r _ ppid _ kind args <<<"$row"
    case "$kind" in client|server) break ;; esac
    kind=none; p="$ppid"; depth=$((depth + 1))
  done
  rm -f "$tbl"
  [ "$kind" != none ] || return 0

  if [ -n "${SGE_COPILOT_REC_PS_FIXTURE:-}" ]; then
    id="$(awk -F'|' -v p="$p" '$1 == p { print $2 "|" $3; exit }' "${SGE_REAP_IDENT_FIXTURE:-/dev/null}")"
  else
    # Compare numeric UIDs, not `ps -o user=` names: procps-ng truncates the user
    # column to fit $COLUMNS, so a narrow terminal/CI width can silently mismatch a
    # real owner. Pin the identity clock (LC_ALL/TZ) so lstart is stable across
    # locales and the writer's and reaper's zone, independent of each caller's env.
    proc_uid="$(ps -o uid= -p "$p" 2>/dev/null | tr -d ' ')"
    my_uid="${SGE_REAP_MY_UID:-$(id -u 2>/dev/null)}"
    start="$(TZ=UTC0 LC_ALL=C ps -o lstart= -p "$p" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')"
    if [ -n "$proc_uid" ] && [ -n "$my_uid" ] && [ "$proc_uid" = "$my_uid" ]; then id="$me|$start"; else id=""; fi
  fi
  user="${id%%|*}"; start="${id#*|}"
  [ -n "$user" ] && [ -n "$start" ] && [ "$user" = "$me" ] || return 0   # only ever record our own process
  case "$start" in *[!A-Za-z0-9\ :._+-]*) return 0 ;; esac
  [ "${#start}" -le 64 ] || return 0

  if [ "$kind" = server ]; then intent=server
  elif [ "${SGE_COPILOT_INTENT:-}" = detached ] || [ "$ppid" = 1 ]; then intent=detached
  else intent=interactive; fi
  state=active; [ "$ev" != end ] || state=ended

  ( umask 077; mkdir -p "$dir" ) 2>/dev/null || return 0     # owner-only store, no chmod needed
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
  rec="$dir/$sid.rec"
  # Another session's record for this very pid means the pid has moved on to a newer session
  # (or this is an older session's late event). Ordering rule:
  #   start      the newer session wins: drop the previous generation's record so the reaper
  #              never sees two claims on one pid (it would treat that as contradictory).
  #   beat / end an OLDER session's late event must never delete or overwrite the newer
  #              session's record, so it writes nothing at all.
  other=0
  for f in "$dir"/*.rec; do
    if [ -e "$f" ] && [ "$f" != "$rec" ]; then
      if grep -qx "pid=$p" "$f" 2>/dev/null; then other=1; fi
    fi
  done
  if [ "$other" -eq 1 ]; then
    [ "$ev" = start ] || return 0
    for f in "$dir"/*.rec; do
      if [ -e "$f" ] && [ "$f" != "$rec" ]; then
        if grep -qx "pid=$p" "$f" 2>/dev/null; then rm -f "$f"; fi
      fi
    done
  fi
  tmp="$(mktemp "$dir/.tmp.XXXXXX")" || return 0
  printf 'schema=1\nsession=%s\npid=%s\nstart=%s\nowner=%s\nintent=%s\nstate=%s\nupdated=%s\n' \
    "$sid" "$p" "$start" "$me" "$intent" "$state" "$now" >"$tmp" && mv -f "$tmp" "$rec" || rm -f "$tmp"
  find "$dir" -maxdepth 1 -name '*.rec' -mtime +30 -delete 2>/dev/null
  return 0
}
main "$@" || true
exit 0
