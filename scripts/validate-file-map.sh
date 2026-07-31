#!/usr/bin/env bash
# validate-file-map.sh — validate a decompose-issue file map against the real tree.
#
# Issue #1271: when /sgd:decompose-issue emits a child's file map (the `Owns:`
# footprint), the paths are not checked against the actual repository. In the
# 2026-07-16 swarm, issue #1236's map named `skills/lib/forgejo-adapter.sh` and
# `skills/**/with-repo-cwd.sh` — but `skills/lib/` does not exist and the
# resolver lives at `scripts/with-repo-cwd.sh`. The Lean Agent Contract tells
# lanes to orient ONLY from the file map (capped recon, no open-ended search),
# so a phantom path sends a lane hunting for files that aren't there. A wrong
# map is worse than none.
#
# This helper is the single mechanical check decompose-issue runs over each
# path it is about to emit. It classifies every entry against `git ls-files`:
#
#   - a concrete path that EXISTS            → emitted as-is (existing surface)
#   - a concrete path that does NOT exist    → the child must be creating it;
#                                              emitted with a "(new)" marker so
#                                              the lane does not hunt for it,
#                                              UNLESS the caller declared it an
#                                              existing surface (--existing),
#                                              in which case it is FLAGGED as a
#                                              phantom — corrected or dropped,
#                                              never emitted silently.
#   - a glob that expands to ≥1 match        → OK (existing surface)
#   - a glob that expands to 0 matches       → FLAGGED (matches nothing)
#
# A path is treated as a glob when it contains a glob metacharacter (* ? [ or a
# `**` segment); otherwise it is a concrete path.
#
# Usage (executed):
#   scripts/validate-file-map.sh check <path> [<path>...]
#       Classify each path. Prints one annotated line per path on stdout:
#         ok      <path>            — concrete path exists, or glob matched ≥1
#         new     <path> (new)      — concrete path absent; child will create it
#         flag    <path>  <reason>  — phantom existing path / glob matched nothing
#       Exit 0 if every path is `ok` or `new`; exit 1 if ANY path is flagged, so
#       a caller can gate on `if scripts/validate-file-map.sh check ...`.
#
#   scripts/validate-file-map.sh check --existing <path> [<path>...]
#       As above, but every concrete path is asserted to be an EXISTING surface:
#       an absent concrete path is `flag`ged (phantom) rather than marked new.
#
#   scripts/validate-file-map.sh owns < body-file
#       Read an issue-body `Owns:` line from stdin, split it on commas, and run
#       `check` over each path. `(shell)` / `(shell only)` qualifiers and
#       surrounding whitespace are stripped. Convenience wrapper for the common
#       case of validating a child body's footprint.
#
# All classification is done with `git ls-files` (the tracked tree), so it works
# identically in a worktree and is not fooled by untracked scratch files.
#
# See skills/decompose-issue/SKILL.md Phase 3c / Phase 5 for how the map is
# built and where this check is wired in.
set -uo pipefail

usage() {
  sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Is $1 a glob pattern (contains an unescaped glob metacharacter)?
is_glob() {
  case "$1" in
    *'*'* | *'?'* | *'['* ) return 0 ;;
    * ) return 1 ;;
  esac
}

# Cache the tracked file list once — one `git ls-files` for the whole run.
# NOTE: match with awk, never `grep -q`. Under `set -o pipefail`, `grep -q`
# closes the pipe on its first match and SIGPIPEs the upstream `printf`, so the
# pipeline returns 141 (a false "no match"). awk consumes the whole stream and
# exits cleanly, so pipefail sees rc 0.
TRACKED_LOADED=0
TRACKED=""
load_tracked() {
  [ "$TRACKED_LOADED" -eq 1 ] && return 0
  TRACKED="$(git ls-files 2>/dev/null)"
  TRACKED_LOADED=1
}

# Does a concrete path exist in the tracked tree? (exact whole-line match)
concrete_exists() {
  load_tracked
  printf '%s\n' "$TRACKED" | awk -v p="$1" '$0==p{f=1} END{exit !f}'
}

# How many tracked files does a glob match? Translate the glob to an anchored
# regex: `**` → any depth, `*` → any run without `/`, `?` → one non-`/` char.
glob_match_count() {
  load_tracked
  local pat="$1" rx
  # Translate the glob to an ERE. Literal `.` becomes the bracket class `[.]`
  # (not `\.`) so awk does not warn "unknown escape sequence"; the remaining
  # regex metachars a path can contain are escaped with a backslash. `**` →
  # any depth, `*` → any run without `/`, `?` → one non-`/` char.
  rx="$(printf '%s' "$pat" | sed \
    -e 's/[^A-Za-z0-9_./?*-]/\\&/g' \
    -e 's#\.#[.]#g' \
    -e 's#\*\*/\?#\x01#g' \
    -e 's#\*#[^/]*#g' \
    -e 's#?#[^/]#g' \
    -e 's#\x01#.*#g')"
  printf '%s\n' "$TRACKED" | awk -v rx="^($rx)\$" '$0 ~ rx{n++} END{print n+0}'
}

cmd_check() {
  local assert_existing=0
  if [ "${1:-}" = "--existing" ]; then
    assert_existing=1
    shift
  fi
  [ "$#" -ge 1 ] || { echo "validate-file-map: check needs ≥1 path" >&2; return 2; }

  local flagged=0 p
  for p in "$@"; do
    # Trim surrounding whitespace and a trailing "(shell)"/"(shell only)" note.
    p="$(printf '%s' "$p" | sed -e 's/[[:space:]]*([^)]*)[[:space:]]*$//' \
                                -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$p" ] || continue

    if is_glob "$p"; then
      if [ "$(glob_match_count "$p")" -ge 1 ]; then
        printf 'ok\t%s\n' "$p"
      else
        printf 'flag\t%s\tglob matches no tracked file\n' "$p"
        flagged=1
      fi
    elif concrete_exists "$p"; then
      printf 'ok\t%s\n' "$p"
    elif [ "$assert_existing" -eq 1 ]; then
      printf 'flag\t%s\tdeclared existing but matches nothing in the tree\n' "$p"
      flagged=1
    else
      printf 'new\t%s (new)\n' "$p"
    fi
  done

  [ "$flagged" -eq 0 ]
}

cmd_owns() {
  local line owns
  line="$(cat)"
  # Take the value after the first `Owns:` (case-insensitive); if the input is
  # already a bare comma list, use it whole.
  owns="$(printf '%s\n' "$line" | grep -iE '^[[:space:]]*Owns:' | head -1 | sed -E 's/^[[:space:]]*[Oo]wns:[[:space:]]*//')"
  [ -n "$owns" ] || owns="$line"

  local -a paths=()
  local IFS=','
  read -ra paths <<<"$owns"
  cmd_check "${paths[@]}"
}

case "${1:-}" in
  check) shift; cmd_check "$@" ;;
  owns)  shift; cmd_owns ;;
  -h | --help | help | "") usage ;;
  *) echo "validate-file-map: unknown command '$1' (want: check | owns)" >&2; exit 2 ;;
esac
