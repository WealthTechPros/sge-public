#!/usr/bin/env bash
# resume-or-create.test.sh — unit tests for resume-or-create.sh (issue #1171).
#
# Self-contained: builds a throwaway git repo + real worktrees in a temp dir,
# exercises roc_find_worktree / roc_find_branch / roc_claim_state / roc_decide,
# and asserts the verdict block. No network (gh open-PR lookup degrades to
# "unknown" and must not change the worktree verdict). Run:
#   bash skills/worktrees/resume-or-create.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/resume-or-create.sh"

fail=0
check() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc"
    echo "       want: [$want]"
    echo "       got : [$got]"
    fail=1
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ROOT="$TMP/repo"
git init -q "$ROOT"
git -C "$ROOT" config user.email t@t.t
git -C "$ROOT" config user.name t
git -C "$ROOT" commit -q --allow-empty -m init
git -C "$ROOT" branch -M main

# --- No worktree, no branch -> create ---
out="$(roc_decide 42 "$ROOT" 2>/dev/null)"
check "no wt/branch -> verdict create" "$(echo "$out" | grep '^verdict:')" "verdict:create"
check "no wt -> worktree:-"            "$(echo "$out" | grep '^worktree:')" "worktree:-"

# --- Branch exists but no worktree -> create, but branch surfaced ---
git -C "$ROOT" branch fix/issue-42
out="$(roc_decide 42 "$ROOT" 2>/dev/null)"
check "branch-only -> verdict create"  "$(echo "$out" | grep '^verdict:')" "verdict:create"
check "branch-only -> branch surfaced" "$(echo "$out" | grep '^branch:')"  "branch:fix/issue-42"

# --- Segment boundary: issue-4 must NOT match issue-42 ---
check "find-branch is segment-exact" "$(roc_find_branch 4 "$ROOT")" ""

# --- Worktree exists (sibling issue-N layout) -> resume ---
WT="$TMP/repo-worktrees/issue-42"
git -C "$ROOT" worktree add -q "$WT" fix/issue-42
# Compare by trailing two segments: git may print C:/… while mktemp yields
# /tmp/… for the same physical dir under MSYS — the path spelling differs but
# the ...-worktrees/issue-42 tail is what the matcher keys on.
tail2() { echo "$1" | awk -F'[/\\\\]' '{ print $(NF-1) "/" $NF }'; }
check "find-worktree locates issue-42" "$(tail2 "$(roc_find_worktree 42 "$ROOT")")" "$(tail2 "$WT")"
check "find-worktree segment-exact"     "$(roc_find_worktree 4 "$ROOT")" ""
out="$(roc_decide 42 "$ROOT" 2>/dev/null)"; rc_resume=$?
check "worktree present -> verdict resume" "$(echo "$out" | grep '^verdict:')" "verdict:resume"
check "resume exit code 0"                 "$rc_resume" "0"
check "resume reports free claim"          "$(echo "$out" | grep '^claim:')"  "claim:free"

# --- Fresh claim by ANOTHER agent -> backoff (exit 10) ---
printf 'other-agent %s\n' "$(date +%s)" > "$WT/.sge-wt-claim"
check "claim-state held-fresh (other agent)" "$(roc_claim_state "$WT")" "held-fresh"
out="$(roc_decide 42 "$ROOT" 2>/dev/null)"; rc_backoff=$?
check "held-fresh -> verdict backoff" "$(echo "$out" | grep '^verdict:')" "verdict:backoff"
check "backoff exit code 10"          "$rc_backoff" "10"

# --- My own fresh claim -> resume (mine), not backoff ---
SGE_AGENT_ID="me" roc_claim "$WT"
check "claim-state mine" "$(SGE_AGENT_ID=me roc_claim_state "$WT")" "mine"
out="$(SGE_AGENT_ID=me roc_decide 42 "$ROOT" 2>/dev/null)"; rc_mine=$?
check "mine -> verdict resume"    "$(echo "$out" | grep '^verdict:')" "verdict:resume"
check "mine resume exit code 0"   "$rc_mine" "0"

# --- Expired claim (older than TTL) -> free -> resume, takeover allowed ---
printf 'other-agent %s\n' "$(( $(date +%s) - 3600 ))" > "$WT/.sge-wt-claim"
check "expired claim -> free" "$(roc_claim_state "$WT")" "free"

# --- Malformed claim timestamp -> free (fail safe) ---
printf 'other-agent notanumber\n' > "$WT/.sge-wt-claim"
check "malformed claim -> free" "$(roc_claim_state "$WT")" "free"

# --- Non-git root -> exit 3 ---
roc_decide 42 "$TMP" >/dev/null 2>&1; check "non-git root exit 3" "$?" "3"

# --- In-repo team-pipeline layout (.worktrees/issue-N) also matches ---
git -C "$ROOT" branch fix/issue-99
IWT="$ROOT/.worktrees/issue-99"
git -C "$ROOT" worktree add -q "$IWT" fix/issue-99
check "find-worktree matches in-repo .worktrees layout" "$(tail2 "$(roc_find_worktree 99 "$ROOT")")" "$(tail2 "$IWT")"

# --- Purpose-scoped worktrees (issue #2214): pr-review-<PR> / pr-fix-<PR> /
# qa-<PR> share the SAME claim-lease machinery as issue-<N>, so a reviewer and
# a fixer working the same PR number in different purpose lanes never collide,
# and two agents in the SAME purpose lane (e.g. two reviewers on one PR) are
# mutex'd exactly like the issue-worktree case above.
git -C "$ROOT" branch fix/pr812
RWT="$TMP/repo-worktrees/pr-review-812"
git -C "$ROOT" worktree add -q "$RWT" fix/pr812
check "find-worktree(purpose=pr-review) locates pr-review-812" \
  "$(tail2 "$(roc_find_worktree 812 "$ROOT" pr-review)")" "$(tail2 "$RWT")"
check "find-worktree(purpose=pr-review) segment-exact vs pr-review-8" \
  "$(roc_find_worktree 8 "$ROOT" pr-review)" ""
check "find-worktree(purpose=issue) does NOT match a pr-review worktree" \
  "$(roc_find_worktree 812 "$ROOT" issue)" ""

out="$(roc_decide 812 "$ROOT" "" pr-review 2>/dev/null)"; rc_pr_resume=$?
check "pr-review purpose: worktree present -> verdict resume" \
  "$(echo "$out" | grep '^verdict:')" "verdict:resume"
check "pr-review purpose: resume exit code 0" "$rc_pr_resume" "0"

# A DIFFERENT purpose lane on the SAME id (pr-fix-812) is independent — no
# worktree found there yet, so it is a fresh 'create', never blocked by the
# pr-review lane's claim. This is the fix for incident #1 (#2214): two agents
# in different purpose lanes on the same PR no longer fight over one worktree.
out="$(roc_decide 812 "$ROOT" "" pr-fix 2>/dev/null)"
check "pr-fix purpose on same id is independent of pr-review -> verdict create" \
  "$(echo "$out" | grep '^verdict:')" "verdict:create"

# Fresh claim by another agent on the pr-review worktree -> backoff, same as issue-N.
printf 'other-agent %s\n' "$(date +%s)" > "$RWT/.sge-wt-claim"
out="$(roc_decide 812 "$ROOT" "" pr-review 2>/dev/null)"; rc_pr_backoff=$?
check "pr-review purpose: held-fresh -> verdict backoff" \
  "$(echo "$out" | grep '^verdict:')" "verdict:backoff"
check "pr-review purpose: backoff exit code 10" "$rc_pr_backoff" "10"

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"
