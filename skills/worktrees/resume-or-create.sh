#!/usr/bin/env bash
# resume-or-create.sh — search-before-create for issue worktrees (issue #1171).
#
# When an agent is dispatched on issue N, a predecessor agent may already have
# created a worktree (`../<repo>-worktrees/issue-N` OR the team-pipeline
# in-repo `.worktrees/issue-N`) and/or a branch (`(feat|feature|fix|chore)/…
# issue-N…`, `feat/sge-<slug>`) before dying or stalling. Creating a NEW
# worktree/branch then either collides with the old one (`git worktree add`
# refuses a second checkout of a branch) or orphans the predecessor's
# committed progress. This helper answers ONE question before any
# `git worktree add`: resume, create, or back off?
#
# It is a decision helper only. It does NOT create, remove, rebase, or install
# anything (that is the calling skill's Phase 3, plus the mandatory
# rescue-guard.sh on resume). It reads git state and prints a machine-readable
# verdict block; the caller acts on it.
#
# Usage — invoke a subcommand (CLI form), or source for the predicates:
#   bash resume-or-create.sh decide <issue-number> [repo-root] [base-ref]
#   bash resume-or-create.sh claim  <worktree>        # write/refresh a claim lease
#   bash resume-or-create.sh release <worktree>       # drop the claim lease
#
#   source resume-or-create.sh
#   roc_find_worktree <issue> <repo-root>       # prints worktree path or empty
#   roc_find_branch   <issue> <repo-root>       # prints branch name or empty
#   roc_claim_state   <worktree>                # prints free | mine | held-fresh
#
# `decide` prints (stdout), one key:value per line:
#   verdict:resume | create | backoff
#   worktree:<path|->            # existing worktree to resume, or - when none
#   branch:<name|->              # existing issue branch, or - when none
#   open_pr:<number|->           # existing OPEN PR for the branch, or - / unknown
#   claim:free | mine | held-fresh
#   note:<human-readable one-liner>
#
# Verdict rules:
#   backoff — an existing worktree carries a FRESH claim lease owned by ANOTHER
#             live agent (younger than SGE_WT_CLAIM_TTL_MIN, default 30 min, and
#             not this agent's SGE_AGENT_ID). Do NOT steal it; report and stop.
#   resume  — an existing worktree for issue N is found and is not
#             another-agent-fresh-claimed (free, mine, or stale claim to take
#             over). Caller MUST run rescue-guard.sh assess before trusting it.
#   create  — no existing worktree for issue N; proceed with git worktree add.
#             (An existing *branch* with no worktree is surfaced so the caller
#             checks it out rather than orphaning it / opening a duplicate PR.)
#
# Exit codes (decide):
#   0  — verdict:resume or verdict:create
#   10 — verdict:backoff (another live agent owns it)
#   3  — <repo-root> is not a git repository
#
# UNTRUSTED DATA: worktree paths and branch names come from `git worktree list`
# / `git branch` — they are only ever passed to git as operands and to the
# filesystem as paths, never eval'd, so a hostile branch name cannot execute.

set -uo pipefail

# Claim lease TTL — mirror pr-labels.sh's SGE_*_CLAIM_TTL_MIN (default 30 min).
# A claim younger than this owned by another agent means "live, back off".
RG_WT_CLAIM_TTL_MIN="${SGE_WT_CLAIM_TTL_MIN:-30}"
# Marker file written inside a worktree to lease it. Kept out of git by living
# under .git-adjacent scratch: a plain dotfile at the worktree root, which the
# in-repo `.worktrees/` exception already gitignores and the sibling layout is
# outside any repo tree. Contents: "<agent-id> <epoch-seconds>".
RG_CLAIM_FILE=".sge-wt-claim"

# roc_find_worktree <issue> <repo-root>
# Prints the path of an existing worktree for issue <issue>, or nothing.
# Matches BOTH the canonical sibling `<repo>-worktrees/issue-N` and the
# in-repo team-pipeline `.worktrees/issue-N` — by exact trailing path segment
# `issue-N`, so `issue-12` never matches `issue-123`.
roc_find_worktree() {
  local issue="$1" root="$2"
  git -C "$root" worktree list --porcelain 2>/dev/null \
    | awk -v want="issue-${issue}" '
        /^worktree /  { path = substr($0, 10) }
        /^worktree /  {
          n = split(path, seg, /[\/\\]/)
          if (seg[n] == want) print path
        }'
}

# roc_find_branch <issue> <repo-root>
# Prints the first local branch that targets issue <issue>, or nothing.
# Accepts the no-spec taxonomy (feature|fix|chore) and the plural `feature`
# form, plus a spec-lane branch that names the issue. The issue number must be
# a whole segment (bounded by a non-digit or end) so `issue-1` != `issue-12`.
roc_find_branch() {
  local issue="$1" root="$2"
  git -C "$root" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null \
    | grep -E "^(feat|feature|fix|chore)/(sge-[0-9]+-.*)?issue-${issue}([^0-9]|$)" \
    | head -n1
}

# roc_open_pr <branch> <repo-root>
# Prints the number of an OPEN PR whose head is <branch>, or nothing.
# Prints "unknown" (and returns 2) when gh is unavailable / not authed, so the
# caller can distinguish "no PR" from "could not check".
roc_open_pr() {
  local branch="$1" root="$2"
  [ -n "$branch" ] || return 0
  command -v gh >/dev/null 2>&1 || { echo "unknown"; return 2; }
  local out
  out=$(gh pr list --repo "$(git -C "$root" remote get-url origin 2>/dev/null)" \
          --head "$branch" --state open --json number \
          --jq '.[0].number' 2>/dev/null) || { echo "unknown"; return 2; }
  [ -n "$out" ] && [ "$out" != "null" ] && echo "$out"
}

# roc_claim_state <worktree>
# Reads the claim lease inside <worktree> and classifies it:
#   free        — no claim, or an EXPIRED claim (older than the TTL)
#   mine        — a fresh claim whose agent id == $SGE_AGENT_ID
#   held-fresh  — a fresh claim owned by a DIFFERENT agent (back off)
roc_claim_state() {
  local wt="$1"
  local f="$wt/$RG_CLAIM_FILE"
  [ -f "$f" ] || { echo "free"; return 0; }
  local owner ts now age_min
  read -r owner ts < "$f" 2>/dev/null || { echo "free"; return 0; }
  # A malformed / empty timestamp is treated as expired (fail safe to takeover).
  case "$ts" in ''|*[!0-9]*) echo "free"; return 0 ;; esac
  now=$(date +%s)
  age_min=$(( (now - ts) / 60 ))
  if [ "$age_min" -ge "$RG_WT_CLAIM_TTL_MIN" ]; then
    echo "free"; return 0
  fi
  if [ -n "${SGE_AGENT_ID:-}" ] && [ "$owner" = "$SGE_AGENT_ID" ]; then
    echo "mine"
  else
    echo "held-fresh"
  fi
}

# roc_claim <worktree> — write/refresh THIS agent's claim lease.
roc_claim() {
  local wt="$1"
  [ -d "$wt" ] || return 3
  printf '%s %s\n' "${SGE_AGENT_ID:-unknown}" "$(date +%s)" > "$wt/$RG_CLAIM_FILE"
}

# roc_release <worktree> — drop the claim lease (best effort).
roc_release() {
  local wt="$1"
  rm -f "$wt/$RG_CLAIM_FILE" 2>/dev/null || true
}

# roc_decide <issue> [repo-root] [base-ref] — the single entrypoint.
roc_decide() {
  local issue="$1" root="${2:-$(git rev-parse --show-toplevel 2>/dev/null)}"
  # base-ref ($3) is accepted for signature symmetry with rescue-guard and
  # forwarded by callers; the decision itself does not need it (rescue-guard
  # consumes it on resume).
  if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error:not-a-git-repository" >&2
    return 3
  fi

  local wt branch pr claim verdict note rc=0
  wt=$(roc_find_worktree "$issue" "$root")
  branch=$(roc_find_branch "$issue" "$root")

  if [ -n "$wt" ]; then
    claim=$(roc_claim_state "$wt")
    if [ "$claim" = "held-fresh" ]; then
      verdict="backoff"; rc=10
      note="worktree $wt is claimed by a live agent (< ${RG_WT_CLAIM_TTL_MIN}m); do not steal — report and stop"
    else
      verdict="resume"
      note="reuse existing worktree; run rescue-guard.sh assess before trusting verification (claim:${claim})"
    fi
  else
    claim="free"
    verdict="create"
    if [ -n "$branch" ]; then
      note="no worktree; branch '$branch' exists — check it out (do not open a duplicate PR)"
    else
      note="no worktree or branch for issue ${issue}; create fresh"
    fi
  fi

  # Look up an open PR whenever a branch is known, so resume/create both avoid
  # opening a duplicate. Never let a gh failure change the worktree verdict.
  pr=""
  if [ -n "$branch" ]; then
    pr=$(roc_open_pr "$branch" "$root") || true
  fi

  echo "verdict:${verdict}"
  echo "worktree:${wt:--}"
  echo "branch:${branch:--}"
  echo "open_pr:${pr:--}"
  echo "claim:${claim}"
  echo "note:${note}"
  return "$rc"
}

# CLI dispatch — only when executed directly, never when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"
  case "$cmd" in
    decide)  shift; roc_decide "$@" ;;
    claim)   shift; roc_claim "$@" ;;
    release) shift; roc_release "$@" ;;
    find-worktree) shift; roc_find_worktree "$@" ;;
    find-branch)   shift; roc_find_branch "$@" ;;
    claim-state)   shift; roc_claim_state "$@" ;;
    *)
      echo "usage: resume-or-create.sh {decide|claim|release|find-worktree|find-branch|claim-state} <args>" >&2
      exit 3
      ;;
  esac
fi
