#!/usr/bin/env bash
# resolve-limits.sh — repo-level concurrency cap resolution for
# /sge:team-pipeline (issue #2488). Phase 0 computes agentMax/waveSize from a
# flat nproc-based formula and never consults a repo-level cap. ppp's
# `.claude/commands/team-pipeline-resources.md` documents a hard local ceiling
# ("max 3 impl lanes on one box, 5+ = CRASH, vitest forks <=2") that the
# plugin defaults ignore — running plugin defaults on that box put it in the
# crash row (2026-08-29: 7 concurrent lanes, new-worktree.sh timed out at 5m).
#
# This script resolves the effective agentMax/waveSize by honouring an
# optional repo-level cap file when present, falling back to the existing
# nproc-based Phase 0 defaults when absent — never raising above whatever the
# caller's own --agents/--wave-size flags or the hard ceilings already impose.
#
# Cap file: .claude/sge-limits.json at the repo root, e.g.:
#   { "maxAgents": 3, "maxWaveSize": 3 }
# Either key may be omitted; an omitted key falls back to the computed
# default for that key. A missing/unreadable/malformed file is NOT an error —
# it just means "no repo cap", so the computed default applies unchanged.
#
# Contract (same family as reconcile-flush.sh / resolve-tier.sh):
#   * resolve_limits <computed_agent_max> <computed_wave_size> [cap_file] ->
#     prints one JSON line to stdout:
#       {"agentMax":<N>,"waveSize":<N>,"capFile":"<path or empty>","capped":<bool>}
#     agentMax is hard-clamped to <=15, waveSize to <=5, exactly as Phase 0's
#     own ceilings do — a cap file can only LOWER the effective number, never
#     raise it past those absolutes.
#   * Sourceable: sourcing (BASH_SOURCE[0] != $0) defines the helpers and
#     returns without running main.
#   * main() (script-invoked): `resolve-limits.sh <computed_agent_max>
#     <computed_wave_size>` resolves against `.claude/sge-limits.json` at the
#     current git repo root (or CAP_FILE env override) and prints the JSON
#     line. Exit 0 always — a missing/bad cap file is not a harness error,
#     it's the documented fallback path.
#
# Run:  bash resolve-limits.sh 4 5             # honour repo cap file if present
#       CAP_FILE=/path/sge-limits.json bash resolve-limits.sh 4 5

# NO `set -e` at file scope: this file is sourced by the test suite.

_HARD_MAX_AGENTS=15
_HARD_MAX_WAVE=5

# json_int_field <json> <key> — extract an integer field's value, or empty
# when absent/non-numeric. No jq dependency (keeps the fallback path
# dependency-free — a missing jq must not make cap resolution fail closed).
_json_int_field() {
  local json=$1 key=$2 v
  v=$(printf '%s' "$json" | grep -oE "\"$key\"[[:space:]]*:[[:space:]]*[0-9]+" \
        | grep -oE '[0-9]+$' | head -1)
  printf '%s' "$v"
}

# json_str <raw> — emit a JSON-safe double-quoted string for arbitrary text
# (a cap-file path may contain backslashes/quotes on Windows). Mirrors
# reconcile-flush.sh's json_str.
_json_str() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# resolve_limits <computed_agent_max> <computed_wave_size> [cap_file] —
# prints the resolved JSON line. Always returns 0.
resolve_limits() {
  local computed_agents=$1 computed_wave=$2 cap_file=${3:-}
  local agents=$computed_agents wave=$computed_wave capped=false cap_json

  if [ -n "$cap_file" ] && [ -r "$cap_file" ]; then
    cap_json=$(cat "$cap_file" 2>/dev/null)
    local cap_agents cap_wave
    cap_agents=$(_json_int_field "$cap_json" "maxAgents")
    cap_wave=$(_json_int_field "$cap_json" "maxWaveSize")

    if [ -n "$cap_agents" ] && [ "$cap_agents" -lt "$agents" ] 2>/dev/null; then
      agents=$cap_agents; capped=true
    fi
    if [ -n "$cap_wave" ] && [ "$cap_wave" -lt "$wave" ] 2>/dev/null; then
      wave=$cap_wave; capped=true
    fi
  else
    cap_file=""
  fi

  # Hard ceilings always win, even over an (invalid) cap file that tried to
  # raise above them — a cap file can only lower, never raise, the effective
  # number past Phase 0's own absolutes.
  if [ "$agents" -gt "$_HARD_MAX_AGENTS" ] 2>/dev/null; then agents=$_HARD_MAX_AGENTS; fi
  if [ "$wave" -gt "$_HARD_MAX_WAVE" ] 2>/dev/null; then wave=$_HARD_MAX_WAVE; fi

  printf '{"agentMax":%s,"waveSize":%s,"capFile":%s,"capped":%s}' \
    "$agents" "$wave" "$(_json_str "$cap_file")" "$capped"
  return 0
}

main() {
  local computed_agents=$1 computed_wave=$2
  if [ -z "$computed_agents" ] || [ -z "$computed_wave" ]; then
    echo "resolve-limits: usage: resolve-limits.sh <computed_agent_max> <computed_wave_size>" >&2
    return 2
  fi
  local cap_file="${CAP_FILE:-}"
  if [ -z "$cap_file" ]; then
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null)
    [ -n "$root" ] && cap_file="$root/.claude/sge-limits.json"
  fi
  resolve_limits "$computed_agents" "$computed_wave" "$cap_file"
  printf '\n'
  return 0
}

# Run only when executed, not when sourced (so tests can source the helpers).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit "$?"
fi
