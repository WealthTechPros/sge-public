#!/usr/bin/env bash
# Real token telemetry reader for team-pipeline lanes (#857).
#
# WHY: pipeline lanes used to self-report a `tokensUsed` number in their
# completion files, and every orchestrator budget decision (session budget,
# per-lane ceilings, durable accounting) trusted it. The 2026-07-06 run proved
# those numbers fiction — lanes under-reported by 2-4x (guessed 16k-60k, actual
# 86k-150k). This library replaces the guess with the harness-MEASURED usage
# that hooks/token-meter.sh already emits, per assistant turn, into
# memory/token-usage.jsonl (token-governance schema v2 — the SGD-045 token-cost
# data plane's on-disk producer). Nothing here self-reports; it only reads what
# the meter measured.
#
# Correlation key: hooks/token-meter.sh tags every record it writes with the
# `agent` field from $SGE_AGENT_ID and the `repo` from the git origin remote.
# The orchestrator dispatches each lane with SGE_AGENT_ID="impl-<issue>", so a
# lane's real spend is exactly the sum of outputTokens over records whose
# `agent` == "impl-<issue>" for this repo. No self-report is consulted.
#
# Design: pure readers over a JSONL path — no globals, no side effects, safe to
# `source` from the skill's fenced bash. Missing file / no jq / no matches all
# degrade to "0" (a reader must never break the orchestrator's monitor loop).
#
# Run its tests: bash skills/tests/measured-usage.test.sh
set -uo pipefail

# measured_lane_tokens <jsonl> <agent-key> [<repo>]
#   Harness-measured output tokens for ONE lane: the sum of `outputTokens`
#   across all token-meter records whose `agent` field equals <agent-key>
#   (e.g. "impl-857"), optionally scoped to <repo> (org/repo). Missing file,
#   no jq, or no matching rows => "0". This is the number the orchestrator's
#   durable per-lane accounting persists instead of the completion file's
#   self-reported tokensUsed.
measured_lane_tokens() {
  local jsonl="${1:-}" agent="${2:-}" repo="${3:-}"
  [ -n "$jsonl" ] && [ -f "$jsonl" ] || { printf '0'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '0'; return 0; }
  jq -rs --arg agent "$agent" --arg repo "$repo" '
    [ .[]
      | select((.agent // "") == $agent)
      | select($repo == "" or (.repo // "") == $repo)
      | (.outputTokens // 0) ] | add // 0
  ' "$jsonl" 2>/dev/null || printf '0'
}

# measured_session_tokens <jsonl> [<repo>]
#   Harness-measured CUMULATIVE pipeline spend for the --session-budget guard:
#   the sum of `outputTokens` across every lane record (agent starts with
#   "impl-") plus the orchestrator's own turns (skill == "team-pipeline"),
#   optionally scoped to <repo>. Replaces the old
#   `jq '[.[].tokensUsed] | add' /tmp/*.json` self-report sum. Missing file /
#   no jq => "0".
measured_session_tokens() {
  local jsonl="${1:-}" repo="${2:-}"
  [ -n "$jsonl" ] && [ -f "$jsonl" ] || { printf '0'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '0'; return 0; }
  jq -rs --arg repo "$repo" '
    [ .[]
      | select($repo == "" or (.repo // "") == $repo)
      | select((.skill // "") == "team-pipeline" or ((.agent // "") | startswith("impl-")))
      | (.outputTokens // 0) ] | add // 0
  ' "$jsonl" 2>/dev/null || printf '0'
}

# compare_measured_vs_reported <measured> <reported> [<tolerance-pct>]
#   The AC3 regression check: makes a divergence between harness-measured usage
#   and any legacy self-reported number VISIBLE, so a silent regression back to
#   guessed numbers surfaces in logs/CI. Prints one machine-parseable line:
#     MEASURED=<m> REPORTED=<r> RATIO=<reported-as-%-of-measured> VERDICT=<v>
#   VERDICT is:
#     ok          reported within +/-<tolerance-pct> of measured (default 50)
#     divergent   reported outside that band (the 2026-07-06 failure mode)
#     no-measure  no measured data yet (token-meter absent / lane unmetered)
#   Returns non-zero ONLY for `divergent`. `no-measure` is soft (returns 0) so
#   an install without the token-meter hook is never treated as a regression.
#   Measured is always authoritative; reported is only ever the cross-check.
compare_measured_vs_reported() {
  local measured="${1:-0}" reported="${2:-0}" tol="${3:-50}"
  case "$measured" in ''|*[!0-9]*) measured=0 ;; esac
  case "$reported" in ''|*[!0-9]*) reported=0 ;; esac
  case "$tol" in ''|*[!0-9]*) tol=50 ;; esac
  if [ "$measured" -le 0 ]; then
    printf 'MEASURED=%s REPORTED=%s RATIO=- VERDICT=no-measure\n' "$measured" "$reported"
    return 0
  fi
  local pct=$(( reported * 100 / measured ))
  local lo=$(( 100 - tol )) hi=$(( 100 + tol ))
  local verdict="ok"
  if [ "$pct" -lt "$lo" ] || [ "$pct" -gt "$hi" ]; then
    verdict="divergent"
  fi
  printf 'MEASURED=%s REPORTED=%s RATIO=%s%% VERDICT=%s\n' "$measured" "$reported" "$pct" "$verdict"
  [ "$verdict" = "ok" ]
}
