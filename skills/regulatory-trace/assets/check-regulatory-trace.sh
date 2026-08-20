#!/usr/bin/env bash
# check-regulatory-trace.sh — the mechanical C12 "Regulatory traceability" drift check.
# ---------------------------------------------------------------------------------------
# Single source of truth for both `/sge:regulatory-trace review` and `/sge:sge-align` C12.
# Read-only. Emits a JSON block on stdout (schema in references/drift-check.md) and exits:
#   0 = no high-severity gaps      1 = one or more high-severity gaps      2 = harness error
#
# A gap is HIGH when: a spec under a `regulated: true` capability has no `regulatory:`
# mapping, OR a mapping references a catalogue id that is absent or `retired: true`.
#
# Bash (see shebang) + grep/sed/awk so it runs in CI with no extra toolchain. It is deliberately
# conservative: when it cannot positively parse an artefact it reports `convention-unknown`
# (a finding to investigate) rather than a false PASS — mirroring trust-fabric's collector
# contract (no fabricated status).
#
# Usage: check-regulatory-trace.sh [obligations-catalogue.yaml]
#   $1 (optional) — explicit path to the obligations catalogue. $1 must be a trusted,
#   tool-resolved path — never a value declared by the audited repo (a repo-supplied
#   path could point the check at a permissive catalogue). Resolution order when $1
#   is absent (#720):
#     1. the audited repo's own copy (the sge repo itself, or a repo that vendors one)
#     2. $CLAUDE_PLUGIN_ROOT, when the harness exports it
#     3. scripts/resolve-sge-root.sh (searches known plugin install roots — the
#        bootstrap fix for a session where CLAUDE_PLUGIN_ROOT is unset)
#     4. the catalogue bundled beside this script (the installed-plugin copy — works
#        even when neither of the above resolves)
#   A missing or unparsable catalogue is a HIGH `convention-unknown` finding and
#   status=fail — RT-2/RT-3 must never silently skip and produce a false PASS.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${1:-}" ]; then
  CATALOGUE="$1"
elif [ -f "${ROOT}/skills/regulatory-trace/assets/obligations-catalogue.yaml" ]; then
  # Prefer the audited repo's own copy: keeps sge-repo dogfooding honest (a locally
  # edited catalogue must be the one checked) and honours vendored catalogues.
  CATALOGUE="${ROOT}/skills/regulatory-trace/assets/obligations-catalogue.yaml"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/skills/regulatory-trace/assets/obligations-catalogue.yaml" ]; then
  CATALOGUE="${CLAUDE_PLUGIN_ROOT}/skills/regulatory-trace/assets/obligations-catalogue.yaml"
elif _resolved_root="$(bash "${SCRIPT_DIR}/../../../scripts/resolve-sge-root.sh" 2>/dev/null)" \
  && [ -n "$_resolved_root" ] \
  && [ -f "${_resolved_root}/skills/regulatory-trace/assets/obligations-catalogue.yaml" ]; then
  CATALOGUE="${_resolved_root}/skills/regulatory-trace/assets/obligations-catalogue.yaml"
else
  # The catalogue ships beside this script in both the sge repo and the installed
  # plugin, so sibling resolution works with no environment cooperation at all.
  CATALOGUE="${SCRIPT_DIR}/obligations-catalogue.yaml"
fi

# --- locate artefacts (degrade gracefully) ------------------------------------------------
CAP_MODEL="$(git -C "$ROOT" ls-files \
  '*capability-model.yaml' '.claude/product-context/capability-model.yaml' 2>/dev/null | head -1 || true)"
SPEC_FILES="$(git -C "$ROOT" ls-files 'docs/specs/*.md' 'docs/features/*.md' 2>/dev/null || true)"

emit() { printf '%s\n' "$1"; }

# --- 1. enumerate regulated capabilities --------------------------------------------------
# A capability is regulated when its block (in the capability model or the
# regulatory-trace.yaml index) carries `regulated: true`.
regulated_caps=""
if [ -n "${CAP_MODEL:-}" ] && [ -f "${ROOT}/${CAP_MODEL}" ]; then
  # crude block scan: id: CAP-xxx ... regulated: true (within the same capability stanza)
  regulated_caps="$(awk '
    /id:[[:space:]]*CAP-/ { cap=$0; sub(/.*id:[[:space:]]*/,"",cap); sub(/[[:space:]].*/,"",cap) }
    /regulated:[[:space:]]*true/ { if (cap!="") print cap }
  ' "${ROOT}/${CAP_MODEL}" | sort -u || true)"
fi
# also honour regulated flags declared in the index
INDEX="$(git -C "$ROOT" ls-files '*regulatory-trace.yaml' 2>/dev/null | head -1 || true)"
if [ -n "${INDEX:-}" ] && [ -f "${ROOT}/${INDEX}" ]; then
  idx_caps="$(awk '
    /id:[[:space:]]*CAP-/ { cap=$0; sub(/.*id:[[:space:]]*/,"",cap); sub(/[[:space:]].*/,"",cap) }
    /regulated:[[:space:]]*true/ { if (cap!="") print cap }
  ' "${ROOT}/${INDEX}" | sort -u || true)"
  regulated_caps="$(printf '%s\n%s\n' "$regulated_caps" "$idx_caps" | sed '/^$/d' | sort -u)"
fi

# --- 2. valid (non-retired) catalogue ids -------------------------------------------------
valid_ids=""; retired_ids=""; catalogue_missing=false; catalogue_unusable=false
if [ ! -f "$CATALOGUE" ]; then
  catalogue_missing=true
fi
if [ -f "$CATALOGUE" ]; then
  # ids appear as `- id: X`; retired ids live under the top-level `retired:` key.
  valid_ids="$(awk '/^retired:/{r=1} /^[a-z_]+:/{if($0!~"^retired:")r=0}
                    /-[[:space:]]*id:[[:space:]]*/{ if(!r){ s=$0; sub(/.*id:[[:space:]]*/,"",s); sub(/[[:space:]].*/,"",s); print s } }' "$CATALOGUE" | sort -u)"
  retired_ids="$(awk '/^retired:/{r=1;next} r&&/-[[:space:]]*id:[[:space:]]*/{ s=$0; sub(/.*id:[[:space:]]*/,"",s); sub(/[[:space:]].*/,"",s); print s }' "$CATALOGUE" | sort -u)"
  # A catalogue that exists but yields no ids (empty, unreadable, or a format the
  # parser no longer matches) must be as loud as a missing one — otherwise RT-2/RT-3
  # silently skip via their [ -n ] guards: the same false-PASS class as #720.
  if [ -z "$valid_ids" ] && [ -z "$retired_ids" ]; then
    catalogue_unusable=true
  fi
fi

# --- 3. walk specs ------------------------------------------------------------------------
high=0; med=0; findings_json=""
# Findings are emitted as JSON built by interpolation — escape backslashes and
# double-quotes so filesystem paths (e.g. Windows backslash paths) can never
# corrupt the audit evidence, especially on the fail path itself.
json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
add_finding() { # artefact severity check message
  [ "$2" = high ] && high=$((high+1)) || med=$((med+1))
  findings_json="${findings_json}{\"artefact\":\"$(json_esc "$1")\",\"severity\":\"$2\",\"check\":\"$3\",\"finding\":\"$(json_esc "$4")\"},"
}

# Fail-open-visible: without a usable catalogue, RT-2 (retired-reference) and RT-3
# (valid-vocabulary) cannot run — that is a HIGH finding, never a silent skip.
if [ "$catalogue_missing" = true ]; then
  add_finding "$CATALOGUE" high "convention-unknown" "obligations catalogue not found at ${CATALOGUE} — RT-2/RT-3 cannot run; pass \$1 or set CLAUDE_PLUGIN_ROOT to the sge plugin root"
elif [ "$catalogue_unusable" = true ]; then
  add_finding "$CATALOGUE" high "convention-unknown" "obligations catalogue at ${CATALOGUE} yielded no obligation ids (empty, unreadable, or unparsable) — RT-2/RT-3 cannot run"
fi

spec_count=0; mapped_count=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  spec_count=$((spec_count+1))
  path="${ROOT}/${f}"
  cap="$(grep -aoE 'capability:[[:space:]]*CAP-[A-Za-z0-9-]+' "$path" 2>/dev/null | head -1 | sed 's/.*CAP-/CAP-/' || true)"
  has_block="$(grep -aqE '^[[:space:]]*regulatory:' "$path" && echo yes || echo no)"
  # coverage gap: regulated capability but no regulatory block
  if printf '%s\n' "$regulated_caps" | grep -qx "${cap:-__none__}"; then
    if [ "$has_block" = no ]; then
      add_finding "$f" high "C12-coverage" "spec under regulated capability ${cap} has no regulatory mapping"
    else
      mapped_count=$((mapped_count+1))
    fi
  fi
  # retired-reference gap: any cited id that is retired
  if [ "$has_block" = yes ] && [ -n "$retired_ids" ]; then
    while IFS= read -r rid; do
      [ -z "$rid" ] && continue
      if grep -aqE "id:[[:space:]]*${rid}([[:space:]]|$)" "$path"; then
        add_finding "$f" high "C12-retired" "mapping cites retired obligation ${rid}"
      fi
    done <<< "$retired_ids"
  fi
  # unknown-id gap: a cited fca/framework id not in the catalogue at all
  if [ "$has_block" = yes ] && [ -n "$valid_ids" ]; then
    cited="$(grep -aoE 'id:[[:space:]]*[A-Z][A-Za-z0-9.:_-]+' "$path" | sed 's/.*id:[[:space:]]*//' | sort -u || true)"
    while IFS= read -r cid; do
      [ -z "$cid" ] && continue
      case "$cid" in CAP-*|SPEC-*|SGE-*|AI-*) continue;; esac   # not obligation ids
      if ! printf '%s\n' "$valid_ids" | grep -qx "$cid" && ! printf '%s\n' "$retired_ids" | grep -qx "$cid"; then
        add_finding "$f" medium "C12-unknown-id" "mapping cites id ${cid} absent from the catalogue"
      fi
    done <<< "$cited"
  fi
done <<< "$SPEC_FILES"

reg_cap_count="$(printf '%s\n' "$regulated_caps" | sed '/^$/d' | wc -l | tr -d ' ')"
applicable=true
[ "$reg_cap_count" = 0 ] && applicable=false

findings_json="[${findings_json%,}]"
# C12 passes when no high-severity gaps and at least one regulated cap exists (else N/A).
status=pass; [ "$high" -gt 0 ] && status=fail
[ "$applicable" = false ] && status=na
# A missing or unusable catalogue is a harness-visibility failure regardless of
# applicability — never report pass/na when RT-2/RT-3 could not run.
if [ "$catalogue_missing" = true ] || [ "$catalogue_unusable" = true ]; then
  status=fail
fi

emit "{
  \"check\": \"C12\",
  \"name\": \"Regulatory traceability\",
  \"layer\": \"regulatory\",
  \"sha\": \"${SHA}\",
  \"applicable\": ${applicable},
  \"status\": \"${status}\",
  \"specsScanned\": ${spec_count},
  \"regulatedCapabilities\": ${reg_cap_count},
  \"mappedSpecs\": ${mapped_count},
  \"high\": ${high},
  \"medium\": ${med},
  \"findings\": ${findings_json}
}"

[ "$high" -gt 0 ] && exit 1 || exit 0
