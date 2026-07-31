#!/usr/bin/env bash
# check-agent-security.sh — the mechanical C11 "Agent Security (Zero-Trust)" drift check.
# ---------------------------------------------------------------------------------------
# Single source of truth for `/sgd:sgd-align` C11 and its `--dimension agent-security`
# standalone mode (#842, parent #737). Mirrors the C12 check-regulatory-trace.sh script
# contract exactly: read-only, emits one JSON block on stdout, and exits:
#   0 = no failing control      1 = one or more failing controls      2 = harness error
#
# FIVE controls — ZT-1..ZT-5, mapped to docs-site/governance/zero-trust-ai-agents.md.
# ZT-6 ("Scoring dimension") was DROPPED (#842): it passed by definition whenever the
# check ran — a self-referential vanity control adding +16.7% to every score. The
# dimension is scored /5; partial (🟡) counts 0.5:
#   score = round(100 × (passing + 0.5 × partial) / applicableControls)
#
#   ZT-1 Least-Agency        — no fullcontrol/allsites.manage/allfiles.write scope in
#                              any mcp config, .env.example, or CI workflow file
#   ZT-2 Tool-chaining/Exfil — WTP_EMAIL_ALLOWLIST declared AND non-empty in those files
#   ZT-3 Prompt Injection    — every skills/*/SKILL.md carries a `<!-- UNTRUSTED DATA`
#                              annotation (the annotation form, not a prose mention).
#                              This verifiably fails the sgd repo itself at wiring time —
#                              the script reports that honestly (fail + the unannotated
#                              files); it never special-cases the home repo. `na` when
#                              the repo has no skills/*/SKILL.md (excluded from /5).
#   ZT-4 Supply-chain/AI-BOM — sbom/ai-bom.cdx.json AND .github/workflows/
#                              ai-supply-chain.yml both exist -> then freshness is
#                              satisfiable two ways (either passes): (a) the workflow
#                              runs the generator in --check (content-sync) mode, which
#                              fails CI the instant the BOM drifts from the live AI
#                              surface — a stronger guarantee than a timestamp, and a
#                              content-anchored generator deliberately emits no
#                              metadata.timestamp so --check stays deterministic; OR
#                              (b) a metadata.timestamp within 90 days. Neither present
#                              (no content-sync gate AND no/unparsable/stale timestamp)
#                              = partial (wiring exists, freshness unverifiable/stale);
#                              either file absent = fail
#   ZT-5 Agent Identity      — >= 80% of branch commits (origin/<default>..HEAD; falls
#                              back to the last 50 commits on HEAD) carry an `Agent-Id:`
#                              trailer, OR 0 agent commits (all-human history) = pass
#
# Like the C12 script it is bash + git/grep/sed/awk only (no jq, runs anywhere CI does)
# and deliberately conservative: evidence it cannot positively verify is reported as
# partial/fail with the reason — never a fabricated pass.
#
# Usage: check-agent-security.sh [repo-root]
#   $1 (optional) — repo root to audit. Must be a trusted, tool-resolved path. Defaults
#   to the enclosing git toplevel (or `.`). A non-directory $1 is a harness error (2).
set -euo pipefail

if [ -n "${1:-}" ]; then
  if [ ! -d "$1" ]; then
    echo "check-agent-security.sh: repo root not found: $1" >&2
    exit 2
  fi
  ROOT="$(cd "$1" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
fi
SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

# JSON built by interpolation — escape backslashes and double-quotes so paths and
# evidence strings can never corrupt the audit record (same convention as C12).
json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

pass_n=0; partial_n=0; fail_n=0; na_n=0
controls_json=""; findings_json=""
add_control() { # id name status evidence
  case "$3" in
    pass)    pass_n=$((pass_n+1)) ;;
    partial) partial_n=$((partial_n+1)) ;;
    fail)    fail_n=$((fail_n+1)) ;;
    na)      na_n=$((na_n+1)) ;;
  esac
  controls_json="${controls_json}{\"id\":\"$1\",\"name\":\"$2\",\"status\":\"$3\",\"evidence\":\"$(json_esc "$4")\"},"
  if [ "$3" = fail ] || [ "$3" = partial ]; then
    sev=high; [ "$3" = partial ] && sev=medium
    findings_json="${findings_json}{\"artefact\":\"$(json_esc "$2")\",\"severity\":\"${sev}\",\"check\":\"C11-$1\",\"finding\":\"$(json_esc "$4")\"},"
  fi
}

# --- shared scan set: mcp configs, env examples, CI workflows -----------------------------
# git-tracked files only (mirrors C12's ls-files enumeration; untracked scratch never
# counts as governance evidence).
SCAN_FILES="$(git -C "$ROOT" ls-files -- \
  '.env.example' '*.env.example' '.mcp.json' '*mcp*.json' '*mcp*.yaml' '*mcp*.yml' \
  '*mcp*.toml' '.github/workflows/*.yml' '.github/workflows/*.yaml' 2>/dev/null | sort -u || true)"
scan_count="$(printf '%s\n' "$SCAN_FILES" | sed '/^$/d' | wc -l | tr -d ' ')"

# --- ZT-1 Least-Agency ---------------------------------------------------------------------
zt1_hits=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if grep -aqiE 'fullcontrol|allsites\.manage|allfiles\.write' "${ROOT}/${f}" 2>/dev/null; then
    zt1_hits="${zt1_hits}${f}, "
  fi
done <<< "$SCAN_FILES"
if [ -n "$zt1_hits" ]; then
  add_control ZT-1 "Least-Agency" fail "over-privileged scope (fullcontrol/allsites.manage/allfiles.write) found in: ${zt1_hits%, }"
elif [ "$scan_count" = 0 ]; then
  add_control ZT-1 "Least-Agency" pass "no mcp/env/CI config files tracked — nothing declares scopes"
else
  add_control ZT-1 "Least-Agency" pass "no fullcontrol/allsites.manage/allfiles.write scope in ${scan_count} scanned config files"
fi

# --- ZT-2 Tool-chaining / Exfil --------------------------------------------------------------
zt2_file=""; zt2_nonempty=false
while IFS= read -r f; do
  [ -z "$f" ] && continue
  line="$(grep -ahE 'WTP_EMAIL_ALLOWLIST' "${ROOT}/${f}" 2>/dev/null | head -1 || true)"
  [ -z "$line" ] && continue
  [ -z "$zt2_file" ] && zt2_file="$f"
  # value = everything after the first = or :, stripped of quotes/spaces
  val="$(printf '%s' "$line" | sed -E 's/.*WTP_EMAIL_ALLOWLIST[^=:]*[=:]//; s/["'"'"' ,]//g')"
  [ -n "$val" ] && { zt2_nonempty=true; zt2_file="$f"; }
done <<< "$SCAN_FILES"
if [ -z "$zt2_file" ]; then
  add_control ZT-2 "Tool-chaining/Exfil" fail "WTP_EMAIL_ALLOWLIST not declared in any CI workflow, .env.example, or mcp config"
elif [ "$zt2_nonempty" = true ]; then
  add_control ZT-2 "Tool-chaining/Exfil" pass "WTP_EMAIL_ALLOWLIST declared and non-empty in ${zt2_file}"
else
  add_control ZT-2 "Tool-chaining/Exfil" fail "WTP_EMAIL_ALLOWLIST declared in ${zt2_file} but its value is empty"
fi

# --- ZT-3 Prompt Injection -------------------------------------------------------------------
SKILL_FILES="$(git -C "$ROOT" ls-files -- 'skills/*/SKILL.md' 2>/dev/null || true)"
skill_total=0; zt3_missing=""; zt3_missing_n=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  skill_total=$((skill_total+1))
  if ! grep -aq '<!-- UNTRUSTED DATA' "${ROOT}/${f}" 2>/dev/null; then
    zt3_missing_n=$((zt3_missing_n+1))
    [ "$zt3_missing_n" -le 8 ] && zt3_missing="${zt3_missing}${f}, "
  fi
done <<< "$SKILL_FILES"
if [ "$skill_total" = 0 ]; then
  add_control ZT-3 "Prompt Injection" na "no skills/*/SKILL.md in this repo — control not applicable"
elif [ "$zt3_missing_n" = 0 ]; then
  add_control ZT-3 "Prompt Injection" pass "<!-- UNTRUSTED DATA --> annotation present in all ${skill_total} skills/*/SKILL.md"
else
  more=""; [ "$zt3_missing_n" -gt 8 ] && more="… (+$((zt3_missing_n-8)) more)"
  add_control ZT-3 "Prompt Injection" fail "$((skill_total-zt3_missing_n))/${skill_total} skills annotated; missing <!-- UNTRUSTED DATA --> in: ${zt3_missing%, }${more}"
fi

# --- ZT-4 Supply-chain / AI-BOM ---------------------------------------------------------------
BOM_REL="sbom/ai-bom.cdx.json"; WF_REL=".github/workflows/ai-supply-chain.yml"
missing=""
[ -f "${ROOT}/${BOM_REL}" ] || missing="${missing}${BOM_REL}, "
[ -f "${ROOT}/${WF_REL}" ]  || missing="${missing}${WF_REL}, "
if [ -n "$missing" ]; then
  add_control ZT-4 "Supply-chain/AI-BOM" fail "absent: ${missing%, }"
else
  # Freshness is satisfiable two ways; either is sufficient for a pass:
  #  (a) a deterministic content-sync gate — the AI-BOM workflow runs the
  #      generator in --check mode, which fails CI the instant the committed BOM
  #      drifts from the repo's live AI surface. That is a STRONGER guarantee than
  #      a timestamp (a timestamp can be present yet stale), and a content-anchored
  #      generator deliberately emits no metadata.timestamp so --check stays a pure,
  #      deterministic content comparison. Absent timestamp is then by-design, not a
  #      freshness gap. This is what sgd's own generate-ai-bom.sh does (issue #875).
  #  (b) a metadata.timestamp within 90 days — for BOMs refreshed on a cadence
  #      rather than gated by content-sync.
  ts="$(grep -aoE '"timestamp"[[:space:]]*:[[:space:]]*"[^"]+"' "${ROOT}/${BOM_REL}" 2>/dev/null \
        | head -1 | sed -E 's/.*:[[:space:]]*"//; s/"$//' || true)"
  content_sync=0
  if grep -aqE 'generate-ai-bom\.sh[^#]*--check' "${ROOT}/${WF_REL}" 2>/dev/null; then
    content_sync=1
  fi
  if [ "$content_sync" = 1 ]; then
    if [ -z "$ts" ]; then
      add_control ZT-4 "Supply-chain/AI-BOM" pass "${BOM_REL} + ${WF_REL} exist; freshness enforced by deterministic content-sync gate (generate-ai-bom.sh --check); no metadata.timestamp required by design"
    else
      add_control ZT-4 "Supply-chain/AI-BOM" pass "${BOM_REL} + ${WF_REL} exist; freshness enforced by content-sync gate (generate-ai-bom.sh --check); BOM timestamp ${ts}"
    fi
  elif [ -z "$ts" ]; then
    add_control ZT-4 "Supply-chain/AI-BOM" partial "both artefacts exist but the BOM has no metadata.timestamp and the workflow has no content-sync (--check) gate — freshness unverifiable"
  else
    ts_epoch="$(date -u -d "$ts" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || true)"
    now_epoch="$(date -u +%s)"
    if [ -z "$ts_epoch" ]; then
      add_control ZT-4 "Supply-chain/AI-BOM" partial "both artefacts exist but metadata.timestamp '${ts}' is unparsable — freshness unverifiable"
    elif [ $((now_epoch - ts_epoch)) -le $((90*86400)) ]; then
      add_control ZT-4 "Supply-chain/AI-BOM" pass "${BOM_REL} + ${WF_REL} exist; BOM timestamp ${ts} within 90 days"
    else
      add_control ZT-4 "Supply-chain/AI-BOM" partial "both artefacts exist but BOM timestamp ${ts} is stale (older than 90 days)"
    fi
  fi
fi

# --- ZT-5 Agent Identity -----------------------------------------------------------------------
DEFAULT="$(git -C "$ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
DEFAULT="${DEFAULT:-main}"
scope="commits on origin/${DEFAULT}..HEAD"
if git -C "$ROOT" rev-parse --verify --quiet "origin/${DEFAULT}" >/dev/null 2>&1 \
   && [ "$(git -C "$ROOT" rev-list --count "origin/${DEFAULT}..HEAD" 2>/dev/null || echo 0)" -gt 0 ]; then
  log="$(git -C "$ROOT" log "origin/${DEFAULT}..HEAD" --format='%H%x09%(trailers:key=Agent-Id,valueonly)' 2>/dev/null || true)"
else
  scope="the last 50 commits on HEAD"
  log="$(git -C "$ROOT" log -50 --format='%H%x09%(trailers:key=Agent-Id,valueonly)' 2>/dev/null || true)"
fi
zt5_total="$(printf '%s\n' "$log" | awk -F'\t' '$1 ~ /^[0-9a-f]{7,40}$/ {t++} END{print t+0}')"
zt5_agent="$(printf '%s\n' "$log" | awk -F'\t' '$1 ~ /^[0-9a-f]{7,40}$/ && $2 != "" {a++} END{print a+0}')"
if [ "$zt5_total" = 0 ]; then
  add_control ZT-5 "Agent Identity" pass "no commits found (empty history) — nothing to attribute"
elif [ "$zt5_agent" = 0 ]; then
  add_control ZT-5 "Agent Identity" pass "all ${zt5_total} of ${scope} are human (0 Agent-Id trailers) — pass per control definition"
else
  pct=$((100 * zt5_agent / zt5_total))
  if [ "$pct" -ge 80 ]; then
    add_control ZT-5 "Agent Identity" pass "${pct}% (${zt5_agent}/${zt5_total}) of ${scope} carry an Agent-Id: trailer"
  else
    add_control ZT-5 "Agent Identity" fail "only ${pct}% (${zt5_agent}/${zt5_total}) of ${scope} carry an Agent-Id: trailer (< 80%)"
  fi
fi

# --- score + emit --------------------------------------------------------------------------------
applicable_n=$((pass_n + partial_n + fail_n))
applicable=true; status=pass; score=0
if [ "$applicable_n" = 0 ]; then
  applicable=false; status=na
else
  # round(100 × (pass + 0.5×partial) / applicable) in integer arithmetic
  score=$(( (200*pass_n + 100*partial_n + applicable_n) / (2*applicable_n) ))
  [ "$fail_n" -gt 0 ] && status=fail
fi

controls_json="[${controls_json%,}]"
findings_json="[${findings_json%,}]"

printf '%s\n' "{
  \"check\": \"C11\",
  \"name\": \"Agent Security (Zero-Trust)\",
  \"layer\": \"agent-security\",
  \"sha\": \"${SHA}\",
  \"applicable\": ${applicable},
  \"status\": \"${status}\",
  \"score\": ${score},
  \"passing\": ${pass_n},
  \"partial\": ${partial_n},
  \"failing\": ${fail_n},
  \"notApplicable\": ${na_n},
  \"totalControls\": 5,
  \"applicableControls\": ${applicable_n},
  \"high\": ${fail_n},
  \"medium\": ${partial_n},
  \"controls\": ${controls_json},
  \"findings\": ${findings_json}
}"

[ "$fail_n" -gt 0 ] && exit 1 || exit 0
