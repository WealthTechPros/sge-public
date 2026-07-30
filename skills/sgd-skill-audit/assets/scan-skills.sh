#!/usr/bin/env bash
# scan-skills.sh — the mechanical skill-quality checks (SQ-0, SQ-3, SQ-4, SQ-5).
# ---------------------------------------------------------------------------------------
# Single source of truth for the structural half of /sgd:sgd-skill-audit (and the
# skill-quality dimension sgd-align delegates here). Extracted from SKILL.md prose per
# issue #843 (parent #737) so these checks are script-anchored, deterministic, and
# trendable — same contract family as the C12 asset (check-regulatory-trace.sh):
# read-only, JSON on stdout, and exits:
#   0 = no failing checks      1 = one or more failing checks      2 = harness error
#
# Checks (SQ-1 Executability and SQ-2 Cost-Awareness stay model-judged in SKILL.md —
# they need semantic reading, not greps):
#   SQ-0 Frontmatter Integrity (high) — SKILL.md opens with a CLOSED `---` YAML block
#        whose `description:` is non-empty after stripping quotes/comments. Missing or
#        empty frontmatter breaks auto-invocation: the model never sees the skill.
#        Mirrors .github/scripts/skills-ci-lint.sh check 2 so repo CI and fleet audits
#        agree on what "valid frontmatter" means.
#   SQ-3 Scope Clarity (medium)       — both `## Role` and `## Out of scope` headers.
#   SQ-4 UNTRUSTED DATA (high)        — a skill that accepts untrusted input
#        ($ARGUMENTS, or external reads: WebFetch/WebSearch/curl/wget/gh api|pr|issue)
#        must contain an `UNTRUSTED DATA` annotation. No untrusted input -> na.
#   SQ-5 Tool Sequencing (low)        — >2 distinct tool-name mentions requires
#        sequencing language (Phase N / Step N / "Tool sequencing" / first…then).
#        <=2 tools -> na.
#
# Usage: scan-skills.sh [skills-dir | single-skill-dir] [--trend <file>]
#   arg 1 (optional) — a directory of skills (each subdir holding a SKILL.md) or a
#        single skill directory (itself holding a SKILL.md). Defaults to <repo>/skills.
#        UNTRUSTED DATA guard: paths containing ".." are rejected (exit 2) — a skill
#        name passed as an argument could attempt path traversal.
#   --trend <file> — additionally APPEND one compact JSONL summary row (date, sha,
#        counts) to <file>, so repeated fleet sweeps build a skill-quality trend
#        (mirrors sgd-align's docs/sgd/drift-trend.jsonl convention).
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
DATE_UTC="$(date -u +%Y-%m-%d)"
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TARGET=""
TREND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --trend)
      TREND="${2:-}"
      if [ -z "$TREND" ]; then echo "scan-skills.sh: --trend requires a file path" >&2; exit 2; fi
      shift 2 ;;
    --trend=*) TREND="${1#--trend=}"; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    --*) echo "scan-skills.sh: unknown option $1" >&2; exit 2 ;;
    *)
      if [ -n "$TARGET" ]; then echo "scan-skills.sh: unexpected extra argument $1" >&2; exit 2; fi
      TARGET="$1"; shift ;;
  esac
done

# UNTRUSTED DATA guard — arguments may come from a user-supplied skill name.
# Each path is checked on its own: concatenating them could false-match (a TARGET
# ending in '.' plus a TREND starting with '.' is not traversal).
for p in "$TARGET" "$TREND"; do
  case "$p" in
    *..*) echo "scan-skills.sh: path containing '..' rejected (traversal guard)" >&2; exit 2 ;;
  esac
done

[ -z "$TARGET" ] && TARGET="${ROOT}/skills"
if [ ! -d "$TARGET" ]; then
  echo "scan-skills.sh: target directory not found: $TARGET" >&2; exit 2
fi

# Resolve the SKILL.md set: single-skill mode when the target itself holds one.
SKILL_FILES=""
if [ -f "$TARGET/SKILL.md" ]; then
  SKILL_FILES="$TARGET/SKILL.md"
else
  # `|| true`: under `set -euo pipefail` a find traversal error (permission-denied
  # subdir, dangling symlink) would otherwise abort the script with no JSON and an
  # undefined exit code, breaking the 0/1/2 contract.
  SKILL_FILES="$(find "$TARGET" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | sort || true)"
fi
if [ -z "$SKILL_FILES" ]; then
  echo "scan-skills.sh: no SKILL.md found under $TARGET" >&2; exit 2
fi

json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

results_json=""; findings_json=""
scanned=0; failing_skills=0
sq0_fail=0; sq3_fail=0; sq4_fail=0; sq5_fail=0

add_finding() { # skill id severity message
  findings_json="${findings_json}{\"skill\":\"$(json_esc "$1")\",\"id\":\"$2\",\"severity\":\"$3\",\"finding\":\"$(json_esc "$4")\"},"
}

# --- SQ-0: closed frontmatter block with a non-empty description -------------------------
# awk exit codes: 0 = ok, 1 = closed but description empty/absent, 2 = never closed,
# 3 = does not start with ---. CR-stripped so CRLF and LF checkouts behave identically.
# NOTE: awk's `exit N` in a main rule still runs END, and an `exit` in END overrides
# the earlier status — so the no-frontmatter case sets a flag and END alone decides.
check_sq0() { # $1 = file; echoes nothing, returns the awk code
  awk '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") { nofm = 1; exit } next }
    /^---[[:space:]]*$/ { closed = 1; exit }
    /^description:/ && !seen {
      seen = 1
      v = $0
      sub(/^description:[[:space:]]*/, "", v)
      sub(/^#.*$/, "", v)
      sub(/[[:space:]]#.*$/, "", v)
      gsub(/["'\'']/, "", v)
      if (v ~ /[^[:space:]]/) found = 1
    }
    END { if (nofm) exit 3; if (!closed) exit 2; exit(found ? 0 : 1) }
  ' "$1"
}

while IFS= read -r f; do
  [ -z "$f" ] && continue
  skill="$(basename "$(dirname "$f")")"
  scanned=$((scanned+1))
  skill_failed=false

  # SQ-0 — frontmatter integrity
  set +e; check_sq0 "$f"; sq0_code=$?; set -e
  sq0=pass
  case "$sq0_code" in
    0) : ;;
    3) sq0=fail; add_finding "$skill" SQ-0 high "SKILL.md does not start with a --- YAML frontmatter block — auto-invocation is broken" ;;
    2) sq0=fail; add_finding "$skill" SQ-0 high "frontmatter block is never closed by a second ---" ;;
    *) sq0=fail; add_finding "$skill" SQ-0 high "frontmatter has no non-empty description: — the model cannot decide when to invoke this skill" ;;
  esac

  # SQ-3 — Role + Out of scope headers (both case-insensitive: one casing policy
  # for the whole check)
  sq3=pass
  has_role=$(grep -aicE '^##[[:space:]]+Role([[:space:]]|$)' "$f" || true)
  has_scope=$(grep -aicE '^##[[:space:]]+Out of scope([[:space:]]|$)' "$f" || true)
  if [ "${has_role:-0}" -eq 0 ] || [ "${has_scope:-0}" -eq 0 ]; then
    sq3=fail
    missing=""
    [ "${has_role:-0}" -eq 0 ] && missing="## Role"
    [ "${has_scope:-0}" -eq 0 ] && missing="${missing:+$missing and }## Out of scope"
    add_finding "$skill" SQ-3 medium "missing ${missing} header(s)"
  fi

  # SQ-4 — UNTRUSTED DATA annotation when the skill accepts untrusted input
  sq4=na
  if grep -aq '\$ARGUMENTS' "$f" \
     || grep -aqE 'WebFetch|WebSearch|curl[[:space:]]|wget[[:space:]]|gh (api|pr|issue)[[:space:]]' "$f"; then
    if grep -aq 'UNTRUSTED DATA' "$f"; then sq4=pass; else
      sq4=fail
      add_finding "$skill" SQ-4 high "accepts untrusted input (\$ARGUMENTS or external reads) but has no UNTRUSTED DATA annotation (ZT-3 gap)"
    fi
  fi

  # SQ-5 — sequencing language when >2 distinct tool types are mentioned
  sq5=na
  tools=0
  for t in Bash Read Write Edit Grep Glob WebFetch WebSearch Agent Task AskUserQuestion NotebookEdit; do
    if grep -aqw "$t" "$f"; then tools=$((tools+1)); fi
  done
  if [ "$tools" -gt 2 ]; then
    if grep -aqiE '(^|[^a-z])phase[[:space:]]+[0-9]|(^|[^a-z])step[[:space:]]+[0-9]|tool[[:space:]-]sequencing|first[^.]*then' "$f"; then
      sq5=pass
    else
      sq5=fail
      add_finding "$skill" SQ-5 low "mentions ${tools} distinct tool types but no call-order guidance (Phase N / Step N / Tool sequencing / first…then)"
    fi
  fi

  [ "$sq0" = fail ] && { sq0_fail=$((sq0_fail+1)); skill_failed=true; }
  [ "$sq3" = fail ] && { sq3_fail=$((sq3_fail+1)); skill_failed=true; }
  [ "$sq4" = fail ] && { sq4_fail=$((sq4_fail+1)); skill_failed=true; }
  [ "$sq5" = fail ] && { sq5_fail=$((sq5_fail+1)); skill_failed=true; }
  [ "$skill_failed" = true ] && failing_skills=$((failing_skills+1))

  results_json="${results_json}{\"skill\":\"$(json_esc "$skill")\",\"SQ-0\":\"${sq0}\",\"SQ-3\":\"${sq3}\",\"SQ-4\":\"${sq4}\",\"SQ-5\":\"${sq5}\"},"
done <<< "$SKILL_FILES"

total_fail=$((sq0_fail + sq3_fail + sq4_fail + sq5_fail))
status=pass; [ "$total_fail" -gt 0 ] && status=fail
results_json="[${results_json%,}]"
findings_json="[${findings_json%,}]"

printf '%s\n' "{
  \"check\": \"SQ-scan\",
  \"name\": \"Skill quality mechanical checks (SQ-0, SQ-3, SQ-4, SQ-5)\",
  \"sha\": \"${SHA}\",
  \"date\": \"${DATE_UTC}\",
  \"status\": \"${status}\",
  \"skillsScanned\": ${scanned},
  \"skillsFailing\": ${failing_skills},
  \"fail\": ${total_fail},
  \"failByCheck\": { \"SQ-0\": ${sq0_fail}, \"SQ-3\": ${sq3_fail}, \"SQ-4\": ${sq4_fail}, \"SQ-5\": ${sq5_fail} },
  \"results\": ${results_json},
  \"findings\": ${findings_json}
}"

# --- trend row (append-only JSONL, one compact row per sweep) -----------------------------
if [ -n "$TREND" ]; then
  trend_dir="$(dirname "$TREND")"
  [ -d "$trend_dir" ] || mkdir -p "$trend_dir"
  printf '{"timestamp":"%s","date":"%s","sha":"%s","skillsScanned":%s,"skillsFailing":%s,"fail":%s,"sq0_fail":%s,"sq3_fail":%s,"sq4_fail":%s,"sq5_fail":%s}\n' \
    "$TS_UTC" "$DATE_UTC" "$SHA" "$scanned" "$failing_skills" "$total_fail" \
    "$sq0_fail" "$sq3_fail" "$sq4_fail" "$sq5_fail" >> "$TREND"
fi

[ "$total_fail" -gt 0 ] && exit 1 || exit 0
