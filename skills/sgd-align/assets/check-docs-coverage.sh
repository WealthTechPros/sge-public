#!/usr/bin/env bash
# check-docs-coverage.sh — the mechanical docs-coverage coherence metric.
# ---------------------------------------------------------------------------------------
# Single source of truth for `/sgd:sgd-align`'s docs-coverage fleet metric, folded
# into the coherence composite so it moves the Audit Score number (#841, parent #740).
# Mirrors the C11 check-agent-security.sh contract: read-only, one JSON block on
# stdout, and exits:
#   0 = fully covered OR nothing to measure (N/A)   1 = >=1 undocumented artefact
#   2 = harness error
#
# docs-coverage = % of governed artefacts (capabilities + feature specs) that carry
# CURRENT documentation:
#   * A FEATURE SPEC is a git-tracked markdown file whose YAML front-matter carries
#     a `ref:` matching SPEC-/SGD-. It is "current-documented" iff it has a non-empty
#     prose body below the front-matter AND its `status:` is not one of
#     deprecated / superseded / retired / obsolete (a stub or a retired doc is not
#     current documentation).
#   * A CAPABILITY is a `CAP-*` id declared with an `id:` key in a
#     capability-model.y*ml. It is documented iff at least one current-documented
#     feature spec cites it via front-matter `capability:`.
#   score = round(100 × (documentedCaps + documentedSpecs) / (totalCaps + totalSpecs))
#
# HONESTY / scope: "current" here is the mechanically-verifiable signal — the doc
# exists, has real body, and is not status-retired. Deeper staleness (a doc older
# than the code it describes, drift against a success_measure) is C13's job, not
# this file-only metric's; this never fabricates a freshness verdict it cannot see.
# Capability extraction counts every CAP-* id declared with an `id:` key, which in a
# nested SGD model includes domain-level nodes — an over-count that is honest and
# consistent, never a silently-narrowed denominator.
#
# bash + git/grep/sed/awk only (no jq) so it runs anywhere CI does.
#
# Usage: check-docs-coverage.sh [repo-root]
#   $1 (optional) — repo root to audit. Trusted tool-resolved path; defaults to the
#   enclosing git toplevel (or `.`). A non-directory $1 is a harness error (2).
set -euo pipefail

if [ -n "${1:-}" ]; then
  if [ ! -d "$1" ]; then
    echo "check-docs-coverage.sh: repo root not found: $1" >&2
    exit 2
  fi
  ROOT="$(cd "$1" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
fi
SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# --- parse one candidate .md into: ref<TAB>capability<TAB>status<TAB>hasbody -------
# Emits nothing unless the file has front-matter with a ref: SPEC-/SGD-.
parse_spec() {
  awk '
    BEGIN{fm=0;ref="";cap="";st="";body=0}
    { sub(/\r$/,"") }
    NR==1 && /^---[[:space:]]*$/ {fm=1;next}
    fm==1 && /^---[[:space:]]*$/ {fm=2;next}
    fm==1 {
      if (match($0,/^ref:[[:space:]]*/))              {ref=substr($0,RLENGTH+1)}
      else if (match($0,/^capability:[[:space:]]*/))  {cap=substr($0,RLENGTH+1)}
      else if (match($0,/^status:[[:space:]]*/))      {st=substr($0,RLENGTH+1)}
      next
    }
    fm==2 && /[^[:space:]]/ {body=1}
    END{
      gsub(/^[ \t]+|[ \t]+$/,"",ref)
      gsub(/^[ \t]+|[ \t]+$/,"",cap)
      gsub(/^[ \t]+|[ \t]+$/,"",st)
      if (ref ~ /^(SPEC|SGD)-/) printf "%s\t%s\t%s\t%d\n", ref, cap, tolower(st), body
    }
  ' "$1"
}

is_current() { # status -> 0 if current, 1 if a non-current (retired-family) status
  case "$1" in
    deprecated|superseded|retired|obsolete) return 1 ;;
    *) return 0 ;;
  esac
}

# --- scan feature specs ------------------------------------------------------------
tot_specs=0; doc_specs=0
cited_caps=""          # capabilities cited by a current-documented spec
spec_findings=""       # JSON finding objects for undocumented specs

MD_FILES="$(git -C "$ROOT" ls-files -- '*.md' 2>/dev/null || true)"
while IFS= read -r f; do
  [ -z "$f" ] && continue
  parsed="$(parse_spec "${ROOT}/${f}" 2>/dev/null || true)"
  [ -z "$parsed" ] && continue
  ref="$(printf '%s' "$parsed" | cut -f1)"
  cap="$(printf '%s' "$parsed" | cut -f2)"
  st="$(printf '%s' "$parsed"  | cut -f3)"
  body="$(printf '%s' "$parsed" | cut -f4)"
  tot_specs=$((tot_specs+1))
  reason=""
  [ "$body" != 1 ] && reason="empty body (stub spec — no documentation)"
  if is_current "$st"; then :; else
    [ -n "$reason" ] && reason="$reason; " ; reason="${reason}status '${st}' is not current (retired/deprecated)"
  fi
  if [ -z "$reason" ]; then
    doc_specs=$((doc_specs+1))
    [ -n "$cap" ] && cited_caps="${cited_caps}${cap}
"
  else
    spec_findings="${spec_findings}{\"artefact\":\"$(json_esc "$ref") (${f})\",\"severity\":\"medium\",\"check\":\"docs-coverage-feature\",\"finding\":\"$(json_esc "$reason")\"},"
  fi
done <<< "$MD_FILES"

cited_sorted="$(printf '%s' "$cited_caps" | sed '/^$/d' | sort -u)"

# --- scan capability model(s) ------------------------------------------------------
tot_caps=0; doc_caps=0; cap_findings=""
MODEL_FILES="$(git -C "$ROOT" ls-files -- '*capability-model.yaml' '*capability-model.yml' 2>/dev/null || true)"
# Capability ids carry internal hyphens (CAP-INSIGHT-POSTURE) — the char class
# MUST include '-' or leaf ids collapse to their domain prefix and never match a
# spec's front-matter capability: citation.
CAPS="$(while IFS= read -r mf; do
  [ -z "$mf" ] && continue
  grep -hoE 'id:[[:space:]]*CAP-[A-Z0-9_-]+' "${ROOT}/${mf}" 2>/dev/null | grep -oE 'CAP-[A-Z0-9_-]+'
done <<< "$MODEL_FILES" | sort -u)"

model_present=false
[ -n "$(printf '%s' "$MODEL_FILES" | sed '/^$/d')" ] && model_present=true

while IFS= read -r c; do
  [ -z "$c" ] && continue
  tot_caps=$((tot_caps+1))
  if printf '%s\n' "$cited_sorted" | grep -qxF "$c"; then
    doc_caps=$((doc_caps+1))
  else
    cap_findings="${cap_findings}{\"artefact\":\"$(json_esc "$c")\",\"severity\":\"medium\",\"check\":\"docs-coverage-capability\",\"finding\":\"capability declared in model but cited by no current-documented spec\"},"
  fi
done <<< "$CAPS"

# --- score + emit ------------------------------------------------------------------
documented=$((doc_caps + doc_specs))
total=$((tot_caps + tot_specs))
findings_json="[${cap_findings}${spec_findings}"; findings_json="${findings_json%,}]"

if [ "$total" = 0 ]; then
  applicable=false; status=na; score=0
  printf '%s\n' "{
  \"check\": \"docs-coverage\",
  \"name\": \"Docs Coverage\",
  \"layer\": \"docs-coverage\",
  \"sha\": \"${SHA}\",
  \"applicable\": false,
  \"status\": \"na\",
  \"score\": 0,
  \"documented\": 0,
  \"total\": 0,
  \"pass\": 0,
  \"fail\": 0,
  \"capabilities\": { \"documented\": 0, \"total\": 0, \"modelPresent\": ${model_present} },
  \"features\": { \"documented\": 0, \"total\": 0 },
  \"findings\": []
}"
  exit 0
fi

# round(100 × documented / total)
score=$(( (200*documented + total) / (2*total) ))
if [ "$documented" = "$total" ]; then status=pass; else status=warn; fi

printf '%s\n' "{
  \"check\": \"docs-coverage\",
  \"name\": \"Docs Coverage\",
  \"layer\": \"docs-coverage\",
  \"sha\": \"${SHA}\",
  \"applicable\": true,
  \"status\": \"${status}\",
  \"score\": ${score},
  \"documented\": ${documented},
  \"total\": ${total},
  \"pass\": ${documented},
  \"fail\": $((total - documented)),
  \"capabilities\": { \"documented\": ${doc_caps}, \"total\": ${tot_caps}, \"modelPresent\": ${model_present} },
  \"features\": { \"documented\": ${doc_specs}, \"total\": ${tot_specs} },
  \"findings\": ${findings_json}
}"

[ "$documented" -lt "$total" ] && exit 1 || exit 0
