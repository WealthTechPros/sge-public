#!/usr/bin/env bash
# read-enforcement-profile.sh [repo-root] — SPEC-128 (F-ENFORCE-PROFILE).
#
# Prints a repo's effective enforcement profile and its declared gate
# exceptions from <repo-root>/.sge/posture.yaml, tab-separated:
#
#   enforcement<TAB>onboarding|enforced
#   exception<TAB><gate><TAB><reason><TAB><approver><TAB><YYYY-MM-DD>   (0..n)
#
# An absent file or absent `enforcement:` key means `onboarding`. Anything
# else that is not exactly `onboarding` or `enforced` is an error: the reader
# fails closed with a named error on stderr and exit 1, and never falls back
# to `onboarding` on a typo. Expiry is reported, not evaluated; consumers
# compare it with today. Dependency-free bash (no yq/python/jq).
#
# Errors: no-such-repo-root, unreadable-posture, invalid-enforcement-value,
#         duplicate-key, malformed-exception, unsupported-enforcement-syntax,
#         unsupported-line-ending, unsupported-encoding.
#
# Hardening (sge#2860): a leading UTF-8 BOM is stripped; an exception field
# holding a control character (a TAB would shift the tab-separated output) or
# an impossible calendar date (2026-13-45, 9999-99-99, 2027-02-29) is
# malformed. FAIL CLOSED BY CLASS: this is a line-oriented subset of YAML, so
# every input it might misread is an error, never onboarding:
#   - any non-comment line that mentions `enforcement` and was not consumed as
#     the plain `enforcement:` / `enforcement_exceptions:` key or an exception
#     item (quoted/tagged/anchored/explicit keys, flow mappings, merge keys,
#     aliases, block scalars, even an inline comment that mentions it);
#   - a non-comment line holding both `"` and `\` (an escape could spell the
#     key, e.g. "enforc\x65ment");
#   - a CR that is not part of a CRLF line ending (CR-only files);
#   - a NUL byte anywhere (UTF-16/UTF-32 files).
# Only whole-line comments (first non-blank character `#`) are skipped.
#
# sge#2877: the keys are top-level (column 0); an indented or nested
# `enforcement:` is unsupported-enforcement-syntax, never the profile. A
# block-list item may sit at column 0 or be indented. A reason needs at least
# one ASCII letter or digit (a lone NBSP is empty). A dangling-symlink
# posture.yaml is unreadable-posture. Bytes are read in the C locale, so the
# vendored awk copy gives the same answer in any locale, under gawk or mawk.
set -uo pipefail
export LC_ALL=C

die() { printf 'read-enforcement-profile: %s: %s\n' "$1" "$2" >&2; exit 1; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

root="${1:-.}"
[ -d "$root" ] || die no-such-repo-root "$root"
file="$root/.sge/posture.yaml"

GATES=" commit-msg tdd-guard require-commit-trailer require-test-evidence branch-protection "
KEY_RE='^enforcement[[:space:]]*:(.*)$'
EXC_KEY_RE='^enforcement_exceptions[[:space:]]*:(.*)$'
ITEM_RE='^[[:space:]]*-[[:space:]]+"([^"|]*)\|([^"|]*)\|([^"|]*)\|([^"|]*)"[[:space:]]*(#.*)?$'
LOGIN_RE='^[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?$'
DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
COMMENT_RE='^[[:space:]]*#'

valid_date() { # YYYY-MM-DD already shape-checked -> 0 if a real calendar date
  local y=$((10#${1:0:4})) m=$((10#${1:5:2})) d=$((10#${1:8:2})) max
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] || return 1
  case "$m" in
    4|6|9|11) max=30 ;;
    2) if (( (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 )); then max=29; else max=28; fi ;;
    *) max=31 ;;
  esac
  [ "$d" -le "$max" ]
}

profile=""; seen_key=0; seen_exc=0; in_exc=0; n=0
exceptions=()

if [ -e "$file" ] || [ -L "$file" ]; then
  [ -f "$file" ] && [ -r "$file" ] || die unreadable-posture "$file"
  [ "$(wc -c < "$file")" -eq "$(tr -d '\000' < "$file" | wc -c)" ] \
    || die unsupported-encoding "$file holds NUL bytes (UTF-16/UTF-32?); save it as UTF-8"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1)); line="${line%$'\r'}"
    [ "$n" -eq 1 ] && line="${line#$'\xef\xbb\xbf'}"
    [[ "$line" == *$'\r'* ]] && die unsupported-line-ending "line $n: a CR that is not part of CRLF (CR-only line endings?); use LF or CRLF"
    if [ "$in_exc" -eq 1 ]; then
      [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
      if [[ "$line" =~ ^[[:space:]] || "$line" == -* ]]; then
        [[ "$line" =~ $ITEM_RE ]] || die malformed-exception "line $n: want - \"<gate> | <reason> | <approver> | <YYYY-MM-DD>\""
        [[ "${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}" == *[[:cntrl:]]* ]] \
          && die malformed-exception "line $n: an exception field holds a control character (e.g. a TAB)"
        gate="$(trim "${BASH_REMATCH[1]}")"; reason="$(trim "${BASH_REMATCH[2]}")"
        approver="$(trim "${BASH_REMATCH[3]}")"; expiry="$(trim "${BASH_REMATCH[4]}")"
        [[ "$GATES" == *" $gate "* ]] || die malformed-exception "line $n: unknown gate '$gate' (one of:$GATES)"
        [[ "$reason" =~ [A-Za-z0-9] ]] || die malformed-exception "line $n: empty reason (it needs at least one letter or digit)"
        [[ "$approver" =~ $LOGIN_RE ]] || die malformed-exception "line $n: approver '$approver' is not a GitHub login"
        [[ "$expiry" =~ $DATE_RE ]] || die malformed-exception "line $n: expiry '$expiry' is not YYYY-MM-DD"
        valid_date "$expiry" || die malformed-exception "line $n: expiry '$expiry' is not a calendar date"
        exceptions+=("exception	$gate	$reason	$approver	$expiry")
        continue
      fi
      in_exc=0
    fi
    if [[ "$line" =~ $KEY_RE ]]; then
      [ "$seen_key" -eq 0 ] || die duplicate-key "line $n: enforcement declared twice"
      seen_key=1
      v="$(trim "${BASH_REMATCH[1]%%#*}")"
      [[ "$v" =~ ^\'(.*)\'$ || "$v" =~ ^\"(.*)\"$ ]] && v="${BASH_REMATCH[1]}"
      case "$v" in
        onboarding|enforced) profile="$v" ;;
        *) die invalid-enforcement-value "line $n: '$v' (expected onboarding|enforced)" ;;
      esac
    elif [[ "$line" =~ $EXC_KEY_RE ]]; then
      [ "$seen_exc" -eq 0 ] || die duplicate-key "line $n: enforcement_exceptions declared twice"
      seen_exc=1
      [ -z "$(trim "${BASH_REMATCH[1]%%#*}")" ] || die malformed-exception "line $n: use a block list, one '- \"...\"' entry per line"
      in_exc=1
    elif ! [[ "$line" =~ $COMMENT_RE ]] && [[ "$line" == *enforcement* || ( "$line" == *'"'* && "$line" == *'\'* ) ]]; then
      die unsupported-enforcement-syntax "line $n: only a plain block key 'enforcement: <value>' and the enforcement_exceptions block list may mention enforcement (no quoted, tagged, anchored or flow-mapping key, no escapes, no mention in a value or inline comment)"
    fi
  done < "$file"
fi

printf 'enforcement\t%s\n' "${profile:-onboarding}"
[ "${#exceptions[@]}" -eq 0 ] || printf '%s\n' "${exceptions[@]}"
