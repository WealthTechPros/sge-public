#!/usr/bin/env bash
# resume-or-create.sh — search-before-create for purpose-scoped worktrees
# (issue #1171; generalised beyond `issue-<N>` to any worktree purpose token
# — `pr-review-<N>`, `pr-fix-<N>`, `qa-<N>` — under issue #2214).
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
# Issue #2214 — the same collision happens one layer up, at PR granularity:
# a `/sge:pr-review` lane and a `/sge:pr-fix` lane (or two concurrent review
# lanes) landing on the SAME PR's worktree with no claim check is exactly how
# a `git stash -u`/`pop` cycle briefly swallowed one agent's uncommitted work
# under another's feet. Every purpose token from the canonical layout
# (`worktrees/SKILL.md`) — `pr-review`, `pr-fix`, `qa` — now goes through the
# SAME claim-lease machinery as `issue`, keyed by that PR/issue number *within*
# its own purpose lane: `pr-review-812` and `pr-fix-812` are independent lanes
# (an implementer rewriting the branch under `pr-fix-812` does not block a
# `pr-review-812` worktree from existing), but two agents both wanting
# `pr-review-812` mutex exactly like two agents wanting `issue-42` do.
#
# It is a decision helper only. It does NOT create, remove, rebase, or install
# anything (that is the calling skill's Phase 3, plus the mandatory
# rescue-guard.sh on resume). It reads git state and prints a machine-readable
# verdict block; the caller acts on it.
#
# Usage — invoke a subcommand (CLI form), or source for the predicates:
#   bash resume-or-create.sh decide <id> [repo-root] [base-ref] [purpose]
#   bash resume-or-create.sh claim  <worktree>        # write/refresh a claim lease
#   bash resume-or-create.sh release <worktree>       # drop the claim lease
#
#   source resume-or-create.sh
#   roc_find_worktree <id> <repo-root> [purpose]   # prints worktree path or empty
#   roc_find_branch   <id> <repo-root>              # prints branch name or empty (issue purpose only)
#   roc_claim_state   <worktree>                    # prints free | mine | held-fresh
#
# `purpose` defaults to `issue` (backward compatible with every existing call
# site). Pass `pr-review` / `pr-fix` / `qa` to target that lane's worktree
# instead — the trailing path segment matched is `<purpose>-<id>`, exactly the
# canonical layout in `worktrees/SKILL.md`.
#
# `decide` prints (stdout), one key:value per line:
#   verdict:resume | create | backoff
#   worktree:<path|->            # existing worktree to resume, or - when none
#   branch:<name|->              # existing issue branch, or - when none (issue purpose only)
#   open_pr:<number|->           # existing OPEN PR for the branch, or - / unknown
#   claim:free | mine | held-fresh
#   note:<human-readable one-liner>
#
# Verdict rules:
#   backoff — an existing worktree carries a FRESH claim lease owned by ANOTHER
#             live agent (younger than SGE_WT_CLAIM_TTL_MIN, default 30 min, and
#             not this agent's SGE_AGENT_ID). Do NOT steal it; report and stop.
#   resume  — an existing worktree for <purpose>-<id> is found and is not
#             another-agent-fresh-claimed (free, mine, or stale claim to take
#             over). Caller MUST run rescue-guard.sh assess before trusting it.
#   create  — no existing worktree for <purpose>-<id>; proceed with git worktree add.
#             (An existing *branch* with no worktree is surfaced so the caller
#             checks it out rather than orphaning it / opening a duplicate PR —
#             issue-purpose only; PR-scoped purposes never guess a branch name.)
#
# Exit codes (decide):
#   0  — verdict:resume or verdict:create
#   10 — verdict:backoff (another live agent owns it)
#   3  — <repo-root> is not a git repository
#
# decide-ref <ref> [repo-root] and associate <worktree> <ref> (SPEC-143, #3614)
# resolve a host-qualified task reference instead of an issue number; see the
# SPEC-143 section below. decide-ref adds verdict:reconcile (exit 11) and exits
# 2 on an invalid reference.
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
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lease-lock.sh"
RG_CLAIM_MAX_BYTES=4096

# roc_find_worktree <id> <repo-root> [purpose=issue]
# Prints the path of an existing worktree for <purpose>-<id>, or nothing.
# Matches BOTH the canonical sibling `<repo>-worktrees/<purpose>-N` and the
# in-repo team-pipeline `.worktrees/<purpose>-N` — by exact trailing path
# segment `<purpose>-N`, so `issue-12` never matches `issue-123`, and
# `pr-review-812` never matches `pr-fix-812` (different purpose, same id —
# issue #2214: those are independent lanes, not the same claim).
roc_find_worktree() {
  local id="$1" root="$2" purpose="${3:-issue}"
  git -C "$root" worktree list --porcelain 2>/dev/null \
    | awk -v want="${purpose}-${id}" '
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
  roc_find_branches "$1" "$2" | head -n1
}

# roc_find_branches <issue> <repo-root> — every local branch roc_find_branch
# would accept, one per line. decide-ref uses it so two issue-<N> branches are
# reconciled, never resumed as one (SPEC-143).
roc_find_branches() {
  local issue="$1" root="$2"
  git -C "$root" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null \
    | grep -E "^(feat|feature|fix|chore)/(sge-[0-9]+-.*)?issue-${issue}([^0-9]|$)"
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
#   held-fresh  — a fresh foreign claim or an invalid record (back off)
roc_claim_state() {
  local wt="$1"
  local f="$wt/$RG_CLAIM_FILE"
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then echo "free"; return 0; fi
  local LC_ALL=C owner ts now age_sec size record
  local shape=$'^([^[:space:]]+) (0|[1-9][0-9]{0,9})\n$'
  if [ -L "$f" ] || [ ! -f "$f" ]; then echo "held-fresh"; return 0; fi
  size=$(wc -c <"$f" 2>/dev/null) || { echo "held-fresh"; return 0; }
  [ "$size" -le "$RG_CLAIM_MAX_BYTES" ] || { echo "held-fresh"; return 0; }
  record="$(cat "$f" 2>/dev/null && printf x)" || { echo "held-fresh"; return 0; }
  record="${record%x}"
  # Bash drops NUL bytes in command substitution. Protect records it could not read byte for byte.
  [ "${#record}" -eq "$size" ] || { echo "held-fresh"; return 0; }
  [[ "$record" =~ $shape ]] || { echo "held-fresh"; return 0; }
  owner="${BASH_REMATCH[1]}"
  ts="${BASH_REMATCH[2]}"
  now=$(date +%s) || { echo "held-fresh"; return 0; }
  age_sec=$((now - ts))
  # Use the earlier of the written timestamp and the file mtime throughout the
  # lease. A skewed writer's expired record must never become fresh again.
  local file_age
  file_age="$(_sge_lease_age "$f")" || { echo "held-fresh"; return 0; }
  if [ "$file_age" -gt "$age_sec" ]; then age_sec="$file_age"; fi
  if [ "$((age_sec / 60))" -ge "$RG_WT_CLAIM_TTL_MIN" ]; then
    echo "free"; return 0
  fi
  if [ -n "${SGE_AGENT_ID:-}" ] && [ "$owner" = "$SGE_AGENT_ID" ]; then
    echo "mine"
  else
    echo "held-fresh"
  fi
}

# roc_claim <worktree> — write/refresh THIS agent's claim lease.
# An atomic check-and-claim (sge#3697): under the shared lease lock it refuses a
# FRESH lease of another agent (exit 10, lease untouched) and otherwise writes
# this agent's. Exit 4 when the lock stays busy; nothing is written then. A
# directory that is not a git checkout has no lock to take and is written as before.
roc_claim() {
  local wt="$1" rc=0 claim tmp epoch
  local LC_ALL=C owner="${SGE_AGENT_ID:-unknown}"
  [ -d "$wt" ] || return 3
  sge_lease_lock "$wt"; rc=$?
  [ "$rc" -ne 1 ] || { echo "roc_claim: lease lock busy for $wt" >&2; return 4; }
  if [ "$(roc_claim_state "$wt")" = held-fresh ]; then
    sge_lease_unlock
    echo "roc_claim: $wt holds a foreign or invalid lease; left intact" >&2
    return 10
  fi
  claim="$wt/$RG_CLAIM_FILE"
  epoch="$(date +%s)" || { sge_lease_unlock; return 1; }
  # Count bytes, including the space and final newline, as the lease reader does.
  if [[ "$owner" = *[[:space:]]* ]] || (( ${#owner} + ${#epoch} + 2 > RG_CLAIM_MAX_BYTES )); then
    sge_lease_unlock
    echo "roc_claim: owner cannot be stored in a valid lease record" >&2
    return 1
  fi
  tmp="$(mktemp "$claim.tmp.XXXXXX")" || { sge_lease_unlock; return 1; }
  printf '%s %s\n' "$owner" "$epoch" >"$tmp" && mv -f -- "$tmp" "$claim"
  rc=$?
  if [ "$rc" -ne 0 ]; then rm -f -- "$tmp"; fi
  sge_lease_unlock
  return "$rc"
}

# roc_release <worktree> — drop this agent's live claim (best effort).
roc_release() {
  local wt="$1"
  [ -n "${SGE_AGENT_ID:-}" ] || return 0
  sge_lease_lock "$wt" || return 0
  if [ "$(roc_claim_state "$wt")" = mine ]; then
    rm -f "$wt/$RG_CLAIM_FILE" 2>/dev/null || true
  fi
  sge_lease_unlock
}

# roc_decide <id> [repo-root] [base-ref] [purpose=issue] — the single entrypoint.
# purpose=issue additionally resolves a branch (issue-N naming convention);
# any other purpose (pr-review/pr-fix/qa, issue #2214) is worktree-only — the
# branch for a PR-scoped lane is the PR's own head branch, already known to
# the caller (gh pr checkout), so this helper never guesses one.
roc_decide() {
  local issue="$1" root="${2:-$(git rev-parse --show-toplevel 2>/dev/null)}"
  local purpose="${4:-issue}"
  # base-ref ($3) is accepted for signature symmetry with rescue-guard and
  # forwarded by callers; the decision itself does not need it (rescue-guard
  # consumes it on resume).
  if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error:not-a-git-repository" >&2
    return 3
  fi

  local wt branch pr claim verdict note rc=0
  wt=$(roc_find_worktree "$issue" "$root" "$purpose")
  if [ "$purpose" = "issue" ]; then
    branch=$(roc_find_branch "$issue" "$root")
  else
    branch=""
  fi

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
      note="no worktree or branch for ${purpose}-${issue}; create fresh"
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

# ── SPEC-143 (#3614): resume by host-qualified task identity ─────────────────
# A task reference names the task on its host: github:issue/<N>, github:pr/<N>,
# azdo:wi/<N> or azdo:pr/<N>. `associate` records one against a worktree's
# branch (git config branch.<b>.sgeTask: shared by every worktree, one value per
# branch, outside the working tree). `decide-ref` resolves a reference to its
# exact branch and worktree from that record, an exact read-only host lookup
# and, for issue/work-item references, the issue-<N> matchers above. Missing or
# ambiguous evidence answers `reconcile` (exit 11), never `create`. It lists
# candidate stashes and changes nothing. Test seams: SGE_ROC_GH,
# SGE_ROC_LINKED_PRS, SGE_ROC_AZDO_ADAPTER.
_ROC_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"

# roc_parse_ref <ref> -> ROC_HOST ROC_KIND ROC_NUM; 2 when it is not one.
roc_parse_ref() {
  case "$1" in
    github:issue/*|github:pr/*|azdo:wi/*|azdo:pr/*) ;;
    *) return 2 ;;
  esac
  ROC_HOST="${1%%:*}"; ROC_KIND="${1#*:}"; ROC_NUM="${ROC_KIND#*/}"; ROC_KIND="${ROC_KIND%%/*}"
  case "$ROC_NUM" in ''|*[!0-9]*) return 2 ;; esac
  [ "$ROC_NUM" -gt 0 ] 2>/dev/null || return 2
}

# roc_associate <worktree> <ref> — record <ref> against the worktree's branch.
roc_associate() {
  local wt="$1" ref="$2" b
  roc_parse_ref "$ref" || { echo "error:invalid-task-ref" >&2; return 2; }
  b="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" \
    || { echo "error:worktree-has-no-branch" >&2; return 3; }
  git -C "$wt" config "branch.$b.sgeTask" "$ref"
}

# roc_branch_worktree <branch> <repo-root> — the worktree that has it checked out.
roc_branch_worktree() {
  git -C "$2" worktree list --porcelain 2>/dev/null | awk -v want="branch refs/heads/$1" '
    /^worktree / { path = substr($0, 10) }
    $0 == want  { print path; exit }'
}

# roc_host_branches <repo-root> — branch names the host gives for the parsed
# reference, one per line. Exit 1 = the lookup failed or is incomplete.
roc_host_branches() {
  local root="$1" gh="${SGE_ROC_GH:-gh}" origin out
  local lp="${SGE_ROC_LINKED_PRS:-$_ROC_ROOT_DIR/scripts/linked-prs.sh}"
  local az="${SGE_ROC_AZDO_ADAPTER:-$_ROC_ROOT_DIR/scripts/azdo-adapter.sh}"
  command -v jq >/dev/null 2>&1 || return 1
  case "$ROC_HOST:$ROC_KIND" in
    github:pr)
      # A fork PR's head branch (often `main`) names no branch of THIS repo, so
      # only a same-repository PR yields a candidate; a fork or an unconfirmed
      # source is unknown -> reconcile (CodeRabbit on #3653).
      out="$(cd "$root" && "$gh" pr view "$ROC_NUM" --json headRefName,isCrossRepository 2>/dev/null)" || return 1
      out="$(printf '%s' "$out" | jq -er 'if type == "object" and .isCrossRepository == false
          and (.headRefName | type == "string" and length > 0) then .headRefName else error("fork or unknown source") end' 2>/dev/null)" || return 1
      out="${out%$'\r'}"; [ -n "$out" ] || return 1; printf '%s\n' "$out" ;;
    github:issue)
      local rc=0
      # --complete: a search that reached its --limit exits 2 (unknown), so a
      # PR the cap left out can never turn reconcile into create.
      out="$(cd "$root" && "$lp" "$ROC_NUM" --state all --complete 2>/dev/null)" || rc=$?
      [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || return 1
      printf '%s' "${out:-[]}" | jq -er 'if type == "array" then .[] | .headRefName // error("no branch") else error("not an array") end' 2>/dev/null | tr -d '\r' \
        || { [ "$rc" -eq 1 ] && return 0; return 1; } ;;
    azdo:pr|azdo:wi)
      origin="$(git -C "$root" remote get-url origin 2>/dev/null)" || return 1
      if [ "$ROC_KIND" = pr ]; then
        out="$(bash "$az" get-pr "$origin" "$ROC_NUM" 2>/dev/null)" || return 1
        out="$(printf '%s' "$out" | jq -er '.headRefName | select(type == "string" and length > 0)' 2>/dev/null)" || return 1
        printf '%s\n' "${out%$'\r'}"
      else
        # Pass the origin: the adapter then looks the item up in the origin's
        # org (a different SGE_AZDO_ORG is refused) and keeps only PRs of this
        # repository, so a same-named branch from another repo is not offered.
        out="$(bash "$az" item-linked-prs "$ROC_NUM" "$origin" 2>/dev/null)" || return 1
        # Every linked PR must name its source branch; one that does not is
        # incomplete evidence, not "no branch".
        printf '%s' "$out" | jq -r 'if type == "array" then .[] | .headRefName
            | if type == "string" and length > 0 then . else error("no branch") end
          else error("not an array") end' 2>/dev/null | tr -d '\r'
      fi ;;
    *) return 1 ;;
  esac
}

# roc_decide_ref <ref> [repo-root] — see the header of this section.
roc_decide_ref() {
  local ref="$1" root="${2:-$(git rev-parse --show-toplevel 2>/dev/null)}"
  roc_parse_ref "$ref" || { echo "error:invalid-task-ref (want github:issue/N, github:pr/N, azdo:wi/N or azdo:pr/N)" >&2; return 2; }
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error:not-a-git-repository" >&2; return 3; }
  local lookup=ok b wt hosted cands="" nl=$'\n' n=0 verdict note claim=free rc=0 one_b="" one_wt="" st task conflict=""
  # 1. Recorded associations.
  local recorded
  recorded="$(git -C "$root" config --get-regexp '^branch\..*\.sgetask$' 2>/dev/null \
    | awk -v r="$ref" '$2 == r { k = $1; sub(/^branch\./, "", k); sub(/\.sgetask$/, "", k); print k }')"
  # 2. Exact host lookup.
  hosted="$(roc_host_branches "$root")" || lookup=unknown
  # 3. The issue-<N> matchers (issue and work-item references).
  local legacy="" lwt=""
  if [ "$ROC_KIND" = issue ] || [ "$ROC_KIND" = wi ]; then
    legacy="$(roc_find_branches "$ROC_NUM" "$root")"
    # Every issue-<N> worktree, one by one: two of them must reconcile.
    while IFS= read -r lwt; do
      [ -n "$lwt" ] || continue
      legacy="$legacy$nl$(git -C "$lwt" symbolic-ref -q --short HEAD 2>/dev/null)"
    done <<EOF
$(roc_find_worktree "$ROC_NUM" "$root" issue)
EOF
  fi
  # Local branches only, de-duplicated.
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    git -C "$root" show-ref --verify --quiet "refs/heads/$b" || continue
    case "$nl$cands$nl" in *"$nl$b$nl"*) continue ;; esac
    cands="$cands$b$nl"; n=$((n + 1))
    # A candidate already recorded for a DIFFERENT task (e.g. fix/issue-42
    # recorded as github:issue/42 while resolving azdo:wi/42) is conflicting
    # evidence: reconcile, never resume it as this task.
    task="$(git -C "$root" config --get "branch.$b.sgeTask" 2>/dev/null)"
    if [ -n "$task" ] && [ "$task" != "$ref" ]; then conflict="$conflict $b=$task"; fi
  done <<EOF
$recorded
$hosted
$legacy
EOF
  echo "ref:$ref"
  echo "lookup:$lookup"
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    wt="$(roc_branch_worktree "$b" "$root")"
    if [ -z "$wt" ]; then st=no-worktree
    elif [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then st=clean
    else st=dirty; fi
    printf 'candidate:%s\t%s\t%s\t%s\n' "${wt:--}" "$b" "$(git -C "$root" rev-parse -q --verify "refs/heads/$b")" "$st"
    one_b="$b"; one_wt="$wt"
  done <<EOF
$cands
EOF
  # Stashes made on a candidate branch: listed, never applied.
  git -C "$root" stash list --format='%gd%x09%gs' 2>/dev/null | while IFS="$(printf '\t')" read -r sref subj; do
    subj="${subj#WIP on }"; subj="${subj#On }"; b="${subj%%:*}"
    case "$nl$cands" in *"$nl$b$nl"*) printf 'stash:%s\t%s\n' "$sref" "$b" ;; esac
  done
  if [ "$lookup" = unknown ]; then
    verdict=reconcile; rc=11; one_b=""; one_wt=""
    note="the host lookup for $ref failed or was incomplete; reconcile the candidates by hand (no prior work is NOT established)"
  elif [ "$n" -gt 1 ]; then
    verdict=reconcile; rc=11; one_b=""; one_wt=""
    note="$n branches resolve to $ref; reconcile them by hand before continuing"
  elif [ -n "$conflict" ]; then
    verdict=reconcile; rc=11; one_b=""; one_wt=""
    note="a matching branch is recorded for another task (${conflict# }); reconcile by hand before continuing"
  elif [ "$n" -eq 1 ] && [ -n "$one_wt" ]; then
    claim="$(roc_claim_state "$one_wt")"
    if [ "$claim" = held-fresh ]; then
      verdict=backoff; rc=10; note="worktree $one_wt is claimed by a live agent; do not steal — report and stop"
    else
      verdict=resume; note="reuse existing worktree; run rescue-guard.sh assess before trusting verification (claim:${claim})"
    fi
  elif [ "$n" -eq 1 ]; then
    verdict=resume; note="branch '$one_b' holds the work but has no worktree — add a worktree for it (do not create a new branch)"
  else
    verdict=create; note="no branch or worktree resolves to $ref; create fresh"
  fi
  echo "verdict:$verdict"
  echo "worktree:${one_wt:--}"
  echo "branch:${one_b:--}"
  echo "open_pr:-"
  echo "claim:$claim"
  echo "note:$note"
  return "$rc"
}

# CLI dispatch — only when executed directly, never when sourced.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"
  case "$cmd" in
    decide)  shift; roc_decide "$@" ;;
    decide-ref) shift; roc_decide_ref "$@" ;;
    associate)  shift; roc_associate "$@" ;;
    claim)   shift; roc_claim "$@" ;;
    release) shift; roc_release "$@" ;;
    find-worktree) shift; roc_find_worktree "$@" ;;
    find-branch)   shift; roc_find_branch "$@" ;;
    claim-state)   shift; roc_claim_state "$@" ;;
    *)
      echo "usage: resume-or-create.sh {decide|decide-ref|associate|claim|release|find-worktree|find-branch|claim-state} <args>" >&2
      exit 3
      ;;
  esac
fi
