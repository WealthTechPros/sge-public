#!/usr/bin/env bash
# assess.sh: READ-ONLY evidence for one B/C item (issue #3621). It gathers the
# git half of references/assessor-brief.md so a host without subagents
# (GitHub Copilot) can assess items inline, one at a time, with the same
# evidence a Claude Code assessor agent would collect. It never fetches,
# checks out, commits, pushes, deletes or calls a host API; the linked issue's
# state and the recommendation stay with the session.
#
#   assess.sh <repo-dir> <ref>      ref = branch, origin/<branch>, stash@{n} or a SHA
#
# Prints key: value lines: ref, tip, base, supersession (live | superseded |
# unknown), ahead, commits (subjects, newest first, max 20), net_diff (diffstat
# vs the merge base), tests (changed test files), linked_issues (#N from the
# branch name and commit messages), uncommitted (file names only, worktrees).
# Exit: 0 ok, 2 usage, 3 ref or repo unreadable. Names are untrusted data.
_AS_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_AS_HERE/audit.sh" # _ta_supersession, nothing runs on source
set +e

as_main() {
  local repo="${1:-}" ref="${2:-}" tip base def wt
  [ -n "$repo" ] && [ -n "$ref" ] || { echo "usage: assess.sh <repo-dir> <ref>" >&2; return 2; }
  cd "$repo" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $repo" >&2; return 3; }
  tip="$(git rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null | tr -d '\r')"
  [ -n "$tip" ] || { echo "unreadable ref: $ref" >&2; return 3; }
  def="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"; [ -n "$def" ] || def=main
  base="origin/$def"
  echo "ref: $ref"
  echo "tip: $tip"
  echo "base: $base"
  echo "supersession: $(_ta_supersession "$tip" "$base")"
  echo "ahead: $(git rev-list --count "$base..$tip" 2>/dev/null || echo unknown)"
  echo "commits:"; git log --format='  %h %s' -20 "$base..$tip" 2>/dev/null
  echo "net_diff:"; git diff --stat=120 "$base...$tip" 2>/dev/null | sed 's/^/  /'
  echo "tests:"; git diff --name-only "$base...$tip" 2>/dev/null | grep -Ei '(^|/)(tests?|__tests__|spec)/|[._-](test|spec)\.' | sed 's/^/  /'
  echo "linked_issues: $( { printf '%s\n' "$ref"; git log --format=%B "$base..$tip" 2>/dev/null; } \
    | grep -oE '#[0-9]+|(^|[/_-])[0-9]{2,6}([/_-]|$)' | grep -oE '[0-9]+' | sort -un | sed 's/^/#/' | tr '\n' ' ')"
  wt="$(git worktree list --porcelain 2>/dev/null | tr -d '\r' | awk -v b="branch refs/heads/${ref#origin/}" '/^worktree /{w=substr($0,10)} $0==b{print w; exit}')"
  echo "uncommitted:"; [ -z "$wt" ] || git -C "$wt" status --porcelain 2>/dev/null | cut -c4- | sed 's/^/  /'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then as_main "$@"; exit $?; fi
