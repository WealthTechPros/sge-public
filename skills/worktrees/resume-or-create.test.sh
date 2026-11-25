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
# (the other agent's fresh lease is released first: roc_claim never steals it, sge#3697)
rm -f "$WT/.sge-wt-claim"
epoch=$(date +%s)
limit_owner=$(printf '%0*d' "$((4096 - 2 - ${#epoch}))" 0)
SGE_AGENT_ID="${limit_owner}x" roc_claim "$WT" 2>/dev/null
check "oversize owner rejected" "$?" "1"
check "rejected owner leaves no lease" "$([ -e "$WT/.sge-wt-claim" ] && echo present || echo absent)" "absent"
SGE_AGENT_ID="$limit_owner" roc_claim "$WT"
check "maximum-size lease is readable" "$(SGE_AGENT_ID="$limit_owner" roc_claim_state "$WT")" "mine"
SGE_AGENT_ID="$limit_owner" roc_release "$WT"
SGE_AGENT_ID="me" roc_claim "$WT"
check "claim-state mine" "$(SGE_AGENT_ID=me roc_claim_state "$WT")" "mine"
out="$(SGE_AGENT_ID=me roc_decide 42 "$ROOT" 2>/dev/null)"; rc_mine=$?
check "mine -> verdict resume"    "$(echo "$out" | grep '^verdict:')" "verdict:resume"
check "mine resume exit code 0"   "$rc_mine" "0"

# --- sge#3697: roc_claim is an atomic check-and-claim under the shared lease lock ---
printf 'other-agent %s
' "$(date +%s)" > "$WT/.sge-wt-claim"
SGE_AGENT_ID="me" roc_claim "$WT" 2>/dev/null; rc_steal=$?
check "roc_claim refuses a fresh foreign lease (rc 10)" "$rc_steal" "10"
check "roc_claim leaves the fresh foreign lease in place" "$(cut -d' ' -f1 "$WT/.sge-wt-claim")" "other-agent"
LOCK="$(git -C "$WT" rev-parse --absolute-git-dir)/sge-wt-claim.lock"
printf 'other-agent %s
' "$(( $(date +%s) - 3600 ))" > "$WT/.sge-wt-claim"
mkdir "$LOCK"
SGE_LEASE_LOCK_WAIT_DS=1 SGE_AGENT_ID="me" roc_claim "$WT" 2>/dev/null; rc_busy=$?
check "roc_claim fails while another holder has the lease lock (rc 4)" "$rc_busy" "4"
check "roc_claim wrote nothing while locked out" "$(cut -d' ' -f1 "$WT/.sge-wt-claim")" "other-agent"
rmdir "$LOCK"
SGE_AGENT_ID="me" roc_claim "$WT"; rc_take=$?
check "roc_claim takes over an expired lease" "$rc_take:$(cut -d' ' -f1 "$WT/.sge-wt-claim")" "0:me"
check "roc_claim releases the lease lock" "$([ -e "$LOCK" ] && echo held || echo released)" "released"
mkdir "$LOCK"; touch -d '@1' "$LOCK" 2>/dev/null || touch -t 197001010000 "$LOCK"
SGE_LEASE_LOCK_WAIT_DS=1 SGE_AGENT_ID="me" roc_claim "$WT"; rc_stale=$?
check "a lock untouched past SGE_LEASE_LOCK_STALE_S is a crashed holder's and is broken" "$rc_stale" "0"
mkdir "$LOCK"; touch "$LOCK/x"; touch -d '@1' "$LOCK" 2>/dev/null || touch -t 197001010000 "$LOCK"
SGE_LEASE_LOCK_WAIT_DS=1 SGE_AGENT_ID="me" timeout 20 bash -c 'source "$1"; roc_claim "$2"' _ "$HERE/resume-or-create.sh" "$WT" 2>/dev/null; rc_stuck=$?
check "a stale lock that cannot be removed still ends at the wait limit (rc 4, no spin)" "$rc_stuck" "4"
rm -rf "$LOCK"
# CodeRabbit on #3701: the protocol only ever removes the lock instance it judged
# stale (re-checked under "$LOCK.break") or the one this shell holds (its token).
mkdir "$LOCK"; touch -d '@1' "$LOCK" 2>/dev/null || touch -t 197001010000 "$LOCK"
mkdir "$LOCK.break"
SGE_LEASE_LOCK_WAIT_DS=1 SGE_AGENT_ID="me" roc_claim "$WT" 2>/dev/null; rc_brk=$?
check "a stale lock another contender is mid-reclaim on is left to it (rc 4)" "$rc_brk:$([ -d "$LOCK" ] && echo lock-kept)" "4:lock-kept"
touch -d '@1' "$LOCK.break" 2>/dev/null || touch -t 197001010000 "$LOCK.break"
SGE_LEASE_LOCK_WAIT_DS=3 SGE_AGENT_ID="me" roc_claim "$WT" 2>/dev/null; rc_brk2=$?
check "a crashed reclaimer's break lock does not pin the lock forever" "$rc_brk2:$([ -e "$LOCK" ] || [ -e "$LOCK.break" ] && echo left || echo clean)" "0:clean"
( sge_lease_lock "$WT"; rm -rf "$LOCK"; mkdir "$LOCK"; sge_lease_unlock )
check "unlock never removes a replacement lock taken after ours was broken" "$([ -d "$LOCK" ] && echo kept || echo removed)" "kept"
rmdir "$LOCK"
( sge_lease_lock "$WT"; rm -rf "$LOCK"; sge_lease_touch )
check "touch never recreates a lock path this shell no longer holds" "$([ -e "$LOCK" ] && echo created || echo absent)" "absent"
check "lease lock lives outside the work tree" "$(git -C "$WT" status --porcelain --ignored | grep -c 'sge-wt-claim.lock')" "0"

# --- Expired claim (older than TTL) -> free -> resume, takeover allowed ---
printf 'other-agent %s\n' "$(( $(date +%s) - 3600 ))" > "$WT/.sge-wt-claim"
check "expired claim -> free" "$(roc_claim_state "$WT")" "free"

# --- Invalid claim records require manual reconciliation ---
printf 'other-agent notanumber\n' > "$WT/.sge-wt-claim"
check "invalid claim remains protected" "$(roc_claim_state "$WT")" "held-fresh"
printf 'other-agent %s\0\n' "$(( $(date +%s) - 3600 ))" >"$WT/.sge-wt-claim"
check "binary corruption in a lease remains protected" "$(roc_claim_state "$WT" 2>/dev/null)" "held-fresh"

# A clock ahead of the local host must not pin an abandoned claim forever.
printf 'other-agent %s\n' "$(( $(date +%s) + 3600 ))" > "$WT/.sge-wt-claim"
check "a recently written claim from an ahead clock stays protected" "$(roc_claim_state "$WT")" "held-fresh"
touch -d '1 hour ago' "$WT/.sge-wt-claim"
check "an aged claim from an ahead clock expires by file age" "$(roc_claim_state "$WT")" "free"

# An unchanged expired claim stays free when the clock reaches its recorded timestamp.
(
  date() { printf '%s\n' "$clock_now"; }
  claim="$WT/.sge-wt-claim"
  printf 'other-agent 1800003600\n' >"$claim"
  touch -d '@1799996400' "$claim"
  clock_now=1800000000
  before="$(roc_claim_state "$WT")"
  clock_now=1800003600
  printf '%s:%s\n' "$before" "$(roc_claim_state "$WT")" >"$TMP/clock-transition"
)
check "an expired claim stays free across the writer timestamp" "$(cat "$TMP/clock-transition")" "free:free"

previous="other-agent $(( $(date +%s) - 3600 ))"
printf '%s\n' "$previous" >"$WT/.sge-wt-claim"
(mv() { return 1; }; SGE_AGENT_ID=me roc_claim "$WT" 2>/dev/null); rc=$?
check "failed claim replacement retains the previous lease" "$rc:$(cat "$WT/.sge-wt-claim")" "1:$previous"

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

# --- SPEC-143 (#3614): resume by host-qualified task identity ---------------
# Stubbed host seams: gh, linked-prs.sh and azdo-adapter.sh read canned answers
# from $STUB; "$STUB/fail" makes every lookup fail (auth, timeout, truncation).
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'EOS'
#!/usr/bin/env bash
[ -e "$STUB/fail" ] && { echo "gh: not authenticated" >&2; exit 1; }
# gh pr view <N> --json headRefName,isCrossRepository
[ "$1 $2" = "pr view" ] && [ -f "$STUB/gh-pr-$3" ] && { cat "$STUB/gh-pr-$3"; exit 0; }
echo "no pull requests found" >&2; exit 1
EOS
cat > "$STUB/linked-prs" <<'EOS'
#!/usr/bin/env bash
echo "$*" > "$STUB/linked-args"
[ -e "$STUB/fail" ] && exit 2
[ -f "$STUB/linked-$1" ] && { cat "$STUB/linked-$1"; exit 0; }
echo '[]'; exit 1
EOS
cat > "$STUB/azdo" <<'EOS'
#!/usr/bin/env bash
[ -e "$STUB/fail" ] && { echo "azdo-adapter: error: 401" >&2; exit 1; }
case "$1" in
  get-pr) [ -f "$STUB/azpr-$3" ] && { cat "$STUB/azpr-$3"; exit 0; }; exit 1 ;;
  item-linked-prs) echo "$*" > "$STUB/azdo-args"
    [ -f "$STUB/wi-$2" ] && { cat "$STUB/wi-$2"; exit 0; }; echo '[]'; exit 0 ;;
esac
exit 1
EOS
chmod +x "$STUB/gh" "$STUB/linked-prs" "$STUB/azdo"
export STUB SGE_ROC_GH="$STUB/gh" SGE_ROC_LINKED_PRS="$STUB/linked-prs" SGE_ROC_AZDO_ADAPTER="$STUB/azdo"
git -C "$ROOT" remote add origin https://dev.azure.com/o/p/_git/r
rm -f "$WT/.sge-wt-claim" "$RWT/.sge-wt-claim"
field() { grep "^$2:" <<<"$1" | head -n1; }

# @invalid ref -> exit 2
bash "$HERE/resume-or-create.sh" decide-ref 'azdo:wi/1;rm' "$ROOT" >/dev/null 2>&1; check "invalid ref -> exit 2" "$?" "2"
bash "$HERE/resume-or-create.sh" decide-ref 'github:wi/1' "$ROOT" >/dev/null 2>&1; check "github has no wi refs -> exit 2" "$?" "2"

# @recorded-association: a guidance-* worktree associated with azdo:wi/812
git -C "$ROOT" branch guidance-tone
GWT="$TMP/repo-worktrees/guidance-tone"
git -C "$ROOT" worktree add -q "$GWT" guidance-tone
check "decide 812 alone still misses it (legacy path)" "$(field "$(roc_decide 812 "$ROOT" 2>/dev/null)" verdict)" "verdict:create"
bash "$HERE/resume-or-create.sh" associate "$GWT" azdo:wi/812; check "associate exit 0" "$?" "0"
check "association is recorded in git config" "$(git -C "$ROOT" config --get branch.guidance-tone.sgeTask)" "azdo:wi/812"
out="$(roc_decide_ref azdo:wi/812 "$ROOT" 2>/dev/null)"; rc=$?
check "recorded association -> resume" "$(field "$out" verdict)" "verdict:resume"
check "recorded association -> exit 0" "$rc" "0"
check "recorded association -> its branch" "$(field "$out" branch)" "branch:guidance-tone"
check "recorded association -> its worktree" "$(tail2 "$(field "$out" worktree)")" "$(tail2 "$GWT")"
check "recorded association -> lookup ok" "$(field "$out" lookup)" "lookup:ok"

# @host-lookup: completed Azure Repos PR whose source branch has no number
git -C "$ROOT" branch polish-copy
echo '[{"id":77,"status":"completed","closedDate":"2026-11-01T00:00:00Z","headRefName":"polish-copy"}]' > "$STUB/wi-4985"
out="$(roc_decide_ref azdo:wi/4985 "$ROOT" 2>/dev/null)"; rc=$?
check "completed azdo PR -> not create" "$(field "$out" verdict)" "verdict:resume"
check "completed azdo PR -> branch-only candidate" "$(field "$out" worktree)" "worktree:-"
check "completed azdo PR -> its source branch" "$(field "$out" branch)" "branch:polish-copy"
echo '{"number":78,"headRefName":"polish-copy","state":"MERGED"}' > "$STUB/azpr-78"
check "azdo:pr ref -> its source branch" "$(field "$(roc_decide_ref azdo:pr/78 "$ROOT" 2>/dev/null)" branch)" "branch:polish-copy"
# A work item whose linked PR has no source branch field is unknown evidence.
echo '[{"id":79,"status":"completed","closedDate":""}]' > "$STUB/wi-5000"
out="$(roc_decide_ref azdo:wi/5000 "$ROOT" 2>/dev/null)"; rc=$?
check "linked PR without a source branch -> reconcile" "$(field "$out" verdict)" "verdict:reconcile"

check "work-item lookup is bound to this repo's origin" "$(cat "$STUB/azdo-args")" "item-linked-prs 5000 https://dev.azure.com/o/p/_git/r"

# @github-pr
git -C "$ROOT" branch tidy-readme
printf '{"headRefName":"tidy-readme","isCrossRepository":false}\n' > "$STUB/gh-pr-501"
out="$(roc_decide_ref github:pr/501 "$ROOT" 2>/dev/null)"
check "github:pr -> head branch candidate" "$(field "$out" branch)" "branch:tidy-readme"
check "github:pr -> resume" "$(field "$out" verdict)" "verdict:resume"
# A fork PR's head branch names no branch here (CodeRabbit on #3653): its
# `tidy-readme` must not resume ours; a fork or unknown source reconciles.
printf '{"headRefName":"tidy-readme","isCrossRepository":true}\n' > "$STUB/gh-pr-502"
out="$(roc_decide_ref github:pr/502 "$ROOT" 2>/dev/null)"; rc=$?
check "github:pr from a fork -> reconcile" "$(field "$out" verdict)" "verdict:reconcile"
check "github:pr from a fork -> exit 11" "$rc" "11"
printf '{"headRefName":"tidy-readme"}\n' > "$STUB/gh-pr-503"
check "github:pr with an unconfirmed source -> reconcile" "$(field "$(roc_decide_ref github:pr/503 "$ROOT" 2>/dev/null)" verdict)" "verdict:reconcile"

# @ambiguous: association on one branch, host lookup names another
git -C "$ROOT" config branch.tidy-readme.sgeTask azdo:wi/4985
out="$(roc_decide_ref azdo:wi/4985 "$ROOT" 2>/dev/null)"; rc=$?
check "two candidates -> reconcile" "$(field "$out" verdict)" "verdict:reconcile"
check "reconcile -> exit 11" "$rc" "11"
check "reconcile lists both candidates" "$(echo "$out" | grep -c '^candidate:')" "2"
check "candidate line carries head and status" \
  "$(echo "$out" | grep '^candidate:' | grep -c "	polish-copy	$(git -C "$ROOT" rev-parse polish-copy)	no-worktree$")" "1"
git -C "$ROOT" config --unset branch.tidy-readme.sgeTask

# @lookup-unknown
touch "$STUB/fail"
out="$(roc_decide_ref azdo:wi/4985 "$ROOT" 2>/dev/null)"; rc=$?
check "failed azdo lookup -> reconcile" "$(field "$out" verdict)" "verdict:reconcile"
check "failed azdo lookup -> lookup unknown" "$(field "$out" lookup)" "lookup:unknown"
check "failed lookup -> exit 11" "$rc" "11"
check "failed github lookup, no candidate -> reconcile, never create" \
  "$(field "$(roc_decide_ref github:issue/7777 "$ROOT" 2>/dev/null)" verdict)" "verdict:reconcile"
rm -f "$STUB/fail"
check "no candidate, complete lookup -> create" \
  "$(field "$(roc_decide_ref github:issue/7777 "$ROOT" 2>/dev/null)" verdict)" "verdict:create"

# @stashes: listed, never applied
echo wip > "$GWT/wip.txt"; git -C "$GWT" add wip.txt; git -C "$GWT" stash -q
git -C "$ROOT" stash list > "$TMP/stash-before"
out="$(roc_decide_ref azdo:wi/812 "$ROOT" 2>/dev/null)"
check "candidate stash is listed" "$(echo "$out" | grep -c '^stash:stash@{0}	guidance-tone$')" "1"
git -C "$ROOT" stash list > "$TMP/stash-after"
check "stash list unchanged" "$(cmp -s "$TMP/stash-before" "$TMP/stash-after" && echo same)" "same"
check "stash not applied" "$([ -e "$GWT/wip.txt" ] && echo applied || echo kept)" "kept"

# @compatible: issue-number path unchanged, and github:issue reaches it too
out="$(roc_decide_ref github:issue/42 "$ROOT" 2>/dev/null)"
check "github:issue/42 -> resume on issue-42" "$(field "$out" verdict)" "verdict:resume"
check "github:issue/42 -> fix/issue-42" "$(field "$out" branch)" "branch:fix/issue-42"
check "decide 42 unchanged" "$(field "$(roc_decide 42 "$ROOT" 2>/dev/null)" verdict)" "verdict:resume"
printf '[{"number":9,"headRefName":"fix/issue-42"}]\n' > "$STUB/linked-42"
check "linked PR on the same branch is one candidate" "$(field "$(roc_decide_ref github:issue/42 "$ROOT" 2>/dev/null)" verdict)" "verdict:resume"
rm -f "$STUB/linked-42"
check "issue lookup asks linked-prs for a complete answer" "$(cat "$STUB/linked-args")" "42 --state all --complete"

# @legacy-ambiguous: two issue-<N> branches and a complete, empty host lookup
git -C "$ROOT" branch fix/issue-55-a
git -C "$ROOT" branch fix/issue-55-b
out="$(roc_decide_ref github:issue/55 "$ROOT" 2>/dev/null)"; rc=$?
check "two legacy issue-55 branches -> reconcile" "$(field "$out" verdict)" "verdict:reconcile"
check "two legacy issue-55 branches -> both listed" "$(echo "$out" | grep -c '^candidate:')" "2"
check "find-branch keeps its first-match answer" "$(roc_find_branch 55 "$ROOT")" "fix/issue-55-a"
git -C "$ROOT" branch -q -D fix/issue-55-a fix/issue-55-b


# @recorded-elsewhere: a legacy match recorded for another task is conflicting evidence
git -C "$ROOT" branch fix/issue-61
git -C "$ROOT" config branch.fix/issue-61.sgeTask github:issue/61
out="$(roc_decide_ref azdo:wi/61 "$ROOT" 2>/dev/null)"; rc=$?
check "legacy branch recorded for another task -> reconcile" "$(field "$out" verdict)" "verdict:reconcile"
check "legacy branch recorded for another task -> exit 11" "$rc" "11"
check "branch recorded for the same task still resumes" "$(field "$(roc_decide_ref github:issue/61 "$ROOT" 2>/dev/null)" verdict)" "verdict:resume"
git -C "$ROOT" config --unset branch.fix/issue-61.sgeTask
git -C "$ROOT" branch -q -D fix/issue-61

# Two issue-<N> worktrees whose branches do not name the issue (CodeRabbit on
# #3653): each one's branch is collected, so the result is reconcile, not create.
git -C "$ROOT" branch alpha-63; git -C "$ROOT" branch beta-63
git -C "$ROOT" worktree add -q "$TMP/wa/issue-63" alpha-63
git -C "$ROOT" worktree add -q "$TMP/wb/issue-63" beta-63
out="$(roc_decide_ref github:issue/63 "$ROOT" 2>/dev/null)"; rc=$?
check "two issue-<N> worktrees -> reconcile" "$(field "$out" verdict)" "verdict:reconcile"
git -C "$ROOT" worktree remove --force "$TMP/wb/issue-63"
check "one issue-<N> worktree -> resume" "$(field "$(roc_decide_ref github:issue/63 "$ROOT" 2>/dev/null)" verdict)" "verdict:resume"
git -C "$ROOT" worktree remove --force "$TMP/wa/issue-63"
git -C "$ROOT" branch -q -D alpha-63 beta-63

# @backoff carried over: a fresh foreign claim on the one candidate
printf 'other-agent %s\n' "$(date +%s)" > "$GWT/.sge-wt-claim"
roc_decide_ref azdo:wi/812 "$ROOT" >/dev/null 2>&1; check "claimed candidate -> exit 10" "$?" "10"
rm -f "$GWT/.sge-wt-claim"

# @no-mutation
snap() { git -C "$ROOT" for-each-ref --format='%(refname) %(objectname)'; git -C "$ROOT" worktree list --porcelain; git -C "$ROOT" stash list; git -C "$GWT" status --porcelain; }
before="$(snap)"; roc_decide_ref azdo:wi/812 "$ROOT" >/dev/null 2>&1; roc_decide_ref azdo:wi/4985 "$ROOT" >/dev/null 2>&1
check "decide-ref changes nothing" "$(snap)" "$before"

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"
