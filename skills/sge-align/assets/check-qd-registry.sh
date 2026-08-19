#!/usr/bin/env bash
# check-qd-registry.sh — the mechanical C8 "Stakeholder Questions" structural/
# referential-integrity drift check.
# ---------------------------------------------------------------------------
# Extends C8 beyond its existing open-past-threshold staleness check (issue
# #2313, split from #2220, decomposed from #2206). Mirrors the C11
# check-agent-security.sh script contract exactly: read-only, emits one JSON
# block on stdout, and exits:
#   0 = no failing defect      1 = one or more failing defects      2 = harness error
#
# Parses docs/sge/questions.md against the schema sge-init Step 6 documents:
# one `### QD-NN` heading per entry, with `- **Field:** value` sub-lines for
# Question / Stakeholder / Raised / Status, and — on Status: Closed — Decision
# / Decided by / Decided.
#
# FOUR defect classes, each independently checkable, none requiring judgement:
#   D1 Duplicate ID        — the same QD-NN heading appears more than once
#   D2 Closed with no decision — Status: Closed but Decision/Decided by/Decided missing
#   D3 Silent revert        — a Closed QD's Decision text differs from its
#                             recorded text at a prior commit (bounded lookback)
#   D4 Referential integrity — a `questions: [QD-NN, ...]` ref in any spec's
#                             front-matter that does not resolve to a real
#                             registry entry, OR a spec still listing a QD the
#                             registry already marks Closed (sge-init Step 6's
#                             own closure rule: remove the ref on closure)
#
# Usage: check-qd-registry.sh [repo-root] [registry-path]
#   $1 (optional) — repo root to audit. Defaults to the enclosing git toplevel (or `.`).
#   $2 (optional) — registry path relative to repo root. Defaults to docs/sge/questions.md.
#   A non-directory $1, or a missing registry file, is reported as N/A (not a harness
#   error) — "no registry yet" is not a defect, same doctrine as every other advisory
#   check's "not adopted yet is never scored as a fail".
set -uo pipefail

if [ -n "${1:-}" ]; then
  if [ ! -d "$1" ]; then
    echo "check-qd-registry.sh: repo root not found: $1" >&2
    exit 2
  fi
  ROOT="$(cd "$1" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
fi
REGISTRY_REL="${2:-docs/sge/questions.md}"
REGISTRY="${ROOT}/${REGISTRY_REL}"
SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

# Escaping boundary: json_esc is applied once, inside add_finding, to the WHOLE composed
# finding string (which already interpolates any raw QD id / decision text / spec path) —
# it is not applied at each field's own interpolation site. Safe today because every
# finding is built via add_finding; a future finding built by concatenating fields
# directly into findings_json (bypassing add_finding) would reopen a JSON-injection risk.
json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

if [ ! -f "$REGISTRY" ]; then
  printf '%s\n' "{
  \"check\": \"C8-QD-REGISTRY\",
  \"name\": \"QD Registry structural/referential integrity\",
  \"sha\": \"${SHA}\",
  \"applicable\": false,
  \"status\": \"na\",
  \"reason\": \"no registry at ${REGISTRY_REL} — not yet adopted, not a defect\",
  \"findings\": []
}"
  exit 0
fi

fail_n=0
findings_json=""
add_finding() { # severity check-key finding
  findings_json="${findings_json}{\"severity\":\"$1\",\"check\":\"$2\",\"finding\":\"$(json_esc "$3")\"},"
  fail_n=$((fail_n+1))
}

# --- Parse the registry into per-QD records ------------------------------------------------
# One QD per `### QD-NN` heading; sub-fields are `- **Field:** value` lines until the
# next heading (### or ##) or EOF. IDs, statuses, and decision text collected as
# parallel arrays keyed by array index (bash 3.2-compatible — no associative arrays).
ids=(); statuses=(); decisions=(); decided_bys=(); decideds=()
current_id=""; current_status=""; current_decision=""; current_decided_by=""; current_decided=""
have_entry=false

flush_entry() {
  if [ "$have_entry" = true ]; then
    ids+=("$current_id")
    statuses+=("$current_status")
    decisions+=("$current_decision")
    decided_bys+=("$current_decided_by")
    decideds+=("$current_decided")
  fi
}

while IFS= read -r line; do
  if [[ "$line" =~ ^###[[:space:]]+(QD-[0-9]+) ]]; then
    flush_entry
    current_id="${BASH_REMATCH[1]}"
    current_status=""; current_decision=""; current_decided_by=""; current_decided=""
    have_entry=true
    continue
  fi
  if [[ "$line" =~ ^##[[:space:]] ]] && [[ ! "$line" =~ ^###[[:space:]] ]]; then
    flush_entry
    have_entry=false
    continue
  fi
  if [ "$have_entry" = true ]; then
    if [[ "$line" =~ \*\*Status:\*\*[[:space:]]*(Open|Closed) ]]; then
      current_status="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ \*\*Decision:\*\*[[:space:]]*(.*)$ ]]; then
      current_decision="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ \*\*Decided[[:space:]]by:\*\*[[:space:]]*(.*)$ ]]; then
      current_decided_by="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ \*\*Decided:\*\*[[:space:]]*(.*)$ ]]; then
      current_decided="${BASH_REMATCH[1]}"
    fi
  fi
done < "$REGISTRY"
flush_entry

qd_count=${#ids[@]}

# --- D1: Duplicate ID -----------------------------------------------------------------------
if [ "$qd_count" -gt 0 ]; then
  seen=""
  for id in "${ids[@]}"; do
    case " $seen " in
      *" $id "*)
        add_finding high "C8-D1" "duplicate QD id in registry: ${id} appears more than once"
        ;;
    esac
    seen="$seen $id"
  done
fi

# --- D2: Closed with no decision recorded ----------------------------------------------------
i=0
while [ "$i" -lt "$qd_count" ]; do
  id="${ids[$i]}"; status="${statuses[$i]}"; decision="${decisions[$i]}"
  decided_by="${decided_bys[$i]}"; decided="${decideds[$i]}"
  if [ "$status" = "Closed" ]; then
    missing=""
    [ -z "$decision" ] && missing="${missing}Decision, "
    [ -z "$decided_by" ] && missing="${missing}Decided by, "
    [ -z "$decided" ] && missing="${missing}Decided, "
    if [ -n "$missing" ]; then
      add_finding high "C8-D2" "${id} is Status: Closed but missing: ${missing%, }"
    fi
  fi
  i=$((i+1))
done

# --- D3: Silent revert — closed decision text changed from a prior commit -------------------
# Walks EVERY commit that touched the registry file (git log --follow, oldest to
# newest reachable from HEAD, no fixed offset) so detection stays correct no matter
# how many unrelated commits have landed since a QD's closure — a fixed lookback
# window (e.g. HEAD~20) would go permanently blind to a revert once enough commits
# accumulate after it, which defeats the point of a sweep-on-every-align check.
# For each Closed QD in the current registry, find its OWN most recent prior
# appearance as Closed (the first earlier commit, scanning backward, where that QD
# id was already Closed) and compare decision text against that specific commit —
# not an arbitrary shared snapshot. A QD absent/Open at every prior commit is a new
# closure, not a revert.
REGISTRY_HISTORY="$(git -C "$ROOT" log --follow --format=%H -- "$REGISTRY_REL" 2>/dev/null || true)"
if [ -n "$REGISTRY_HISTORY" ]; then
  # Oldest-first walk order; drop the current HEAD commit itself (index 0 when reversed).
  PRIOR_COMMITS="$(printf '%s\n' "$REGISTRY_HISTORY" | tac | sed '$d')"
  i=0
  while [ "$i" -lt "$qd_count" ]; do
    id="${ids[$i]}"; status="${statuses[$i]}"; decision="${decisions[$i]}"
    if [ "$status" = "Closed" ] && [ -n "$decision" ]; then
      # Scan prior commits NEWEST-first so we compare against this QD's most
      # recent earlier Closed appearance, not its oldest (avoids false-flagging
      # a deliberate multi-step amendment as a single "revert").
      prior_decision=""
      for prior_ref in $(printf '%s\n' "$PRIOR_COMMITS" | tac); do
        prior_content="$(git -C "$ROOT" show "${prior_ref}:${REGISTRY_REL}" 2>/dev/null || true)"
        [ -n "$prior_content" ] || continue
        prior_status="$(printf '%s\n' "$prior_content" | awk -v qd="$id" '
          $0 ~ "^### "qd"([^0-9]|$)" { infield=1; next }
          infield && /^###[[:space:]]/ { infield=0 }
          infield && /^##[[:space:]]/ && !/^###/ { infield=0 }
          infield && /\*\*Status:\*\*/ {
            sub(/^.*\*\*Status:\*\*[[:space:]]*/, ""); sub(/[[:space:]]*$/, "");
            print; exit
          }
        ')"
        [ "$prior_status" = "Closed" ] || continue
        prior_decision="$(printf '%s\n' "$prior_content" | awk -v qd="$id" '
          $0 ~ "^### "qd"([^0-9]|$)" { infield=1; next }
          infield && /^###[[:space:]]/ { infield=0 }
          infield && /^##[[:space:]]/ && !/^###/ { infield=0 }
          infield && /\*\*Decision:\*\*/ {
            sub(/^.*\*\*Decision:\*\*[[:space:]]*/, "");
            print;
            exit
          }
        ')"
        break
      done
      if [ -n "$prior_decision" ] && [ "$prior_decision" != "$decision" ]; then
        add_finding high "C8-D3" "${id} decision text changed since its last-recorded closed state (was: '${prior_decision}', now: '${decision}') — closed decision text is immutable; open a new superseding QD instead"
      fi
    fi
    i=$((i+1))
  done
fi

# --- D4: Referential integrity against spec front-matter questions[] ------------------------
# Collect every QD-NN referenced by any spec's `questions: [...]` front-matter line, plus
# whether the registry currently marks that QD Closed.
# NOTE: only the inline flow-style form (questions: [QD-01, QD-04]) is detected — the
# convention sge-init Step 6 documents and every spec in this repo currently uses. A
# block-style YAML sequence (questions:\n  - QD-01) is not matched and would go
# unchecked; if that form is ever adopted, this regex needs widening.
spec_files="$(git -C "$ROOT" ls-files -- 'docs/features/*.md' 'docs/specs/*.md' 2>/dev/null | sort -u || true)"
if [ -n "$spec_files" ]; then
  while IFS= read -r sf; do
    [ -z "$sf" ] && continue
    refs_line="$(grep -aE '^\s*questions:\s*\[' "${ROOT}/${sf}" 2>/dev/null | head -1 || true)"
    [ -z "$refs_line" ] && continue
    refs="$(printf '%s' "$refs_line" | grep -oE 'QD-[0-9]+' || true)"
    [ -z "$refs" ] && continue
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      found=false; ref_status=""
      j=0
      while [ "$j" -lt "$qd_count" ]; do
        if [ "${ids[$j]}" = "$ref" ]; then
          found=true; ref_status="${statuses[$j]}"
          break
        fi
        j=$((j+1))
      done
      if [ "$found" = false ]; then
        add_finding medium "C8-D4" "${sf} cites ${ref} in questions[] but no such entry exists in ${REGISTRY_REL}"
      elif [ "$ref_status" = "Closed" ]; then
        add_finding medium "C8-D4" "${sf} still lists ${ref} in questions[] but the registry marks it Closed — remove the ref and fold the answer into the spec body (sge-init Step 6 closure rule)"
      fi
    done <<< "$refs"
  done <<< "$spec_files"
fi

# --- emit ------------------------------------------------------------------------------------
findings_json="[${findings_json%,}]"
applicable=true; status=pass
[ "$fail_n" -gt 0 ] && status=fail

printf '%s\n' "{
  \"check\": \"C8-QD-REGISTRY\",
  \"name\": \"QD Registry structural/referential integrity\",
  \"sha\": \"${SHA}\",
  \"registry\": \"${REGISTRY_REL}\",
  \"applicable\": ${applicable},
  \"status\": \"${status}\",
  \"qdCount\": ${qd_count},
  \"defectCount\": ${fail_n},
  \"findings\": ${findings_json}
}"

[ "$fail_n" -gt 0 ] && exit 1 || exit 0
