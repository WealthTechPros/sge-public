#!/usr/bin/env bash
# reconcile-flush.sh — the Phase 0.5 flush reconciliation gate for
# /sge:team-pipeline (issue #856; script-extraction per epic #729 / #819–#823).
#
# team-pipeline Phase 0.5 pushes unpushed worktree branches and opens draft
# PRs so in-flight work becomes visible to CI and reviewers. Verbatim, it
# treated EVERY unpushed worktree as lost work. In the 2026-07-06 pipeline run
# 27 of 28 unpushed worktrees actually belonged to CLOSED issues whose content
# had already landed via squash merges — squash merges leave no shared
# ancestry, so a plain "is this branch pushed?" heuristic lies. Flushing
# verbatim would have opened ~27 garbage draft PRs, each burning a CI run plus
# a review-lane dispatch: the single largest avoidable token burn in the run.
#
# This script classifies each flush candidate before any push, applying the
# two #856 gates. A candidate is FLUSH only if BOTH pass:
#
#   1. Novelty gate  — `git cherry <base>` reports >=1 commit whose patch-id
#      is not already on <base> (robust to single-commit squash merges, which
#      collapse to an identical patch-id; a multi-commit branch squashed into
#      one upstream commit is NOT caught here — that is the open-issue gate's
#      job, see #856 evidence).
#   2. Open-issue gate — the branch's linked issue is still OPEN. A branch for
#      a CLOSED issue is presumed landed, not lost, regardless of novelty.
#
# Anything failing either gate is classified `tidy` (a /sge:tidy-worktrees
# hand-off candidate), never pushed.
#
# Contract (same JSON-to-stdout family as check-regulatory-trace.sh /
# scan-skills.sh):
#   * Emits a single JSON object to stdout: { candidates: [ ... ], summary }.
#     Each candidate: { path, branch, issue, novel, issueState, decision,
#     reason }. decision is "flush" | "tidy".
#   * Exit 0 = ran successfully (regardless of how candidates classified).
#     Exit 2 = harness error (not in a git repo, no base ref).
#   * The caller pushes / draft-PRs ONLY the decision:"flush" candidates and
#     hands the decision:"tidy" ones to /sge:tidy-worktrees.
#
# Sourceable: when sourced (BASH_SOURCE[0] != $0) it defines the helpers and
# returns without running, so the regression suite can unit-test
# classify_worktree against real git fixtures + a stubbed `gh`.
#
# Env / args:
#   BASE            base ref to reconcile against (default: origin/main)
#   WORKTREE_BASE   in-repo pipeline layout root  ($ROOT/.worktrees)
#   SIBLING_BASE    canonical sibling layout root ($(dirname ROOT)/<repo>-worktrees)
#   $1..            explicit worktree paths to classify (overrides discovery)
#
# Run:  bash reconcile-flush.sh              # discover both layouts
#       bash reconcile-flush.sh /path/wt ... # classify the given paths

# NO `set -e` at file scope: this file is sourced by the test suite, and a
# non-zero from a helper (an expected "tidy" verdict) must not kill the shell.

BASE="${BASE:-origin/main}"

# json_str <raw> — emit a JSON-safe double-quoted string for arbitrary text.
json_str() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/ }
  s=${s//$'\t'/ }
  printf '"%s"' "$s"
}

# novel_commit_count <worktree_path> <base> — commits on the worktree branch
# whose patch-id is NOT already on <base> (git cherry '+' lines). Prints an
# integer; prints 0 on any git failure (fail safe: unknown novelty -> tidy).
novel_commit_count() {
  local path=$1 base=$2 n
  n=$(git -C "$path" cherry "$base" 2>/dev/null | grep -c '^+') || n=0
  printf '%s' "${n:-0}"
}

# linked_issue <branch> — first integer run in the branch name (issue number),
# empty when the branch encodes no issue number.
linked_issue() {
  printf '%s' "$1" | grep -oE '[0-9]+' | head -1
}

# issue_state <issue-number> — uppercase GitHub state ("OPEN"/"CLOSED") via
# `gh`, or empty when gh is unavailable / the lookup fails. Empty is treated
# by the gate as "not known closed" (do not block the flush on a gh outage —
# the novelty gate has already passed by the time this is consulted).
issue_state() {
  [ -n "$1" ] || return 0
  gh issue view "$1" --json state -q .state 2>/dev/null | tr '[:lower:]' '[:upper:]'
}

# classify_worktree <path> <branch> [base] — emit one candidate JSON object.
# Returns 0 when decision is "flush", 1 when "tidy". This is the whole #856
# gate, in one testable unit.
classify_worktree() {
  local path=$1 branch=$2 base=${3:-$BASE}
  local novel issue state decision reason rc

  novel=$(novel_commit_count "$path" "$base")
  issue=$(linked_issue "$branch")

  if [ "${novel:-0}" -eq 0 ] 2>/dev/null; then
    # Gate 1 failed: no patch-novel commits vs base (single-commit squash
    # merges land here).
    decision="tidy"; reason="no novel commits vs $base"; rc=1; state=""
  else
    state=$(issue_state "$issue")
    if [ "$state" = "CLOSED" ]; then
      # Gate 2 failed: multi-commit squash false-positive on gate 1 is caught
      # here — the linked issue is closed, so content is presumed landed.
      decision="tidy"; reason="issue #$issue closed, content presumed landed"; rc=1
    else
      decision="flush"
      if [ -n "$issue" ]; then
        reason="$novel novel commit(s) vs $base, issue #$issue open"
      else
        reason="$novel novel commit(s) vs $base, no linked issue"
      fi
      rc=0
    fi
  fi

  printf '{"path":%s,"branch":%s,"issue":%s,"novel":%s,"issueState":%s,"decision":%s,"reason":%s}' \
    "$(json_str "$path")" \
    "$(json_str "$branch")" \
    "$(json_str "$issue")" \
    "${novel:-0}" \
    "$(json_str "$state")" \
    "$(json_str "$decision")" \
    "$(json_str "$reason")"
  return "$rc"
}

# discover_candidates — worktree paths matching either the pipeline in-repo
# layout ($WORKTREE_BASE/issue-*) or the canonical sibling layout
# ($SIBLING_BASE/*). Mirrors Phase 0.5's flush_candidate_paths path coverage.
discover_candidates() {
  local wtbase="${WORKTREE_BASE:-}" sibbase="${SIBLING_BASE:-}" p
  git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' \
    | while IFS= read -r p; do
        case "$p" in
          "$wtbase"/issue-*) [ -n "$wtbase" ] && echo "$p" ;;
          "$sibbase"/*)      [ -n "$sibbase" ] && echo "$p" ;;
        esac
      done
}

main() {
  # Must be inside a git repo to resolve the base and enumerate worktrees.
  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "reconcile-flush: not inside a git repository" >&2
    return 2
  fi
  # A missing base ref would make git cherry error on every candidate (novelty
  # unknowable) — fail loudly rather than silently classifying everything tidy.
  if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
    echo "reconcile-flush: base ref '$BASE' not found (run: git fetch origin main)" >&2
    return 2
  fi

  local -a paths=()
  if [ "$#" -gt 0 ]; then
    paths=("$@")
  else
    while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done < <(discover_candidates)
  fi

  local first=1 flush=0 tidy=0 branch obj
  printf '{"base":%s,"candidates":[' "$(json_str "$BASE")"
  local path
  for path in "${paths[@]}"; do
    branch=$(git -C "$path" branch --show-current 2>/dev/null)
    [ -n "$branch" ] || continue
    obj=$(classify_worktree "$path" "$branch")
    if [ "$?" -eq 0 ]; then flush=$((flush+1)); else tidy=$((tidy+1)); fi
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '%s' "$obj"
  done
  printf '],"summary":{"flush":%s,"tidy":%s}}\n' "$flush" "$tidy"
  return 0
}

# Run only when executed, not when sourced (so tests can source the helpers).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit "$?"
fi
