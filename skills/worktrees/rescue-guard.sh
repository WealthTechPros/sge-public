#!/usr/bin/env bash
# rescue-guard.sh — the mandatory rebase + isolated-install guard for
# rescued/resumed git worktrees (issue #951).
#
# A worktree that was resurrected from stale WIP (tidy-worktrees' Phase 3
# "push + draft PR" rescue) or resumed from an abandoned session can be behind
# the base branch AND can be silently serving a MAIN workspace's stale build
# output through a junctioned/shared node_modules (the fast-spawn worktree
# pattern — a symlink/NTFS-junction whose node_modules resolves into the main
# checkout, not this worktree). Either condition makes the worktree's own
# `tsc`/test claims untrustworthy: tests pass or fail against the wrong tree.
#
# This guard is the single mechanical check both /sge:tidy-worktrees and
# /sge:pr-review run BEFORE they trust (or publish) any verification claim for
# such a worktree. It answers two yes/no questions and prints a verdict:
#
#   1. Is the worktree behind its base ref?  (base has commits the worktree
#      does not — a rebase onto base is mandatory before merge/verify.)
#   2. Does node_modules resolve OUTSIDE this worktree?  (shared/junctioned —
#      an isolated dependency install in this worktree is mandatory before its
#      build output can be trusted.)
#
# `assess` answers the two git/filesystem questions above. A second mode,
# `verify` (issue #1447), goes one step further: AFTER a rescue is rebased and
# isolated-installed clean, it actually RUNS the repo's own quality suite in the
# worktree — the isolated install, typecheck, format:check and the affected test
# subset — so a "Push + draft PR" rescue can only publish a READY PR when the
# rescued code genuinely compiles/formats/tests, never on a stale claim. The
# commands are discovered from the repo CLAUDE.md (never hardcoded to a stack),
# so verify works for TypeScript, Python, shell or anything else.
#
# A third mode, `supersession` (issue #1538), runs BEFORE either of the above —
# it is the FIRST question the "Push + draft PR" path must ask: does this rescue
# branch introduce net work that is NOT already in origin/main? It encodes the
# 2026-07-23 incident where a fleet main-clean sweep pushed 3 rescued branches
# as PRs — all three already fully merged via other PRs, and one of which would
# have REVERTED ~1,808 lines had it merged. supersession answers this without
# mutating the worktree, via the non-destructive equivalent of a
# `git rebase origin/main --empty=drop`:
#
#   1. surviving_commits — `git cherry <base> HEAD` counts the branch commits
#      that have NO patch-equivalent already in base (exactly the commits that
#      would survive `rebase --empty=drop`). Zero survivors ⇒ every commit is
#      already in main (by patch-id), so pushing contributes nothing — and if
#      main has since advanced the same files, pushing would REVERT them.
#   2. files_diff — the file-level diff of the branch's touched files against
#      base. Empty ⇒ those files are already byte-identical to main, so the
#      branch's net effect is already contained in main.
#
# SUPERSEDED when EITHER signal fires; the caller reports SUPERSEDED and
# recommends delete-not-PR instead of pushing a rescue PR.
#
# Usage — SOURCE it for the individual predicates, or invoke a subcommand:
#   source "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/worktrees/rescue-guard.sh"
#   rg_behind_base <worktree> [base-ref]        # integer; -1 = base unresolvable
#   rg_shared_node_modules <worktree>           # yes | no
#   rg_assess <worktree> [base-ref]             # prints the verdict block
#   rg_verify_command <repo-claude-md> <stage>  # the command declared for <stage>
#   rg_verify <worktree> <repo-claude-md>       # runs the quality suite; verdict
#   rg_supersession <worktree> [base-ref]       # superseded|live|unknown verdict
#
#   bash rescue-guard.sh assess <worktree> [base-ref]     # CLI form
#   bash rescue-guard.sh verify <worktree> <repo-claude-md>
#   bash rescue-guard.sh supersession <worktree> [base-ref]
#
# rg_assess prints (stdout):
#   behind_base:<N|unknown>
#   shared_node_modules:yes|no
#   verdict:up-to-date | needs-rebase | isolated-install-only | needs-rebase-and-isolated-install
#
# rg_verify prints (stdout), one line per ordered stage plus a summary verdict:
#   install:pass|fail|skip
#   typecheck:pass|fail|skip
#   format:pass|fail|skip
#   test:pass|fail|skip
#   verify:pass | verify:fail:<stage>          # <stage> incl. `config`
#
# rg_supersession prints (stdout):
#   base:<resolved base ref>
#   surviving_commits:<N|unknown>              # branch commits not already in base
#   touched_files:<N|unknown>
#   files_diff:empty|nonempty|unknown          # touched files vs base
#   verdict:superseded | live | unknown
#
# Exit codes (rg_assess / CLI):
#   0  — up-to-date AND not shared: no mandatory step, verification is trustworthy as-is
#   10 — action required: rebase onto base and/or run an isolated install first
#   3  — <worktree> is not a git working tree (cannot assess)
#
# Exit codes (rg_verify / CLI):
#   0  — verify:pass (every declared stage passed)
#   20 — verify:fail:<stage> — a gate failed, or NO stage was declared at all
#        (verify:fail:config), so the caller must NOT publish a "verified" ready
#        PR: push a DRAFT with a "CI-unverified" note instead.
#   3  — <worktree> is not a git working tree (cannot verify)
#
# Exit codes (rg_supersession / CLI):
#   0  — verdict:live — the branch carries net work not already in base; the
#        rescue push may proceed (then run assess/verify as usual).
#   30 — verdict:superseded — every commit is already in base by patch-id, or
#        the touched files are already identical to base. The caller must NOT
#        push a rescue PR: recommend delete-not-PR (record the tip SHA first).
#   40 — verdict:unknown — the base ref could not be resolved, so supersession
#        is UNANSWERABLE. Fail SAFE: neither auto-push nor auto-delete — surface
#        for a manual decision (fetch the base, or check the branch by hand).
#   3  — <worktree> is not a git working tree (cannot check)
#
# ORDERING: `supersession` runs FIRST — a superseded branch must never be
# pushed at all, so there is no point rebasing/installing/verifying it. Only a
# `live` branch proceeds to `assess` (rebase + isolated install per the verdict)
# and then `verify` (the real quality run). verify assumes the assess checks are
# already clean — the caller (tidy-worktrees Phase 3) runs `assess`, rebases
# onto base and/or runs an isolated install per the verdict, THEN runs `verify`.
# verify's own `install` stage is that isolated install, so a junctioned
# node_modules is broken by the fresh install before the typecheck/test stages
# read the tree.
#
# FAIL CLOSED: an unresolvable base ref is treated as action-required
# (behind_base:unknown, verdict includes needs-rebase) — the safe default is to
# rebase+install, never to wave a possibly-stale worktree through as clean.
# verify likewise fails closed: an undeclared repo yields verify:fail:config,
# never a silent pass.
#
# UNTRUSTED DATA: <worktree> and <base-ref> are caller-supplied paths/refs —
# they are only ever passed to git as operands (never eval'd) and to the
# filesystem, so a hostile branch name or path cannot execute as a command.
# TRUSTED CONFIG: the <repo-claude-md> commands ARE executed (that is the point
# — running the repo's own documented quality suite), exactly as running its
# package.json scripts would be. Point verify only at a trusted repo CLAUDE.md,
# never at one from an untrusted branch.

set -uo pipefail

# Default base ref when the caller omits one. origin/main is the merge target
# for every SGE-managed repo; a rescued worktree is "stale" relative to it.
RG_DEFAULT_BASE="${RG_DEFAULT_BASE:-origin/main}"

# rg_behind_base <worktree> [base-ref]
# Prints the count of commits on <base-ref> that are NOT reachable from the
# worktree's HEAD (i.e. how far the worktree is behind base). 0 = up to date.
# Prints -1 (and returns 2) when <base-ref> cannot be resolved in the worktree.
rg_behind_base() {
  local wt="$1" base="${2:-$RG_DEFAULT_BASE}"
  if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo -1; return 3
  fi
  if ! git -C "$wt" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
    echo -1; return 2
  fi
  # HEAD..base = commits reachable from base but not from HEAD.
  local n
  n=$(git -C "$wt" rev-list --count "HEAD..${base}" 2>/dev/null) || { echo -1; return 2; }
  echo "$n"
}

# rg_shared_node_modules <worktree>
# Prints "yes" when the worktree's node_modules resolves OUTSIDE the worktree
# — a POSIX symlink, an NTFS directory junction, or any path whose physical
# location differs from <worktree>/node_modules. Prints "no" when node_modules
# is absent or is a real directory inside the worktree.
rg_shared_node_modules() {
  local wt="$1"
  local nm="$wt/node_modules"
  # Absent -> nothing shared (a fresh worktree with no install yet).
  [ -e "$nm" ] || { echo "no"; return 0; }
  # A symlink is unambiguously shared regardless of where it points.
  if [ -L "$nm" ]; then echo "yes"; return 0; fi
  # Otherwise compare physical paths: cd into node_modules and read its real
  # location. For a junction/bind that resolves elsewhere, this differs from
  # the worktree-local path. Both sides use `pwd -P` so a worktree reached via
  # a symlinked parent does not produce a false positive.
  local real base
  real=$(cd "$nm" 2>/dev/null && pwd -P) || { echo "no"; return 0; }
  base=$(cd "$wt" 2>/dev/null && pwd -P)/node_modules
  if [ -n "$real" ] && [ "$real" != "$base" ]; then echo "yes"; else echo "no"; fi
}

# rg_assess <worktree> [base-ref]
# The single entrypoint both skills call. Prints the verdict block and returns
# 0 (no action) / 10 (action required) / 3 (not a worktree).
rg_assess() {
  local wt="$1" base="${2:-$RG_DEFAULT_BASE}"
  if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error:not-a-git-worktree" >&2
    return 3
  fi

  local behind shared behind_label action=0
  behind=$(rg_behind_base "$wt" "$base"); local brc=$?
  shared=$(rg_shared_node_modules "$wt")

  if [ "$brc" -ne 0 ] || [ "$behind" = "-1" ]; then
    # Base unresolvable -> fail closed: treat as behind (must rebase).
    behind_label="unknown"
    local stale=1
  elif [ "$behind" -gt 0 ]; then
    behind_label="$behind"
    local stale=1
  else
    behind_label="$behind"
    local stale=0
  fi

  local verdict
  if [ "$stale" -eq 1 ] && [ "$shared" = "yes" ]; then
    verdict="needs-rebase-and-isolated-install"; action=1
  elif [ "$stale" -eq 1 ]; then
    verdict="needs-rebase"; action=1
  elif [ "$shared" = "yes" ]; then
    verdict="isolated-install-only"; action=1
  else
    verdict="up-to-date"; action=0
  fi

  echo "behind_base:${behind_label}"
  echo "shared_node_modules:${shared}"
  echo "verdict:${verdict}"

  [ "$action" -eq 0 ] && return 0
  return 10
}

# The ordered quality stages verify runs. Each is INDEPENDENTLY optional: a
# stage the repo CLAUDE.md does not declare is skipped, not failed — so a
# pure-shell repo (test only) and a full TypeScript repo (all four) are both
# valid. Kept in this order so the cheap, fast gates fail first.
RG_VERIFY_STAGES="install typecheck format test"

# rg_verify_command <repo-claude-md> <stage>
# Discovers the command a repo declares for <stage> via the stack-agnostic
# marker convention in its CLAUDE.md — one HTML-comment line per stage:
#
#   <!-- rescue-verify:install:   pnpm install --frozen-lockfile --ignore-workspace -->
#   <!-- rescue-verify:typecheck: pnpm -w run type-check -->
#   <!-- rescue-verify:format:    pnpm -w run format:check -->
#   <!-- rescue-verify:test:      pnpm -w run test:affected -->
#
# Prints the trimmed command and returns 0 when the stage is declared; returns
# 1 when the file is missing or the stage is absent. The command must not itself
# contain the `-->` comment terminator. Uses only portable grep + parameter
# expansion + a BSD/GNU-safe [[:space:]] trim (no GNU-only sed/grep syntax).
rg_verify_command() {
  local claude_md="$1" stage="$2"
  [ -f "$claude_md" ] || return 1
  local line
  line=$(grep -E "rescue-verify:${stage}:" "$claude_md" 2>/dev/null | head -1)
  [ -n "$line" ] || return 1
  local cmd="${line#*rescue-verify:${stage}:}"   # drop up to & incl. the marker
  cmd="${cmd%%-->*}"                              # drop the comment terminator on
  cmd=$(printf '%s' "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$cmd" ] || return 1
  printf '%s' "$cmd"
}

# rg_verify <worktree> <repo-claude-md>
# Runs the repo's own quality suite inside the worktree — see the header block
# for the contract. Stages run in RG_VERIFY_STAGES order; the FIRST failure
# short-circuits (remaining stages are not run). A stage with no declared
# command is skipped. When NO stage is declared (or the CLAUDE.md is missing)
# the verdict is verify:fail:config so a rescue cannot claim "verified" for a
# repo that documents no gates.
rg_verify() {
  local wt="$1" claude_md="${2:-}"
  if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error:not-a-git-worktree" >&2
    return 3
  fi

  local ran=0 stage cmd
  for stage in $RG_VERIFY_STAGES; do
    if cmd=$(rg_verify_command "$claude_md" "$stage"); then
      ran=1
      # Run the declared command in the worktree. Its stdout is redirected to
      # the guard's stderr (its own stderr already goes there) so this
      # function's stdout stays machine-readable.
      if ( cd "$wt" && bash -c "$cmd" ) >&2; then
        echo "${stage}:pass"
      else
        echo "${stage}:fail"
        echo "verify:fail:${stage}"
        return 20
      fi
    else
      echo "${stage}:skip"
    fi
  done

  if [ "$ran" -eq 0 ]; then
    echo "verify:fail:config"
    return 20
  fi
  echo "verify:pass"
  return 0
}

# rg_supersession <worktree> [base-ref]
# The supersession preflight (issue #1538). Runs BEFORE assess/verify on the
# "Push + draft PR" rescue path. Answers, without mutating the worktree, whether
# the branch introduces net work that is not already in <base-ref> — the
# non-destructive equivalent of `git rebase <base> --empty=drop` plus a
# file-level diff. Prints the verdict block; returns 0 (live) / 30 (superseded)
# / 40 (base unresolvable → unknown) / 3 (not a worktree).
#
# FAIL SAFE (deliberately NOT the same as assess/verify's fail-closed): when the
# base ref cannot be resolved the supersession question is unanswerable, so the
# verdict is `unknown` — the caller must neither auto-push (could revert main)
# nor auto-delete (could bin live work). Both wrong answers are costly here, so
# the only safe default is to surface it for a human/gh decision.
rg_supersession() {
  local wt="$1" base="${2:-$RG_DEFAULT_BASE}"
  if ! git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error:not-a-git-worktree" >&2
    return 3
  fi

  echo "base:${base}"

  # Base unresolvable -> the supersession question cannot be answered. Fail SAFE
  # to unknown (never a silent live/superseded), so the caller stops and checks.
  if ! git -C "$wt" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
    echo "surviving_commits:unknown"
    echo "touched_files:unknown"
    echo "files_diff:unknown"
    echo "verdict:unknown"
    return 40
  fi

  # surviving_commits — the branch commits with NO patch-equivalent already in
  # base. `git cherry <base> HEAD` prints `+ <sha>` for a commit not upstream
  # and `- <sha>` for one already applied (by patch-id); the `+` count is
  # exactly what would survive `rebase <base> --empty=drop`. A cherry FAILURE
  # (corrupt repo, ref race) must NOT be mistaken for "zero survivors" — that
  # would silently produce a superseded verdict — so its exit status is checked
  # and a failure fails SAFE to unknown, like the base-resolution check above.
  local cherry_out cherry_rc surviving
  cherry_out=$(git -C "$wt" cherry "$base" HEAD 2>/dev/null); cherry_rc=$?
  if [ "$cherry_rc" -ne 0 ]; then
    echo "surviving_commits:unknown"
    echo "touched_files:unknown"
    echo "files_diff:unknown"
    echo "verdict:unknown"
    return 40
  fi
  surviving=$(printf '%s\n' "$cherry_out" | grep -c '^+ ')

  # touched_files / files_diff — the files that DIFFER between base's tip and
  # HEAD (two-dot `git diff <base> HEAD`). Deliberately NOT three-dot
  # (`<base>...HEAD`): three-dot needs a merge-base and FATALS ("no merge base")
  # on a disjoint-history branch (orphan branch, rewritten/root-rebased history,
  # pruned fork point) — a fatal that, swallowed, would leave an empty set and
  # wrongly read as "already contained in main." Two-dot needs no merge-base:
  # an empty diff means HEAD's tree already equals base's on every path (net-zero
  # vs base — squash-merged, reverted-in-branch, or nothing ahead), i.e. the
  # branch contributes nothing over main. NUL-safe; the paths are only ever
  # passed to git as pathspec operands, never evaluated.
  local -a touched=()
  local f
  while IFS= read -r -d '' f; do
    touched+=("$f")
  done < <(git -C "$wt" diff -z --name-only "$base" HEAD 2>/dev/null)

  # files_diff — empty when the branch's net effect is already contained in base.
  # With the two-dot name-only list above, a non-empty list is by construction a
  # real tree difference, so files_diff mirrors whether any path differs.
  local files_diff
  if [ "${#touched[@]}" -eq 0 ]; then
    files_diff="empty"
  else
    files_diff="nonempty"
  fi

  echo "surviving_commits:${surviving}"
  echo "touched_files:${#touched[@]}"
  echo "files_diff:${files_diff}"

  # SUPERSEDED when EITHER signal fires: nothing unique survives a drop-rebase,
  # OR the touched files already match base. Otherwise the branch is live.
  if [ "$surviving" -eq 0 ] || [ "$files_diff" = "empty" ]; then
    echo "verdict:superseded"
    return 30
  fi
  echo "verdict:live"
  return 0
}

# CLI dispatch — only when executed directly, never when sourced (so the
# predicates can be unit-tested without running anything). BASH_SOURCE[0] ==
# $0 exactly when this file is the executed script.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"
  case "$cmd" in
    assess)             shift; rg_assess "$@" ;;
    verify)             shift; rg_verify "$@" ;;
    supersession)       shift; rg_supersession "$@" ;;
    behind-base)        shift; rg_behind_base "$@" ;;
    shared-node-modules) shift; rg_shared_node_modules "$@" ;;
    verify-command)     shift; rg_verify_command "$@" ;;
    *)
      echo "usage: rescue-guard.sh {assess|verify|supersession|behind-base|shared-node-modules|verify-command} <worktree|repo-claude-md> [arg]" >&2
      exit 3
      ;;
  esac
fi
