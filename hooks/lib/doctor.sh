#!/usr/bin/env bash
# SGE hook doctor (sge#3269). Explains why hooks cannot run, in plain words.
#   doctor.sh --quiet   session-start check: no forks, prints ONE line only on a problem
#   doctor.sh --full    /sge:env-health --doctor report (runs the launcher once as a probe)
# Read-only: it never edits PATH, hooks or policy; hooks stay enabled and fail closed.
# Output names plugin-relative files and tool kinds only (no home or user paths, no env values).
# Seam: SGE_DOCTOR_PATH overrides the PATH that is inspected (tests).
# Sourceable: `. doctor.sh` defines sge_doctor_quiet (session-start uses it, so a healthy start spawns nothing).
FIX_PATH='put Git for Windows (its bin or cmd folder) ahead of C:\Windows\System32 and WindowsApps in PATH for the process that launches the client, then restart it'
BREAK_GLASS='A human can override a blocked policy action for one session with SGE_POLICY_OVERRIDE="<reason>" (logged); hooks stay on and fail closed.'
STUB_MSG="the first bash on PATH is the WSL launcher stub (System32 or WindowsApps), the #3264 condition: hook scripts fail with exit 1 when run by that bash (hooks/run-hook.cmd bypasses it, other tools do not). Fix: $FIX_PATH."

# First PATH entry holding a bash; sets FIRST_KIND to ok|stub|none, no subprocesses.
first_bash() {
  local d; FIRST_KIND=none
  local scan="${SGE_DOCTOR_PATH-$PATH}"
  shopt -s nocasematch
  local IFS=:
  for d in $scan; do
    [ -n "$d" ] || continue
    if [ -e "$d/bash" ] || [ -e "$d/bash.exe" ]; then
      case "$d" in
        */system32|*/system32/*|*/windowsapps|*/windowsapps/*|*/sysnative|*/sysnative/*) FIRST_KIND=stub ;;
        *) FIRST_KIND=ok ;;
      esac
      break
    fi
  done
  shopt -u nocasematch
}

# Prints one line only when something is wrong. Arg: plugin root.
sge_doctor_quiet() {
  local root="$1"
  first_bash
  if [ "$FIRST_KIND" = stub ]; then
    echo "SGE doctor: $STUB_MSG Run /sge:env-health --doctor for details. $BREAK_GLASS"
  elif [ ! -f "$root/hooks/run-hook.cmd" ]; then
    echo "SGE doctor: hooks/run-hook.cmd is missing from the plugin, so hooks cannot run and will fail closed. Fix: reinstall with /plugin update sge. Run /sge:env-health --doctor for details. $BREAK_GLASS"
  fi
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
set -uo pipefail
MODE="${1:---quiet}"
ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
if [ "$MODE" = "--quiet" ]; then sge_doctor_quiet "$ROOT"; exit 0; fi

# --- full report ---
BAD=0
say() { printf '%s\n' "$*"; }
problem() { BAD=1; say "PROBLEM: $*"; }

kind_of() {
  case "$1" in
    */[Gg]it/*|*/[Gg]it-*/*) echo "Git for Windows bash" ;;
    /bin/*|/usr/*|/opt/homebrew/*|/home/linuxbrew/*) echo "system bash" ;;
    *) echo "bash outside the standard locations (path withheld)" ;;
  esac
}

say "SGE doctor"
# plugin version
pv="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
say "plugin: sge v${pv:-unknown}"

# client and version (semver only is echoed)
client=""
if [ -n "${CLAUDECODE:-}" ] || [ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ] || [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then client=claude
elif [ -n "$(env | grep -m1 '^COPILOT_' )" ]; then client=copilot
elif command -v claude >/dev/null 2>&1; then client=claude
elif command -v copilot >/dev/null 2>&1; then client=copilot; fi
ver() { case "$(command -v "$1" 2>/dev/null)" in /*|[A-Za-z]:*) "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 ;; esac; }
case "$client" in
  claude) cv="$(ver claude)"; say "client: Claude Code v${cv:-unknown}" ;;
  copilot) cv="$(ver copilot)"; say "client: Copilot CLI v${cv:-unknown}" ;;
  *) say "client: not detected (run from inside Claude Code or Copilot CLI)" ;;
esac

# PATH order
first_bash
case "$FIRST_KIND" in
  stub) problem "$STUB_MSG" ;;
  ok) say "PATH: first bash is not a WSL launcher stub" ;;
  none) say "PATH: no bash on PATH; the launcher falls back to standard locations" ;;
esac

# Which bash the hooks use and whether the launcher runs: reuse the real launcher with a probe script.
probe="$(. "$ROOT/hooks/run-hook.cmd" "$ROOT/hooks/lib/doctor-probe.sh" 2>&1)"
rc=$?
if [ "$rc" = 0 ] && [[ "$probe" == probe-ok* ]]; then
  pb="${probe#probe-ok }"
  say "bash used by hooks: $(kind_of "$pb"), chosen by hooks/run-hook.cmd (the running bash, else the first working one; WSL stubs are skipped)"
  say "launcher: hooks/run-hook.cmd runs"
else
  problem "hooks/run-hook.cmd could not run a hook (exit $rc), so every hook fails closed. Fix: install Git for Windows (or bash on Linux/macOS) and $FIX_PATH. Launcher said: $(printf '%s' "$probe" | tr -d '\r' | grep -m1 '^SGE hook launcher:' | sed -E 's#([A-Za-z]:)?[/\]+(Users|home)[/\]+[^ /\\"]*#<home>#g' | head -c 300)"
fi

# each hook command line: run it the way the client does (its command shell, CLAUDE_PLUGIN_ROOT set),
# in a throwaway cwd/HOME with a benign payload, no network. Exit 0 means it runs.
scrub() { sed -E 's#([A-Za-z]:)?[/\]+(Users|home)[/\]+[^ /\\"]*#<home>#g' | tr -d '\r' | head -c 200; }
[ -f "$ROOT/hooks/hooks.json" ] || problem "hooks/hooks.json is missing. Fix: /plugin update sge."
TMP="$(mktemp -d 2>/dev/null)"; n=0; failed=0
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 20"
PAYLOAD='{"hook_event_name":"PreToolUse","session_id":"doctor","tool_name":"Bash","tool_input":{"command":"ls"},"stop_hook_active":true}'
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  n=$((n+1)); name="$(printf '%s' "$cmd" | grep -oE '[A-Za-z0-9_.-]+\.sh' | tail -1)"
  err="$(cd "$TMP" && printf '%s' "$PAYLOAD" | env CLAUDE_PLUGIN_ROOT="$ROOT" HOME="$TMP" SGE_SESSION_DIR="$TMP/sess" SGE_REMOTE_VERSION= SGE_DIGEST_PATH= $TO "$BASH" -c "$cmd" 2>&1 >/dev/null)"; hrc=$?
  if [ "$hrc" = 0 ]; then say "hook ${name:-?}: runs (exit 0)"
  else failed=$((failed+1)); problem "hook ${name:-?} exited $hrc when run as the client runs it. Output: $(printf '%s' "$err" | grep -m1 . | scrub). Fix: $FIX_PATH, or /plugin update sge if the script is missing."; fi
done < <(sed -n 's/^[[:space:]]*"command":[[:space:]]*"\(.*\)",\{0,1\}[[:space:]]*$/\1/p' "$ROOT/hooks/hooks.json" 2>/dev/null | sed 's/\\"/"/g' | sort -u)
rm -rf "$TMP" 2>/dev/null
[ "$n" -gt 0 ] || problem "no hook commands found in hooks/hooks.json"
say "hook commands: $n run, $failed failed"

if [ "$BAD" = 1 ]; then
  say "$BREAK_GLASS"
  exit 1
fi
say "healthy: nothing to fix"
exit 0
