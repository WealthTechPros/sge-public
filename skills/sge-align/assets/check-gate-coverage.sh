#!/usr/bin/env bash
# check-gate-coverage.sh — the mechanical gate-coverage governance-posture metric.
# ---------------------------------------------------------------------------------------
# Single source of truth for `/sge:sge-align`'s gate-coverage fleet metric (#841,
# parent #740, spec SGD-048 Repository Governance Posture). Mirrors the C11
# check-agent-security.sh / C12 check-regulatory-trace.sh contract exactly:
# read-only, emits one JSON block on stdout, and exits:
#   0 = every gate installed AND PR-blocking   1 = >=1 gate missing/not-blocking
#   2 = harness error
#
# Reports, per repo, which of the FOUR standard enforcement workflows are
# installed and would actually block a pull request:
#   G1 require-pr-reviewed-label  (.github/workflows/require-pr-reviewed-label.yml)
#   G2 require-commit-trailer     (.github/workflows/require-commit-trailer.yml)
#   G3 ai-supply-chain            (.github/workflows/ai-supply-chain.yml)
#   G4 check-tracking-close-keyword (.github/workflows/check-tracking-close-keyword.yml)
#
# Per-gate status (0.5 credit for partial, same formula as the ZT dimension):
#   pass    — workflow file present AND triggers on `pull_request` (can gate a PR)
#   partial — workflow file present but NOT pull_request-triggered (push/schedule
#             only): installed, running, but incapable of blocking a merge
#   fail    — workflow file absent
#   score = round(100 × (pass + 0.5 × partial) / 4)
#
# HONESTY / scope: this reads the repo's workflow FILES only — it proves a gate
# is installed and PR-triggered, i.e. *capable* of blocking. Whether GitHub has
# it wired as a REQUIRED status check in branch protection is a separate
# branch-protection dimension, only observable via the GitHub API (gh api
# repos/:o/:r/branches/main/protection) — out of this file-only script's scope;
# SGD-048's live posture scan owns that. This never fabricates a required-check
# verdict it cannot see from files.
#
# Like the C11/C12 scripts it is bash + git/grep/sed/awk only (no jq) so it runs
# anywhere CI does, and is deliberately conservative: a gate it cannot positively
# verify as PR-blocking is reported partial/fail with the reason, never a
# fabricated pass.
#
# Usage: check-gate-coverage.sh [repo-root]
#   $1 (optional) — repo root to audit. Must be a trusted, tool-resolved path.
#   Defaults to the enclosing git toplevel (or `.`). A non-directory $1 is a
#   harness error (2).
set -euo pipefail

if [ -n "${1:-}" ]; then
  if [ ! -d "$1" ]; then
    echo "check-gate-coverage.sh: repo root not found: $1" >&2
    exit 2
  fi
  ROOT="$(cd "$1" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
fi
SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

# JSON built by interpolation — escape backslashes and double-quotes so paths
# and evidence strings can never corrupt the audit record (same convention as
# the C11/C12 scripts).
json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

pass_n=0; partial_n=0; fail_n=0
gates_json=""; findings_json=""
add_gate() { # id name status evidence workflow-path
  case "$3" in
    pass)    pass_n=$((pass_n+1)) ;;
    partial) partial_n=$((partial_n+1)) ;;
    fail)    fail_n=$((fail_n+1)) ;;
  esac
  gates_json="${gates_json}{\"id\":\"$1\",\"workflow\":\"$(json_esc "$2")\",\"status\":\"$3\",\"evidence\":\"$(json_esc "$4")\"},"
  if [ "$3" = fail ] || [ "$3" = partial ]; then
    sev=high; [ "$3" = partial ] && sev=medium
    findings_json="${findings_json}{\"artefact\":\"$(json_esc "$5")\",\"severity\":\"${sev}\",\"check\":\"gate-coverage-$1\",\"finding\":\"$(json_esc "$4")\"},"
  fi
}

# --- returns 0 if the workflow file has a top-level `pull_request` trigger ------
# Scans only the `on:` block: either `on: pull_request`, `on: [pull_request,...]`,
# or a `pull_request:` key nested under a block-form `on:`. Stops at the first
# top-level (column-0) key after `on:` so a later job step mentioning
# "pull_request" can never produce a false positive.
pr_triggered() { # workflow-abs-path
  awk '
    /^[[:space:]]*#/ { next }
    # inline forms: on: pull_request  |  on: [push, pull_request]  | on: {pull_request: ...}
    /^on:[[:space:]]*.*pull_request/ { found=1; exit }
    /^on:[[:space:]]*$/ { inon=1; next }
    inon==1 {
      if ($0 ~ /^[A-Za-z]/) { exit }                 # left the on: block
      if ($0 ~ /pull_request/) { found=1; exit }
    }
    END { exit(found?0:1) }
  ' "$1"
}

check_gate() { # id workflow-basename
  local id="$1" name="$2" rel=".github/workflows/$2.yml" abs
  abs="${ROOT}/.github/workflows/$2.yml"
  if [ ! -f "$abs" ]; then
    # tolerate the .yaml extension too
    if [ -f "${ROOT}/.github/workflows/$2.yaml" ]; then abs="${ROOT}/.github/workflows/$2.yaml"; rel=".github/workflows/$2.yaml"; fi
  fi
  if [ ! -f "$abs" ]; then
    add_gate "$id" "$name" fail "workflow ${rel} absent — gate not installed" "$rel"
  elif pr_triggered "$abs"; then
    add_gate "$id" "$name" pass "${rel} installed and pull_request-triggered (can block a PR)" "$rel"
  else
    add_gate "$id" "$name" partial "${rel} installed but not pull_request-triggered — runs, but cannot block a PR merge" "$rel"
  fi
}

check_gate G1 require-pr-reviewed-label
check_gate G2 require-commit-trailer
check_gate G3 ai-supply-chain
check_gate G4 check-tracking-close-keyword

# --- score + emit --------------------------------------------------------------
total_gates=4
# round(100 × (pass + 0.5×partial) / 4) in integer arithmetic
score=$(( (200*pass_n + 100*partial_n + total_gates) / (2*total_gates) ))
status=pass
[ "$partial_n" -gt 0 ] && status=warn
[ "$fail_n" -gt 0 ] && status=fail

gates_json="[${gates_json%,}]"
findings_json="[${findings_json%,}]"

printf '%s\n' "{
  \"check\": \"gate-coverage\",
  \"name\": \"Gate Coverage (governance posture)\",
  \"layer\": \"governance-posture\",
  \"sha\": \"${SHA}\",
  \"status\": \"${status}\",
  \"score\": ${score},
  \"installed\": ${pass_n},
  \"partial\": ${partial_n},
  \"missing\": ${fail_n},
  \"totalGates\": ${total_gates},
  \"gates\": ${gates_json},
  \"findings\": ${findings_json}
}"

[ $((partial_n + fail_n)) -gt 0 ] && exit 1 || exit 0
