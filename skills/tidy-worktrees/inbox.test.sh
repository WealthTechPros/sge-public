#!/usr/bin/env bash
# inbox.test.sh — tests for inbox.sh (issue #3236, SPEC-139 worktree inbox).
# Throwaway repos, no network (the open-PR lookup is stubbed). Run:
#   bash skills/tidy-worktrees/inbox.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/inbox.sh"
set +e

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       want: [$3]"; echo "       got : [$2]"; fail=1; fi; }

export SGE_WT_RECENCY_GUARD_MIN=0 # fixtures are brand new; the recency guard has its own test
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkrepo() { # <dir>
  git init -q "$1"; git -C "$1" config user.email t@t.t; git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m init; git -C "$1" branch -M main
  git -C "$1" update-ref refs/remotes/origin/main HEAD
}
R1="$TMP/repo one"; R2="$TMP/repo2"
mkrepo "$R1"; mkrepo "$R2"
W="$TMP/repo one-worktrees"; mkdir -p "$W" "$TMP/repo2-worktrees"

git -C "$R1" worktree add -q -b feat/superseded "$W/sup ersed"
git -C "$R1" worktree add -q -b feat/live "$W/live"
git -C "$W/live" commit -q --allow-empty -m "net work"; echo x >"$W/live/f"; git -C "$W/live" add f; git -C "$W/live" commit -q -m "net work 2"
git -C "$R1" worktree add -q -b feat/dirty "$W/dirty"; echo wip >"$W/dirty/wip.txt"
git -C "$R1" worktree add -q -b feat/openpr "$W/openpr"
git -C "$R1" worktree add -q -b feat/claimed "$W/claimed"; echo "agent-x $(date +%s)" >"$W/claimed/.sge-wt-claim"
git -C "$R1" worktree add -q -b feat/stashy "$W/stashy"
echo s >"$W/stashy/s.txt"; git -C "$W/stashy" add s.txt; git -C "$W/stashy" stash -q
git -C "$R1" worktree add -q -b 'feat/$HOME;touch$IFS-pwned' "$W/hostile"
git -C "$R1" branch feat/branch-only-superseded main
git -C "$R1" branch feat/branch-only-live main; git -C "$R1" checkout -q feat/branch-only-live
git -C "$R1" commit -q --allow-empty -m bo-live; echo b >"$R1/b.txt"; git -C "$R1" add b.txt; git -C "$R1" commit -q -m bo-live2; git -C "$R1" checkout -q main
git -C "$R2" worktree add -q -b feat/other "$TMP/repo2-worktrees/other"
cd "$TMP"

fpr_open_pr_heads() { printf '9\tfeat/openpr\n'; }
OUT="$TMP/out.tsv"; { wi_scan "$R1"; wi_scan "$R2"; } >"$OUT"
row() { awk -F'\t' -v b="$1" '$6==b' "$OUT"; }
act() { row "$1" | cut -f1; }
why() { row "$1" | cut -f2; }

check "clean superseded worktree -> delete" "$(act feat/superseded)" "delete"
check "delete reason says record the tip SHA" "$(why feat/superseded | grep -c record-tip-sha)" "1"
check "unmerged work -> open-a-pr (supersession live)" "$(act feat/live)" "open-a-pr"
check "uncommitted -> checkpoint-then-decide" "$(act feat/dirty)" "checkpoint-then-decide"
check "open PR -> continue" "$(act feat/openpr)" "continue"
check "live claim -> continue" "$(act feat/claimed)" "continue"
check "attributed stash -> keep" "$(act feat/stashy):$(why feat/stashy)" "keep:attributed-stash"
check "branch without worktree, superseded -> delete" "$(act feat/branch-only-superseded)" "delete"
check "branch without worktree, live -> open-a-pr" "$(act feat/branch-only-live)" "open-a-pr"
check "worktree outside the repo dir is listed" "$(row feat/other | cut -f1,3)" "$(printf 'delete\tworktree')"
check "items from at least two repos" "$(cut -f4 "$OUT" | sort -u | wc -l | tr -d ' ')" "2"
check "path with spaces preserved" "$(row feat/superseded | cut -f5 | grep -c 'sup ersed')" "1"
check "hostile branch name kept as data" "$(why 'feat/$HOME;touch$IFS-pwned' | grep -c .)" "1"
check "hostile branch caused no side effect" "$([ -e "$TMP/pwned" ] || [ -e "$W/hostile/pwned" ] && echo bad || echo ok)" "ok"
check "every row has exactly one allowed action" \
  "$(cut -f1 "$OUT" | grep -vcE '^(continue|open-a-pr|delete|checkpoint-then-decide|keep)$')" "0"
check "every row has a reason" "$(awk -F'\t' '$2==""' "$OUT" | wc -l | tr -d ' ')" "0"
check "open-a-pr only for supersession-live rows" \
  "$(awk -F'\t' '$1=="open-a-pr"{print $6}' "$OUT" | sort | tr '\n' ' ')" "feat/branch-only-live feat/live "
check "tip sha is recorded on every delete row" "$(awk -F'\t' '$1=="delete" && $7 !~ /^[0-9a-f]{40}$/' "$OUT" | wc -l | tr -d ' ')" "0"

# --- fail safe: PR lookup failure never suggests delete / open-a-pr ---
fpr_open_pr_heads() { return 1; }
wi_scan "$R1" >"$OUT"
check "lookup failure: no delete or open-a-pr" "$(cut -f1 "$OUT" | grep -cE '^(delete|open-a-pr)$')" "0"
check "lookup failure reason recorded" "$(row feat/superseded | cut -f2)" "open-pr-lookup-failed"
fpr_open_pr_heads() { printf '9\tfeat/openpr\n'; }
git -C "$R1" update-ref -d refs/remotes/origin/main
wi_scan "$R1" >"$OUT"
check "unresolvable base: never delete" "$(cut -f1 "$OUT" | grep -c '^delete$')" "0"
git -C "$R1" update-ref refs/remotes/origin/main main

# --- recency guard ---
SGE_WT_RECENCY_GUARD_MIN=60 wi_scan "$R1" >"$OUT"
check "recently created -> continue, never delete" "$(act feat/superseded)" "continue"
export SGE_WT_RECENCY_GUARD_MIN=0

# --- machine-readable output ---
wi_scan "$R1" >"$OUT"
JSON="$(wi_json <"$OUT")"
check "json is valid and one object per row" "$(printf '%s' "$JSON" | jq 'length')" "$(wc -l <"$OUT" | tr -d ' ')"
check "json round-trips the hostile branch" \
  "$(printf '%s' "$JSON" | jq -r '[.[] | select(.branch == "feat/$HOME;touch$IFS-pwned")] | length')" "1"
check "json carries action+reason" "$(printf '%s' "$JSON" | jq '[.[] | select(.action and .reason)] | length')" "$(wc -l <"$OUT" | tr -d ' ')"
check "human list is suggestions only" "$(wi_human <"$OUT" | grep -c 'nothing is deleted, pushed or opened')" "1"
check "wi_main --json on two repos" "$(wi_main --json "$R1" "$R2" | jq 'map(.repo) | unique | length')" "2"

# --- read-only: nothing changed ---
before="$(git -C "$R1" worktree list --porcelain | wc -l)|$(git -C "$R1" for-each-ref | wc -l)|$(git -C "$R1" stash list | wc -l)|$(git -C "$W/dirty" status --porcelain)"
wi_main "$R1" "$R2" >/dev/null
after="$(git -C "$R1" worktree list --porcelain | wc -l)|$(git -C "$R1" for-each-ref | wc -l)|$(git -C "$R1" stash list | wc -l)|$(git -C "$W/dirty" status --porcelain)"
check "inbox changed nothing (worktrees, refs, stash, working tree)" "$after" "$before"
check "non-repo dir reported, others still listed" "$(wi_main "$TMP" "$R2" 2>/dev/null | grep -c 'feat/other')" "1"
exit $fail
