#!/usr/bin/env bash
# scan-staged-secrets.sh — value-aware secret scan of the STAGED ADDED lines
# (/sge:commit step 3, sge#3094). Exit 0 = clean, 1 = findings (stop and
# confirm), 2 = scan error (fail closed: treat exactly like findings).
# No flags, no skip switch. Diagnostics: file:line rule masked-prefix only.
set -uo pipefail
LC_ALL=C; export LC_ALL
[ "$#" -eq 0 ] || { echo "scan-staged-secrets: takes no arguments" >&2; exit 2; }

diff_out="$(git diff --staged --no-color --no-ext-diff --no-renames -U0 --diff-filter=ACMR 2>/dev/null)" \
  || { echo "scan-staged-secrets: git diff failed (not a git repo?) - fail closed" >&2; exit 2; }

shopt -u nocasematch
found=0
file="" ; lineno=0 ; inhunk=0

report() { # <rule> <value-or-empty>
  local v="$2" shown="(no value)"
  [ -n "$v" ] && shown="${v:0:4}***(len ${#v}, redacted)"
  printf 'SECRET-SCAN %s:%s rule=%s value=%s\n' "$file" "$lineno" "$1" "$shown" >&2
  found=1
}

is_test_path() {
  [[ "$1" =~ (^|/)(tests?|__tests__|spec|specs|fixtures?|__fixtures__|testdata)/ ]] \
    || [[ "$1" =~ \.(test|spec)\.[a-z0-9]+$ ]] || [[ "$1" =~ _test\.[a-z0-9]+$ ]] \
    || [[ "$(basename "$1")" =~ ^test_ ]]
}

# is_dummy <value>: built ONLY from dummy words / x-runs / short numbers.
is_dummy() {
  local v="${1,,}" w
  [[ "$v" =~ ^(x{4,}|\*{4,}|0{4,}|\.{3,}|-{3,})$ ]] && return 0
  for w in fixture test testing dummy example changeme change me placeholder redacted \
           fake mock sample token secret password key value todo tbd none null foo bar abc; do
    v="${v//$w/}"
  done
  [[ -z "$v" || "$v" =~ ^[-_.0-9]*$ ]]
}

KEYRE='([a-z0-9_.-]*(secret|token|passw(or)?d|passwd|pwd|api[_-]?key|apikey|private[_-]?key|credential|access[_-]?key|auth[_-]?key)[a-z0-9_.-]*)["'"'"'`]?[[:space:]]*(:=|=>|=|:)[[:space:]]*(.*)$'
VALRE='^["'"'"'`]?([^"'"'"'`[:space:],;]*)'

# keyword + (is|was|set to)/quote + value, no separator: 'the password is X', '-Password "X"'.
KEY2RE='(secret|token|passw(or)?d|pwd|api[_-]?key|private[_-]?key|credential)[[:space:]]+((is|was|equals?|set[[:space:]]+to)[[:space:]]+)?(["'"'"'`])?([^"'"'"'`[:space:],;]{8,})(.*)$'

# Quoted values keep leading/inner punctuation (",Val1d!"); unquoted values stop
# at , or ;. A typed assignment (password: str = "x", token: Final[str] = "x")
# yields BOTH the text after the separator and the value after the annotation's =.
VALQRE='^(["'"'"'`])([^"'"'"'`[:space:]]*)'
TYPERE='^[[:space:]]*[A-Za-z_][A-Za-z0-9_.]*(\[[^]]*\])?[[:space:]]*=[[:space:]]*(.*)$'
extract_vals() { # <text after separator> -> appends to global cands
  local t="$1" n=0
  while [ $n -lt 3 ]; do
    if [[ "$t" =~ $VALQRE ]]; then cands+=("${BASH_REMATCH[2]}")
    elif [[ "$t" =~ $VALRE ]]; then cands+=("${BASH_REMATCH[1]}"); fi
    [[ "$t" =~ $TYPERE ]] || break
    t="${BASH_REMATCH[2]}"; n=$((n+1))
  done
}

scan_line() { # <content>
  local cands l="$1" rest v distinct c i s tok before="$found"
  # R1 known credential shapes: never excepted, test path or not.
  [[ "$l" =~ gh[pousr]_[A-Za-z0-9]{36,} || "$l" =~ github_pat_[A-Za-z0-9_]{22,} ]] && report github-token "${BASH_REMATCH[0]}"
  [[ "$l" =~ (AKIA|ASIA)[A-Z0-9]{16} ]] && report aws-access-key "${BASH_REMATCH[0]}"
  [[ "$l" =~ AIza[0-9A-Za-z_-]{35} ]] && report gcp-api-key "${BASH_REMATCH[0]}"
  [[ "$l" =~ xox[bpars]-[A-Za-z0-9-]{10,} ]] && report slack-token "${BASH_REMATCH[0]}"
  [[ "$l" =~ (sk|rk|pk)_live_[A-Za-z0-9]{16,} || "$l" =~ (^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,} ]] && report stripe-or-api-key "${BASH_REMATCH[0]}"
  [[ "$l" =~ eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,} ]] && report jwt "${BASH_REMATCH[0]}"
  [[ "$l" =~ -----BEGIN\ [A-Z\ ]*PRIVATE\ KEY ]] && report private-key ""
  [[ "$l" =~ [Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+[A-Za-z0-9._~+/=-]{20,} ]] && report bearer-token "${BASH_REMATCH[0]}"
  [[ "$l" =~ [Bb][Aa][Ss][Ii][Cc][[:space:]]+[A-Za-z0-9+/=]{16,} ]] && report basic-auth "${BASH_REMATCH[0]}"
  [[ "$l" =~ ://[^/[:space:]:@\$\<\{]+:[^/[:space:]:@\$\<\{]{4,}@ ]] && report url-credentials "${BASH_REMATCH[0]}"
  # R2 key/value assignment with a real-looking value.
  shopt -s nocasematch; rest="$l"
  while [[ "$rest" =~ $KEYRE ]]; do
    rest="${BASH_REMATCH[5]}"
    cands=(); extract_vals "$rest"
    for v in "${cands[@]}"; do
      [[ ${#v} -ge 8 ]] || continue
      [[ "$v" =~ ^[\$\<\{%\[@] ]] && continue            # reference / placeholder
      [[ "$v" == *"("* || "$v" == *")"* ]] && continue   # call expression
      [[ "$v" =~ ^[0-9]+$ ]] && continue                 # plain number
      [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$ ]] && continue  # a.b.c reference
      if is_dummy "$v" && is_test_path "$file"; then continue; fi
      report credential-assignment "$v"
    done
  done
  rest="$l"
  while [[ "$rest" =~ $KEY2RE ]]; do
    v="${BASH_REMATCH[6]}"; rest="${BASH_REMATCH[7]}"
    [[ -n "${BASH_REMATCH[5]}" || ( -n "${BASH_REMATCH[4]}" && "$v" =~ [0-9] ) ]] || continue
    [[ "$v" =~ ^[\$\<\{%\[@] || "$v" == *"("* || "$v" =~ ^[0-9]+$ ]] && continue
    [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$ ]] && continue
    if is_dummy "$v" && is_test_path "$file"; then continue; fi
    report credential-assignment "$v"
  done
  shopt -u nocasematch
  [ "$found" -ne "$before" ] && return 0   # already reported on this line
  # R3 high-entropy credential-like strings (any context).
  s="$l"
  while [[ "$s" =~ ([A-Za-z0-9+/_=-]{32,}) ]]; do
    tok="${BASH_REMATCH[1]}"; s="${s#*"$tok"}"
    [[ "$tok" =~ ^sha[0-9]+- ]] && continue
    [[ "$tok" =~ [a-z] && "$tok" =~ [A-Z] && "$tok" =~ [0-9] ]] || continue
    declare -A seen=(); distinct=0
    for ((i=0;i<${#tok};i++)); do c="${tok:i:1}"; [[ -z "${seen[$c]:-}" ]] && { seen[$c]=1; distinct=$((distinct+1)); }; done
    unset seen
    [[ $distinct -ge 16 ]] && report high-entropy "$tok"
  done
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    "diff --git "*) inhunk=0; file="" ;;
    "+++ "*) if [ $inhunk -eq 0 ]; then
               file="${line#+++ }"; file="${file%%$'\t'*}"; file="${file#\"}"; file="${file%\"}"; file="${file#b/}"
             fi ;;
    "@@ "*) inhunk=1
            [[ "$line" =~ \+([0-9]+) ]] && lineno=$(( ${BASH_REMATCH[1]} - 1 )) || { echo "scan-staged-secrets: bad hunk header - fail closed" >&2; exit 2; } ;;
    "+"*) if [ $inhunk -eq 1 ]; then lineno=$((lineno+1)); scan_line "${line:1}"; fi ;;
  esac
done <<<"$diff_out"

if [ $found -ne 0 ]; then
  echo "SECRET-SCAN stop - findings above; confirm each with the user before committing." >&2
  exit 1
fi
exit 0
