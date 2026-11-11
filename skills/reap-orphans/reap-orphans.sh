#!/usr/bin/env bash
# /sge:reap-orphans — POSIX (macOS/Linux) zombie reaper.
#
# Moved here from env-health's Component A (#2915): env-health now calls this
# instead of carrying its own reaper. The Windows reaper is reap-orphans.ps1.
#
# GENERIC DEBRIS. A process is reaped only when ALL THREE hold (any doubt -> leave it alone):
#   1. its command matches a known-reapable test/dev-server or hung-install
#      pattern (ZOMBIE_NAME_RE),
#   2. its parent is PID 1 or no longer alive (orphaned),
#   3. it has run longer than the grace window (GRACE_MIN, default 30).
# Never reaped: anything matching PROTECT_RE (MCP servers, claude, language
# servers, ...) and the current session tree (this shell and its ancestors).
# CLAUDE.md may extend ZOMBIE_NAME_RE / PROTECT_RE / GRACE_MIN via env.
#
# GITHUB COPILOT CLI (#3367). Copilot processes are a SEPARATE lane that the
# generic rules above can never reach (a Copilot-shaped process is skipped by the
# generic loop even if its prompt text happens to match ZOMBIE_NAME_RE). A
# Copilot client is reaped only when ALL hold; every other shape is kept:
#   a. it positively matches the Copilot CLI signature (a `copilot` binary, or a
#      node-hosted `@github/copilot` package) and carries no server/ACP flag,
#   b. its parent is PID 1 or absent from the process table,
#   c. a valid per-user lifecycle record (see SKILL.md) binds this exact PID and
#      start identity to this user, with intent=interactive,
#   d. the record says the session ended (state=ended, past COPILOT_END_GRACE_SEC)
#      or went silent (state=active, no heartbeat for COPILOT_ABANDON_MIN),
#   e. the PID, start identity, owner and (a)-(d) are re-validated immediately
#      before TERM and again before KILL (PID reuse -> no kill).
# Parent loss, age, memory and flags alone never qualify. A missing, malformed,
# stale or contradictory record is report-only. Copilot command lines are never
# printed. Only the single Copilot PID is signalled (never its tree).
#
# Usage: reap-orphans.sh [--dry-run]
#   Kills with TERM, re-checks after a short grace, then KILL; oldest first.
#   Every generic kill (or would-kill) is logged as "pid=.. age=..s ppid=.. :: args".
#
# Test seams (fixtures only; never needed in real use):
#   SGE_REAP_PS_ETIME_FIXTURE       macOS-shaped table ("pid ppid [[dd-]hh:]mm:ss args") converted like live ps
#   SGE_REAP_PS_FIXTURE[_2|_3]     file of "pid ppid etimes args" lines in place of ps
#                                  (_2 = re-validation before TERM, _3 = before KILL)
#   SGE_REAP_IDENT_FIXTURE[_2|_3]  file of "pid|user|start-identity" lines in place of ps -o user,lstart
#   SGE_REAP_SELF_PIDS             extra pids to protect
#   SGE_REAP_KILL_LOG              mock termination: append "SIG pid" here, signal nothing, no sleeps
#   SGE_REAP_NOW, SGE_REAP_USER    pin the clock / the current user
set -uo pipefail

DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-DryRun) DRY=1; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "reap-orphans.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

ZOMBIE_NAME_RE="${ZOMBIE_NAME_RE:-playwright.*(test-server|test server)|(next|vite|webpack|nuxt|remix) (dev|serve)|pnpm .*install}"
PROTECT_RE="${PROTECT_RE:-mcp|claude|anthropic|tsserver|eslint_d|gopls|language-server}"
GRACE_MIN="${GRACE_MIN:-30}"

num_or() { case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
COPILOT_ABANDON_SEC=$(( $(num_or "${COPILOT_ABANDON_MIN:-}" 360) * 60 ))
COPILOT_END_GRACE_SEC="$(num_or "${COPILOT_END_GRACE_SEC:-}" 300)"
NOW="$(num_or "${SGE_REAP_NOW:-}" "$(date +%s)")"
ME="${SGE_REAP_USER:-$(id -un 2>/dev/null)}"
SESSION_DIR="${SGE_COPILOT_SESSION_DIR:-${XDG_STATE_HOME:-${HOME:-/nonexistent}/.local/state}/sge/copilot-sessions}"
MOCK_KILL="${SGE_REAP_KILL_LOG:-}"

# A macOS-shaped table fixture is still a fixture: every live-ps/kill path stays off.
[ -z "${SGE_REAP_PS_ETIME_FIXTURE:-}" ] || SGE_REAP_PS_FIXTURE="${SGE_REAP_PS_FIXTURE:-$SGE_REAP_PS_ETIME_FIXTURE}"

# Current session tree: this shell and every ancestor up to PID 1.
SELF_TREE="$$ ${SGE_REAP_SELF_PIDS:-}"
p=$$
while [ -z "${SGE_REAP_PS_FIXTURE:-}" ] && [ "$p" -gt 1 ] 2>/dev/null; do
  p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
  [ -n "$p" ] || break
  SELF_TREE="$SELF_TREE $p"
done

# etime_to_secs: rewrites "pid ppid [[dd-]hh:]mm:ss args" rows to "pid ppid <seconds> args".
# macOS/BSD `ps` has no `etimes` (it silently drops an unknown keyword and shifts every
# later column left, losing the executable the Copilot classifier needs), only `etime`.
etime_to_secs() {
  awk '{ match($0, /^[ 	]*[0-9]+[ 	]+[0-9]+[ 	]+/); pre = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
         e = rest; sub(/[ 	].*/, "", e); tail = substr(rest, length(e) + 1)
         d = 0; if (e ~ /-/) { split(e, a, "-"); d = a[1]; e = a[2] }
         n = split(e, t, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + t[i]
         print pre (d * 86400 + s) tail }'
}

# list <phase>: the process table, "pid ppid etimes args" per line.
list() {
  local f="${SGE_REAP_PS_FIXTURE:-}" v
  if [ -n "${SGE_REAP_PS_ETIME_FIXTURE:-}" ]; then etime_to_secs <"$SGE_REAP_PS_ETIME_FIXTURE"   # macOS-shaped fixture
  elif [ -n "$f" ]; then
    case "${1:-1}" in
      2) v="${SGE_REAP_PS_FIXTURE_2:-}"; [ -z "$v" ] || f="$v" ;;
      3) v="${SGE_REAP_PS_FIXTURE_3:-${SGE_REAP_PS_FIXTURE_2:-}}"; [ -z "$v" ] || f="$v" ;;
    esac
    cat "$f"
  else
    case "$(uname -s 2>/dev/null)" in
      Darwin|*BSD) ps -axo pid=,ppid=,etime=,args= 2>/dev/null | etime_to_secs ;;
      *)           ps -eo pid=,ppid=,etimes=,args= 2>/dev/null ;;
    esac
  fi
}

# ident <pid> <phase>: prints "user|start-identity" for a pid (empty when unknown).
# Live path compares numeric UIDs rather than `ps -o user=` names (procps-ng
# truncates the user column to fit $COLUMNS, which can silently mismatch a real
# owner), and pins LC_ALL/TZ for lstart so the same process yields the same start
# identity here and in the writer regardless of either caller's locale/zone.
ident() {
  local f="${SGE_REAP_IDENT_FIXTURE:-}" v pid="$1" s uid my_uid
  if [ -n "${SGE_REAP_PS_FIXTURE:-}" ]; then
    case "${2:-1}" in
      2) v="${SGE_REAP_IDENT_FIXTURE_2:-}"; [ -z "$v" ] || f="$v" ;;
      3) v="${SGE_REAP_IDENT_FIXTURE_3:-${SGE_REAP_IDENT_FIXTURE_2:-}}"; [ -z "$v" ] || f="$v" ;;
    esac
    [ -f "$f" ] || return 0
    awk -F'|' -v p="$pid" '$1 == p { print $2 "|" $3; exit }' "$f"
    return 0
  fi
  uid="$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ')"
  my_uid="${SGE_REAP_MY_UID:-$(id -u 2>/dev/null)}"
  s="$(TZ=UTC0 LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')"
  if [ -n "$uid" ] && [ -n "$my_uid" ] && [ "$uid" = "$my_uid" ] && [ -n "$s" ]; then
    printf '%s|%s' "$ME" "$s"   # UID-verified as ours; report by name for the owner/R_OWNER comparison
  fi
  return 0
}

# Copilot process signature (shared with copilot-session-record.sh): classify_table.
# shellcheck source=copilot-signature.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/copilot-signature.sh" || { echo "reap-orphans.sh: copilot-signature.sh missing" >&2; exit 2; }

# pid_in_table <pid> <table-file>
pid_in_table() { awk -v p="$1" '$1 == p { f = 1; exit } END { exit !f }' "$2"; }
# ppid_of <pid> <table-file>
ppid_of() { awk -v p="$1" '$1 == p { print $2; exit }' "$2"; }

# parent_dead <ppid> <table-text>: orphaned = PID 1, or absent from the table and not signalable.
parent_dead() {
  [ "$1" -eq 1 ] 2>/dev/null && return 0
  if awk -v p="$1" '$1 == p { f = 1; exit } END { exit !f }' <<<"$2"; then return 1; fi
  # EPERM from kill -0 means "exists, not ours": alive. Only "no such process" is dead.
  if kill -0 "$1" 2>/dev/null; then return 1; fi
  if [ -z "${SGE_REAP_PS_FIXTURE:-}" ] && ps -p "$1" >/dev/null 2>&1; then return 1; fi
  return 0
}

# ---- lifecycle records (per-user store; see SKILL.md) ----
# The store is read into an in-memory index (build_index) with no per-record forks;
# evaluate_copilot rebuilds it on every re-validation so a record that changed or
# vanished between selection and signal is seen.
STORE_OK=0; STORE_WHY=""
check_store() {
  local m
  if [ ! -d "$SESSION_DIR" ]; then STORE_WHY="no record store"; return; fi
  if [ -L "$SESSION_DIR" ] || [ ! -O "$SESSION_DIR" ]; then STORE_WHY="record store not owned by this user"; return; fi
  m="$(ls -ld "$SESSION_DIR" 2>/dev/null)"; m="${m:0:10}"
  case "${m:5:1}${m:8:1}" in *w*) STORE_WHY="record store is group/world-writable"; return ;; esac
  STORE_OK=1
}

# parse_record <file> -> sets R_* and returns 0 when strictly valid, 1 otherwise.
# R_PID is set even for an invalid file when it names a pid, so find_record can
# make that pid report-only.
parse_record() {
  local f="$1" k v seen="" lines=0 re
  R_SESSION=""; R_PID=""; R_START=""; R_OWNER=""; R_INTENT=""; R_STATE=""; R_UPDATED=""; R_SCHEMA=""
  [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] || return 1
  while IFS='=' read -r k v || [ -n "$k" ]; do
    v="${v%$'\r'}"
    lines=$((lines + 1)); [ "$lines" -le 16 ] || return 1
    case " $seen " in *" $k "*) return 1 ;; esac    # duplicate key = contradictory
    seen="$seen $k"
    case "$k" in
      schema)  R_SCHEMA="$v" ;;
      session) R_SESSION="$v" ;;
      pid)     R_PID="$v" ;;
      start)   R_START="$v" ;;
      owner)   R_OWNER="$v" ;;
      intent)  R_INTENT="$v" ;;
      state)   R_STATE="$v" ;;
      updated) R_UPDATED="$v" ;;
      *) return 1 ;;                                  # unknown key
    esac
  done <"$f"
  [ "$R_SCHEMA" = 1 ] || return 1
  case "$R_SESSION" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#R_SESSION}" -le 128 ] || return 1
  [ "${f##*/}" = "$R_SESSION.rec" ] || return 1
  case "$R_PID" in ''|*[!0-9]*) return 1 ;; esac
  case "$R_UPDATED" in ''|*[!0-9]*) return 1 ;; esac
  case "$R_STATE" in active|ended) ;; *) return 1 ;; esac
  case "$R_INTENT" in interactive|detached|acp|server) ;; *) return 1 ;; esac
  [ -n "$R_START" ] && [ "${#R_START}" -le 64 ] || return 1
  re='^[A-Za-z0-9 :._+-]+$'; [[ $R_START =~ $re ]] || return 1
  re='^[A-Za-z0-9._@\\-]{1,64}$'; [[ $R_OWNER =~ $re ]] || return 1
  [ "$R_UPDATED" -le $(( NOW + 60 )) ] || return 1   # a record from the future is not trustworthy
  return 0
}

IDX_PID=(); IDX_FILE=(); BAD_PIDS=" "
build_index() {
  local f
  IDX_PID=(); IDX_FILE=(); BAD_PIDS=" "
  [ "$STORE_OK" -eq 1 ] || return 0
  for f in "$SESSION_DIR"/*.rec; do
    [ -e "$f" ] || continue
    if parse_record "$f"; then IDX_PID+=("$R_PID"); IDX_FILE+=("$f")
    else
      case "$R_PID" in ''|*[!0-9]*) ;; *) BAD_PIDS="$BAD_PIDS$R_PID " ;; esac   # names a pid but unusable
    fi
  done
}

# find_record <pid> -> 0 found (R_* set), 1 none, 2 invalid/contradictory.
# ANY .rec file that names this pid but is not strictly valid, or a second valid
# record for the same pid, makes the pid report-only.
find_record() {
  local pid="$1" i hits=0 keep_f=""
  [ "$STORE_OK" -eq 1 ] || return 1
  case "$BAD_PIDS" in *" $pid "*) return 2 ;; esac
  i=0
  while [ "$i" -lt "${#IDX_PID[@]}" ]; do
    if [ "${IDX_PID[$i]}" = "$pid" ]; then hits=$((hits + 1)); keep_f="${IDX_FILE[$i]}"; fi
    i=$((i + 1))
  done
  [ "$hits" -le 1 ] || return 2
  [ "$hits" -eq 1 ] || return 1
  parse_record "$keep_f" || return 2
  return 0
}

# evaluate_copilot <pid> <phase>: decides eligibility from a FRESH read of table,
# identity and record. Sets VERDICT=reap|keep, KIND, WHY, EPPID, EETIMES.
evaluate_copilot() {
  local pid="$1" phase="$2" tbl row rc id user start
  VERDICT=keep; WHY="not found"; KIND=none; EPPID=""; EETIMES=""
  [ "$phase" = 1 ] || build_index      # re-validation re-reads the store
  tbl="$(list "$phase")"            # a variable, not a temp file: nothing to clean up on any return
  row="$(awk -v p="$pid" '$1 == p { print; exit }' <<<"$tbl" | classify_table)"
  if [ -z "$row" ]; then WHY="process gone"; return; fi
  read -r _ EPPID EETIMES KIND _ <<<"$row"
  case "$KIND" in
    server)  WHY="server/ACP host"; return ;;
    related) WHY="copilot-related, unrecognised shape"; return ;;
    client)  ;;
    *)       WHY="no longer a copilot client"; return ;;
  esac
  case " $SELF_TREE " in *" $pid "*) WHY="current session tree"; return ;; esac
  if ! parent_dead "$EPPID" "$tbl"; then WHY="live parent"; return; fi
  find_record "$pid"; rc=$?
  case "$rc" in
    1) WHY="no valid lifecycle record (report-only)"; return ;;
    2) WHY="invalid or contradictory lifecycle record (report-only)"; return ;;
  esac
  id="$(ident "$pid" "$phase")"
  user="${id%%|*}"; start="${id#*|}"
  if [ -z "$id" ] || [ "$start" != "$R_START" ]; then WHY="start identity mismatch (PID reuse?)"; return; fi
  if [ "$user" != "$ME" ] || [ "$R_OWNER" != "$ME" ]; then WHY="owner mismatch"; return; fi
  if [ "$R_INTENT" != interactive ]; then WHY="record intent=$R_INTENT"; return; fi
  case "$R_STATE" in
    ended)
      if [ $(( NOW - R_UPDATED )) -ge "$COPILOT_END_GRACE_SEC" ]; then VERDICT=reap; WHY="session ended, process outlived it"
      else WHY="session ended moments ago (grace)"; fi ;;
    active)
      if [ $(( NOW - R_UPDATED )) -ge "$COPILOT_ABANDON_SEC" ]; then VERDICT=reap; WHY="no heartbeat past abandonment window"
      else WHY="recent heartbeat (session may be live)"; fi ;;
  esac
}

do_kill() { # <SIG> <pid>
  if [ -n "$MOCK_KILL" ]; then printf '%s %s\n' "$1" "$2" >>"$MOCK_KILL"; return 0; fi
  kill -"$1" "$2" 2>/dev/null
}
nap() { [ -n "$MOCK_KILL" ] || sleep "$1"; }

# ---- scan ----
TABLE="$(mktemp)"; trap 'rm -f "$TABLE"' EXIT
list 1 | classify_table >"$TABLE"
check_store
build_index

CP_KEPT_PIDS=""
CP_LIVE=0; CP_KEPT=0; CP_SERVER=0; CP_RELATED=0
COPILOT_REAP=()    # "etimes pid ppid reason"
COPILOT_KEEP=()    # "pid kind reason"
while read -r pid ppid etimes kind args; do
  [ -n "${pid:-}" ] || continue
  case "$kind" in
    none) continue ;;
    related) CP_RELATED=$((CP_RELATED + 1)); CP_KEPT_PIDS="$CP_KEPT_PIDS $pid"; COPILOT_KEEP+=("$pid related copilot-related_unrecognised_shape"); continue ;;
    server)  CP_SERVER=$((CP_SERVER + 1));   CP_KEPT_PIDS="$CP_KEPT_PIDS $pid"; COPILOT_KEEP+=("$pid server server/ACP_host"); continue ;;
  esac
  evaluate_copilot "$pid" 1
  if [ "$VERDICT" = reap ]; then
    COPILOT_REAP+=("$EETIMES $pid $EPPID $WHY")
  else
    CP_KEPT_PIDS="$CP_KEPT_PIDS $pid"
    case "$WHY" in "live parent"|"current session tree") CP_LIVE=$((CP_LIVE + 1)) ;; *) CP_KEPT=$((CP_KEPT + 1)) ;; esac
    COPILOT_KEEP+=("$pid client $(printf '%s' "$WHY" | tr ' ' '_')")
  fi
done <"$TABLE"

# in_kept_copilot_tree <pid>: any ancestor is a kept Copilot process.
in_kept_copilot_tree() {
  local cur="$1" depth=0 par
  [ -n "${CP_KEPT_PIDS// /}" ] || return 1
  while [ "$depth" -lt 64 ]; do
    par="$(ppid_of "$cur" "$TABLE")"
    { [ -n "$par" ] && [ "$par" -gt 1 ]; } 2>/dev/null || return 1
    case " $CP_KEPT_PIDS " in *" $par "*) return 0 ;; esac
    cur="$par"; depth=$((depth + 1))
  done
  return 1
}

CANDIDATES=()
while read -r pid ppid etimes kind args; do
  [ -n "${pid:-}" ] || continue
  case " $SELF_TREE " in *" $pid "*) continue ;; esac                  # self / ancestor
  [ "$kind" = none ] || continue                 # copilot lane owns copilot shapes
  printf '%s' "$args" | grep -qiE "$PROTECT_RE" && continue             # never-kill
  printf '%s' "$args" | grep -qiE "$ZOMBIE_NAME_RE" || continue         # 1. reapable name
  if [ "$ppid" -ne 1 ] && kill -0 "$ppid" 2>/dev/null; then continue; fi # 2. orphaned
  in_kept_copilot_tree "$pid" && continue                               # inside a kept copilot session tree
  [ "$etimes" -ge $(( GRACE_MIN * 60 )) ] || continue                   # 3. aged
  CANDIDATES+=("$etimes $pid $ppid $args")
done <"$TABLE"

echo "=== reap-orphans (posix)$([ "$DRY" -eq 1 ] && echo ' — dry run, nothing will be killed') ==="
if [ "$STORE_OK" -ne 1 ] && [ "$((CP_LIVE + CP_KEPT + CP_SERVER + CP_RELATED + ${#COPILOT_REAP[@]}))" -gt 0 ]; then
  echo "Copilot lifecycle records unusable: ${STORE_WHY:-unknown}"
  echo "Copilot cleanup coverage: incomplete; unknown sessions stay report-only."
  echo "Preview optional tracking: node \"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/copilot-hooks.mjs\" --print (installs nothing)."
fi

if [ "${#CANDIDATES[@]}" -eq 0 ] && [ "${#COPILOT_REAP[@]}" -eq 0 ]; then
  echo "No eligible orphaned debris found (uncertain processes are kept)."
fi

reaped=0
# Oldest first: killing a parent often takes its children with it.
if [ "${#CANDIDATES[@]}" -gt 0 ]; then
  while read -r etimes pid ppid args; do
    [ -n "${pid:-}" ] || continue
    if [ "$DRY" -eq 1 ]; then
      echo "  WOULD KILL pid=$pid age=${etimes}s ppid=$ppid :: $args"
      continue
    fi
    if [ -n "$MOCK_KILL" ]; then pid_in_table "$pid" "$TABLE" || continue
    else kill -0 "$pid" 2>/dev/null || continue; fi   # already gone with its parent
    echo "  KILL pid=$pid age=${etimes}s ppid=$ppid :: $args"
    do_kill TERM "$pid"
    nap 2
    if [ -n "$MOCK_KILL" ] || kill -0 "$pid" 2>/dev/null; then do_kill KILL "$pid"; fi
    reaped=$((reaped + 1))
  done < <(printf '%s\n' "${CANDIDATES[@]}" | sort -rn)
fi

# Copilot lane: command lines are never printed; every signal is preceded by a fresh re-validation.
cp_reaped=0
if [ "${#COPILOT_REAP[@]}" -gt 0 ]; then
  while read -r etimes pid ppid why; do
    [ -n "${pid:-}" ] || continue
    if [ "$DRY" -eq 1 ]; then
      echo "  WOULD KILL pid=$pid age=${etimes}s ppid=$ppid copilot-client ($why)"
      continue
    fi
    evaluate_copilot "$pid" 2
    if [ "$VERDICT" != reap ]; then
      echo "  SKIP pid=$pid copilot-client: re-validation failed before TERM ($WHY)"
      CP_KEPT=$((CP_KEPT + 1)); continue
    fi
    echo "  KILL pid=$pid age=${etimes}s ppid=$ppid copilot-client ($why)"
    do_kill TERM "$pid"
    nap 2
    evaluate_copilot "$pid" 3
    if [ "$VERDICT" = reap ]; then
      do_kill KILL "$pid"
    elif [ "$WHY" != "process gone" ]; then
      echo "  SKIP pid=$pid copilot-client: not escalating to KILL ($WHY)"
    fi
    cp_reaped=$((cp_reaped + 1))
  done < <(printf '%s\n' "${COPILOT_REAP[@]}" | sort -rn)
fi

# Accurate counts, no command lines.
if [ "$((CP_LIVE + CP_KEPT + CP_SERVER + CP_RELATED + ${#COPILOT_REAP[@]}))" -gt 0 ]; then
  for k in "${COPILOT_KEEP[@]+"${COPILOT_KEEP[@]}"}"; do
    [ -n "$k" ] || continue
    read -r kp kk kw <<<"$k"
    echo "  KEPT pid=$kp copilot-$kk: $(printf '%s' "$kw" | tr '_' ' ')"
  done
  echo "Copilot: live=$CP_LIVE kept-uncertain=$CP_KEPT server/acp=$CP_SERVER related=$CP_RELATED reapable=${#COPILOT_REAP[@]}$([ "$DRY" -eq 1 ] || echo " reaped=$cp_reaped")"
fi

if [ "$DRY" -eq 1 ]; then
  if [ "$(( ${#CANDIDATES[@]} + ${#COPILOT_REAP[@]} ))" -gt 0 ]; then echo "(dry run) $(( ${#CANDIDATES[@]} + ${#COPILOT_REAP[@]} )) reapable."; fi
elif [ "$((reaped + cp_reaped))" -gt 0 ] || [ "${#CANDIDATES[@]}" -gt 0 ] || [ "${#COPILOT_REAP[@]}" -gt 0 ]; then
  echo "Reaped $((reaped + cp_reaped))."
fi
