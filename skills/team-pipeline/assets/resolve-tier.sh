#!/usr/bin/env bash
# resolve-tier.sh — per-lane model-tier resolution for /sge:team-pipeline
# (issue #2488). Every dispatched impl lane inherits the session model (a
# session pinned to a large-context, high-cost model runs a dead-file
# deletion on the same tier as a schema migration). This script gives each
# queue entry an explicit `tier`
# (haiku|sonnet|opus) from cheap, deterministic signals, so the orchestrator
# can pass `model: <tier>` to Agent(name, model:) instead of a bare spawn that
# silently inherits whatever model the session happens to be running.
#
# Tier heuristic (per issue #2488's "Proposed" + agents/agent-registry.md's
# routing table, which this mirrors rather than replaces):
#   haiku  — mechanical/docs/rename, <=50 changed-lines estimate (from the
#            issue's file-map line-count hints, when present), no
#            schema/UI/migration signal.
#   sonnet — the default: anything not clearly haiku- or opus-shaped.
#   opus   — migration, cross-package schema change, auth, or UI work needing
#            design judgement. Also the CRITICAL escalation rule from
#            agent-registry.md: security/auth, DB migrations, or
#            multi-tenant/data-isolation boundaries ALWAYS escalate to opus
#            regardless of how mechanical the rest of the signal looks — this
#            check runs LAST and overrides haiku/sonnet if it matches.
#
# Contract (same family as reconcile-flush.sh):
#   * resolve_tier <title> <body> -> prints "haiku"|"sonnet"|"opus" to stdout,
#     exit 0 always (never fails — an unclassifiable issue defaults to sonnet,
#     the safe non-trivial-non-critical floor).
#   * Sourceable: sourcing (BASH_SOURCE[0] != $0) defines the helpers and
#     returns without running main, so the regression suite can unit-test
#     resolve_tier directly.
#   * main() (script-invoked): `resolve-tier.sh <N>` reads the issue's
#     title+body via `gh issue view` and prints the resolved tier. Exit 2 on
#     harness error (gh unavailable / issue not found).
#
# Run:  bash resolve-tier.sh 2488            # resolve tier for issue #2488
#       source resolve-tier.sh; resolve_tier "$TITLE" "$BODY"   # unit-testable

# NO `set -e` at file scope: this file is sourced by the test suite.

# CRITICAL escalation signal (agents/agent-registry.md's CRITICAL escalation
# rule) — security/auth, DB migrations, multi-tenant/data-isolation. Checked
# LAST so it always overrides a haiku/sonnet match on the same text.
_critical_signal() {
  printf '%s' "$1" | grep -qiE \
    'migrat(e|ion)|schema change|\bauth\b|authentication|authorization|multi-tenant|multi-tenancy|tenant isolation|data isolation|\bsecret(s)?\b|credential'
}

# opus signal — migration/cross-package schema/UI-needing-design-judgement,
# per issue #2488's Proposed section (checked before the mechanical/haiku
# signal so a "small migration" doesn't get mis-routed as haiku).
_opus_signal() {
  printf '%s' "$1" | grep -qiE \
    'migrat(e|ion)|cross-package|schema change|design judgement|design judgment|\bux\b|redesign|architecture'
}

# haiku signal — mechanical/docs/rename with no schema/UI/migration touch.
_haiku_signal() {
  printf '%s' "$1" | grep -qiE \
    '\b(typo|rename|renaming|doc(s)?|documentation|lint|formatting|wording)\b' \
    && ! _opus_signal "$1"
}

# haiku line-count signal — an explicit "<=N lines" / "N lines changed" hint
# in the issue body, honoured only when N <= 50 (issue #2488's stated bound).
_haiku_linecount_signal() {
  local n
  n=$(printf '%s' "$1" | grep -oiE '(<=|under|less than)?[[:space:]]*[0-9]+[[:space:]]*lines?' \
        | grep -oE '[0-9]+' | head -1)
  [ -n "$n" ] && [ "$n" -le 50 ] 2>/dev/null
}

# resolve_tier <title> <body> — prints the resolved tier to stdout. Always
# exits 0; an issue matching no signal defaults to "sonnet" (the safe,
# non-trivial-non-critical floor per agent-registry.md).
resolve_tier() {
  local title=${1:-} body=${2:-} text tier
  text="$title
$body"

  if _haiku_signal "$text" || _haiku_linecount_signal "$text"; then
    tier="haiku"
  elif _opus_signal "$text"; then
    tier="opus"
  else
    tier="sonnet"
  fi

  # CRITICAL escalation always wins, regardless of how mechanical the rest of
  # the signal looked (agent-registry.md CRITICAL escalation rule).
  if _critical_signal "$text"; then
    tier="opus"
  fi

  printf '%s' "$tier"
  return 0
}

main() {
  local issue=$1
  if [ -z "$issue" ]; then
    echo "resolve-tier: usage: resolve-tier.sh <issue-number>" >&2
    return 2
  fi
  local json title body
  json=$(gh issue view "$issue" --json title,body 2>/dev/null) || {
    echo "resolve-tier: gh issue view failed for #$issue" >&2
    return 2
  }
  title=$(printf '%s' "$json" | jq -r '.title // ""')
  body=$(printf '%s' "$json" | jq -r '.body // ""')
  resolve_tier "$title" "$body"
  printf '\n'
  return 0
}

# Run only when executed, not when sourced (so tests can source the helpers).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit "$?"
fi
