#!/usr/bin/env bash
# resolve-sge-root.sh — portable plugin/repo-root resolver (portability audit
# docs/portability-audit.md §5 Slice A, issue #1567).
#
# Every skill that shells out to `${CLAUDE_PLUGIN_ROOT}/scripts/X` or
# `${CLAUDE_PLUGIN_ROOT}/scripts/X.mjs` needs SOME value for the root when
# CLAUDE_PLUGIN_ROOT is unset — which happens on any host that isn't running
# SGE as an installed Claude Code plugin (a bare checkout, CI, GitHub Copilot's
# coding agent, or a fork/worktree of this repo), AND, confirmed live, in a
# normal Claude Code session's own `!`bash ...`` skill-preload directives —
# CLAUDE_PLUGIN_ROOT is simply not populated in that execution context in
# some harness versions. The prior convention, `${CLAUDE_PLUGIN_ROOT:-.}`,
# silently resolves to whatever the CALLER's cwd happens to be — which is
# virtually never this repo's own scripts/ directory (it is almost always the
# TARGET repo being worked on), producing "No such file or directory" for a
# path that is real, just not under the caller's cwd. This is exactly what
# broke `/sge:sge-implement`'s issue preload (SKILL.md line 51 calling
# `${CLAUDE_PLUGIN_ROOT:-.}/scripts/issue-read.sh` from a target-repo
# checkout) and is the same bug at ~17 other call sites across the skill set.
#
# THE BOOTSTRAP PROBLEM this script exists to solve: an inline `!`bash ...``
# preload directive is NOT a script file — it has no BASH_SOURCE of its own
# to self-locate from, unlike a real .sh file invoked by path. So call sites
# cannot simply do `$(dirname "${BASH_SOURCE[0]}")` themselves; they need an
# INDEPENDENT way to find "the SGE plugin root" starting from nothing but the
# plugin's own identity. This script supplies that: when CLAUDE_PLUGIN_ROOT is
# unset, it searches the well-known Claude Code plugin install locations for
# a directory whose `.claude-plugin/plugin.json` declares `"name": "sge"`
# (this repo's own manifest identity) — deterministic, not a guess, and does
# not depend on the caller's cwd being anywhere in particular.
#
# Usage:
#   scripts/resolve-sge-root.sh
#       Print the resolved root on stdout. Resolution order:
#         1. $CLAUDE_PLUGIN_ROOT, if set and non-empty (unchanged fast path).
#         2. Self-location via BASH_SOURCE, when THIS script is itself being
#            run from a real checkout (works for skills that DO invoke this
#            script as a file, e.g. `bash scripts/resolve-sge-root.sh` from
#            inside a known checkout — not the bootstrap case above, but a
#            useful direct-invocation path).
#         3. A search of common Claude Code plugin-cache/marketplace install
#            roots for a directory whose .claude-plugin/plugin.json name is
#            "sge" (the bootstrap fix — works from ANY cwd, no self-location
#            possible since the caller is inline, not a file).
#       Always succeeds if the SGE plugin is installed anywhere findable;
#       exits 1 with a clear stderr message otherwise (never silently prints
#       a bogus path — a wrong root breaks every downstream script the same
#       way `.` did, so failing loud here is strictly better than guessing).
#
# Call-site convention this replaces:
#   OLD (broken):  "${CLAUDE_PLUGIN_ROOT:-.}/scripts/issue-read.sh"
#
#   A call site that IS a real .sh/.mjs file (has its own BASH_SOURCE / import.meta.url)
#   should self-locate directly, exactly as issue-read.sh's `_IR_SCRIPT_DIR`
#   does — that is always more precise than a search and needs no change here.
#
#   An INLINE `!`bash ...`` preload directive in a SKILL.md has no file of its
#   own to self-locate from — it cannot shell out to THIS script either,
#   because it doesn't know this script's path any more than it knew
#   issue-read.sh's. It must perform the same install-root search itself, so
#   every such call site defines and uses this exact function (copy verbatim
#   — do not paraphrase; a slightly-different search per call site is how this
#   class of bug regrows):
#
#     _sge_root() {
#       [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && { printf "%s" "$CLAUDE_PLUGIN_ROOT"; return 0; }
#       local t; t="$(git rev-parse --show-toplevel 2>/dev/null)"
#       if [ -n "$t" ] && [ -d "$t/scripts" ] && [ -d "$t/skills" ] && [ -f "$t/scripts/issue-read.sh" ]; then
#         printf "%s" "$t"; return 0
#       fi
#       local h="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" c d best=""
#       _ok() {
#         [ -f "$1/.claude-plugin/plugin.json" ] || return 1
#         [ -f "$1/scripts/issue-read.sh" ] || return 1
#         if command -v node >/dev/null 2>&1; then
#           node -e 'try{const m=require(process.argv[1]);process.exit(m&&m.name==="sge"?0:1)}catch{process.exit(1)}' "$1/.claude-plugin/plugin.json" 2>/dev/null
#         elif command -v jq >/dev/null 2>&1; then
#           jq -e '.name=="sge"' "$1/.claude-plugin/plugin.json" >/dev/null 2>&1
#         else
#           return 1
#         fi
#       }
#       for d in $(find "$h/plugins/cache" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | awk -F/ '{print $NF, $0}' | sort -k1,1V | cut -d" " -f2-); do
#         _ok "$d" && best="$d"
#       done
#       if [ -z "$best" ]; then
#         for c in "$h"/plugins/marketplaces/*/; do
#           _ok "${c%/}" && { best="${c%/}"; break; }
#         done
#       fi
#       [ -n "$best" ] && { printf "%s" "$best"; return 0; }
#       return 1
#     }
#     SGE_ROOT="$(_sge_root)" || { echo "NO_SGE_ROOT — SGE plugin not found under \$HOME/.claude/plugins" >&2; exit 1; }
#
#   Then: bash "$SGE_ROOT/scripts/issue-read.sh" view "$ARGUMENTS"
#
#   This snippet is deliberately a plain function, not a call to
#   resolve-sge-root.sh itself — an inline directive cannot reach this file
#   without already knowing where it is, which is precisely the problem being
#   solved. The two implementations (this script's step 3, and the snippet
#   above) are kept in lockstep by scripts/resolve-sge-root.test.sh's
#   bootstrap-scenario tests, which exercise the search this script performs
#   against the same fixture layouts the snippet is designed to search.
#
# Exit codes:
#   0  root resolved and printed on stdout.
#   1  CLAUDE_PLUGIN_ROOT unset, this script is not itself running from a
#      real checkout, AND no known install location carries a plugin.json
#      named "sge" — the plugin genuinely cannot be found. Never falls back
#      to an unverified guess.

set -uo pipefail

# 1. CLAUDE_PLUGIN_ROOT, when the Claude Code plugin runtime set it — this is
#    the common case for every existing installed-plugin invocation and is
#    byte-identical to prior behaviour whenever it is actually set.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  printf '%s\n' "$CLAUDE_PLUGIN_ROOT"
  exit 0
fi

_is_sge_root() {
  # A candidate root is confirmed (not guessed) only when its plugin.json's
  # TOP-LEVEL "name" field is "sge" (parsed with a real JSON parser, not a
  # substring/regex grep — a grep anchored on `"name": "sge"` still matches a
  # nested field, e.g. {"name":"totally-different-plugin","dependencies":
  # {"name":"sge"}}, which a live security review (PR #2266) confirmed wins
  # selection over the real plugin root) AND scripts/issue-read.sh actually
  # exists under the candidate — every consumer of this resolver immediately
  # shells out to that script, so a root without it is not usable regardless
  # of what its manifest claims.
  [ -f "$1/.claude-plugin/plugin.json" ] || return 1
  [ -f "$1/scripts/issue-read.sh" ] || return 1
  if command -v node >/dev/null 2>&1; then
    node -e '
      const fs = require("fs");
      try {
        const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        process.exit(m && m.name === "sge" ? 0 : 1);
      } catch { process.exit(1); }
    ' "$1/.claude-plugin/plugin.json" 2>/dev/null
    return $?
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -e '.name == "sge"' "$1/.claude-plugin/plugin.json" >/dev/null 2>&1
    return $?
  fi
  echo "resolve-sge-root.sh: neither node nor jq is available to parse plugin.json — cannot safely verify plugin identity, refusing to guess." >&2
  return 1
}

# 2. Self-location via BASH_SOURCE — resolves relative to THIS script's own
#    real path, not the caller's cwd. Only applies when this script is
#    genuinely being executed as a file (has a real BASH_SOURCE); an inline
#    `!`bash ...`` preload directive cannot reach this branch at all since it
#    has no file of its own — that is the bootstrap problem step 3 solves.
if [ -n "${BASH_SOURCE:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _CANDIDATE="$(dirname "$_SELF_DIR")"   # scripts/ -> repo root
  if _is_sge_root "$_CANDIDATE"; then
    printf '%s\n' "$_CANDIDATE"
    exit 0
  fi
  # Not carrying the plugin manifest (e.g. a bare git clone without
  # .claude-plugin/) — the git toplevel of THIS script's own checkout is
  # still a valid, self-located root (GitHub Copilot coding agent checkout,
  # or a contributor's plain `git clone` outside the plugin marketplace) —
  # but ONLY when that toplevel actually looks like an SGE checkout. A live
  # security review (PR #2266) reproduced this branch returning an unrelated
  # git repo's toplevel unverified — because it printed and exited before
  # step 3's verified search ever ran, any repo containing a copy of this
  # script (even outside a real SGE checkout) won it over the genuine
  # install. Require the toplevel to actually contain scripts/ and skills/
  # (not the full plugin.json identity check — a bare git clone of this repo
  # legitimately lacks .claude-plugin/, so `_is_sge_root` is deliberately
  # not required here); fall through to step 3 otherwise.
  if _GIT_TOPLEVEL="$(cd "$_SELF_DIR" && git rev-parse --show-toplevel 2>/dev/null)" \
    && [ -n "$_GIT_TOPLEVEL" ] \
    && [ -d "$_GIT_TOPLEVEL/scripts" ] \
    && [ -d "$_GIT_TOPLEVEL/skills" ] \
    && [ -f "$_GIT_TOPLEVEL/scripts/issue-read.sh" ]; then
    printf '%s\n' "$_GIT_TOPLEVEL"
    exit 0
  fi
fi

# 3. The bootstrap fix: search known Claude Code plugin install roots for a
#    directory whose plugin.json identifies it as "sge". This is the ONLY
#    path available to an inline preload directive (no BASH_SOURCE of its
#    own) and is what makes this script actually solve the bug, not just
#    relocate it. Search both plugin layouts Claude Code uses:
#      - cache/<marketplace-name>/<plugin>/<version>/ (versioned cache install)
#      - marketplaces/<marketplace-name>/            (git-checkout install)
#    Precedence is DETERMINISTIC, not mtime-based (a live security review,
#    PR #2266, confirmed "most-recently-modified wins" lets an attacker- or
#    accident-controlled directory — a stray feature-branch checkout touched
#    after the real install — win over the genuine plugin): cache/, at its
#    highest semver, ranks above marketplaces/, because a versioned cache
#    install is the runtime's own managed artifact, while marketplaces/ is a
#    live git checkout more likely to be a contributor's working copy.
_CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

_CACHE_CANDIDATES=()
if [ -d "$_CLAUDE_HOME/plugins/cache" ]; then
  # Depth here is <marketplace>/<plugin>/<version>/ = 3 levels below cache/,
  # confirmed against the live layout (plugins/cache/wtp-plugins/sgd/4.33.0/)
  # — a shallower search silently misses every cached plugin version.
  while IFS= read -r -d '' _d; do
    _CACHE_CANDIDATES+=("$_d")
  done < <(find "$_CLAUDE_HOME/plugins/cache" -mindepth 3 -maxdepth 3 -type d -print0 2>/dev/null)
fi

_MARKETPLACE_CANDIDATES=()
if [ -d "$_CLAUDE_HOME/plugins/marketplaces" ]; then
  while IFS= read -r -d '' _d; do
    _MARKETPLACE_CANDIDATES+=("$_d")
  done < <(find "$_CLAUDE_HOME/plugins/marketplaces" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

# Within cache/, rank by semver (highest wins) rather than mtime — a
# freshly-touched-but-older cached version must not beat a genuinely newer
# one. Sort by the trailing path segment (the version directory) with
# version sort (`sort -V`) to get a correct, deterministic semver ordering —
# lowest first, so the loop below overwrites _BEST with each higher version
# and ends on the highest.
_BEST=""
if [ "${#_CACHE_CANDIDATES[@]}" -gt 0 ]; then
  while IFS= read -r _c; do
    [ -n "$_c" ] || continue
    if _is_sge_root "$_c"; then
      _BEST="$_c"
    fi
  done < <(printf '%s\n' "${_CACHE_CANDIDATES[@]}" | awk -F/ '{print $NF, $0}' | sort -k1,1V | cut -d' ' -f2-)
fi

if [ -z "$_BEST" ]; then
  for _c in "${_MARKETPLACE_CANDIDATES[@]+"${_MARKETPLACE_CANDIDATES[@]}"}"; do
    if _is_sge_root "$_c"; then
      _BEST="$_c"
      break
    fi
  done
fi

if [ -n "$_BEST" ]; then
  printf '%s\n' "$_BEST"
  exit 0
fi

echo "resolve-sge-root.sh: could not resolve the SGE plugin root — CLAUDE_PLUGIN_ROOT is unset, this script is not running from a checkout, and no installed plugin under $_CLAUDE_HOME/plugins/{marketplaces,cache} declares plugin.json name \"sge\"." >&2
exit 1
