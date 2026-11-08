#!/usr/bin/env bash
# lifecycle-e2e.test.sh — end-to-end preservation and confirmation tests across
# the registry/audit (#3233), checkpoint store (#3234) and the tidy integration
# (#3236). Binds SPEC-139 @confirmed-cleanup and @tidy-safeguards.
# Throwaway repo, no network (the open-PR lookup is stubbed). Run:
#   bash skills/tidy-worktrees/lifecycle-e2e.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$HERE"
# shellcheck source=/dev/null
source "$HERE/inbox.sh"
set +e

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       want: [$3]"; echo "       got : [$2]"; fail=1; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SGE_WT_RECENCY_GUARD_MIN=0
export SGE_CHECKPOINT_DIR="$TMP/ckstore"
R="$TMP/my repo"
git init -q "$R"; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
git -C "$R" commit -q --allow-empty -m init; git -C "$R" branch -M main
git -C "$R" update-ref refs/remotes/origin/main HEAD
git -C "$R" worktree add -q -b feat/done "$TMP/wt done"
git -C "$R" worktree add -q -b feat/wip "$TMP/wt wip"
D="$TMP/wt done"; P="$TMP/wt wip"
cd "$TMP"
hpr_open_pr_heads() { printf '7\tsome/other\n'; }
wl_register "$D" s1 >/dev/null; wl_register "$P" s1 >/dev/null

snapshot() { # everything a deletion or mutation would change
  {
    git -C "$R" worktree list --porcelain
    git -C "$R" for-each-ref refs/heads refs/remotes refs/tags
    git -C "$R" stash list
    git -C "$P" status --porcelain
    git -C "$P" diff --cached
    [ -f "$P/wip.txt" ] && cat "$P/wip.txt"
  } | cksum
}

# --- @confirmed-cleanup: audit + inbox + checkpoint delete or change nothing ---
echo "tracked" >"$P/t.txt"; git -C "$P" add t.txt; git -C "$P" commit -q -m t
echo "edit" >>"$P/t.txt"; echo "new" >"$P/wip.txt"
before="$(snapshot)"
check "dirty registered worktree audits VALUABLE" "$(wl_audit "$P" s1 | sed -n 1p)" "verdict:VALUABLE"
wi_scan "$R" >/dev/null
bash "$HERE/../worktrees/checkpoint.sh" checkpoint "$P" s1 >"$TMP/ck.out" 2>&1; ck_rc=$?
case "$ck_rc" in 0|10) echo "ok   - checkpoint ran (exit $ck_rc)" ;; *) echo "FAIL - checkpoint exit $ck_rc"; sed 's/^/       /' "$TMP/ck.out"; fail=1 ;; esac
check "checkpoint never claims safe-to-remove" "$(grep -c 'safe-to-remove:yes' "$TMP/ck.out")" "0"
check "audit + inbox + checkpoint left worktrees, refs, stash, index and files unchanged" "$(snapshot)" "$before"
# refs/sge/checkpoints/* is new by design, so the snapshot covers heads, remotes and tags only
check "no branch, worktree or stash was removed" \
  "$(git -C "$R" for-each-ref refs/heads | wc -l | tr -d ' '):$(git -C "$R" worktree list | wc -l | tr -d ' ')" "3:3"
check "recovery ref exists after checkpoint" "$(git -C "$R" for-each-ref refs/sge/checkpoints | wc -l | tr -d ' ')" "1"
check "checkpoint left the working file as it was" "$(cat "$P/wip.txt")" "new"

# --- @tidy-safeguards ---
check "clean superseded registered worktree is a candidate" "$(wl_audit "$D" s1 | sed -n 1p)" "verdict:candidate"
echo "later" >"$D/post.txt"; git -C "$D" add post.txt; git -C "$D" commit -q -m "post-merge commit"
check "branch tip moved after audit: re-audit is no longer a candidate" "$(wl_audit "$D" s1 | sed -n 1p)" "verdict:VALUABLE"
wi_scan "$R" >"$TMP/rows.tsv"
check "post-merge commit is never suggested for delete" "$(awk -F'\t' '$6=="feat/done"{print $1}' "$TMP/rows.tsv")" "open-a-pr"
git -C "$P" stash -q -u 2>/dev/null
wi_scan "$R" >"$TMP/rows.tsv"
check "attributed stash is kept, not deleted" "$(awk -F'\t' '$6=="feat/wip"{print $1":"$2}' "$TMP/rows.tsv")" "keep:attributed-stash"
hpr_open_pr_heads() { return 1; }
check "failed PR lookup never yields candidate" "$(wl_audit "$D" s1 | sed -n 1p)" "verdict:KEEP"
hpr_open_pr_heads() { printf '7\tsome/other\n'; }

# --- no lifecycle script or hook contains a deletion or history-mutating command ---
SCRIPTS=("$HERE/inbox.sh" "$HERE/../lib/worktree-lifecycle.sh" "$HERE/../../hooks/copilot/worktree-lifecycle.sh")
DEL='git +(-C +[^ ]+ +)?(worktree +remove|branch +-[dD]|push|reset|stash +(push|save|drop|pop)|checkout|rebase|gc|prune)|push +[^ ]* +--delete|rm +-rf +(\$wt|\$path|"\$wt|"\$path)'
for s in "${SCRIPTS[@]}"; do
  n="$(grep -vE '^[[:space:]]*#' "$s" | grep -cE "$DEL")"
  check "no deletion/mutation command in $(basename "$s")" "$n" "0"
done

# --- removal order and the confirmation gate are written down and kept ---
SK="$SKILL_DIR/SKILL.md"
w="$(grep -n '^git worktree remove' "$SK" | head -1 | cut -d: -f1)"
b="$(grep -n '^git branch -d' "$SK" | head -1 | cut -d: -f1)"
r="$(grep -n '^git push origin --delete' "$SK" | head -1 | cut -d: -f1)"
check "removal order: worktrees, then local branches, then remote" "$([ -n "$w" ] && [ "$w" -lt "$b" ] && [ "$b" -lt "$r" ] && echo ordered)" "ordered"
check "junction guard is still required before removal" "$(grep -c 'Windows junction guard' "$SK" | awk '{print ($1>0)?"yes":"no"}')" "yes"
check "--force still needs a confirmed plan" "$(grep -c 'one consolidated deletion plan\|single confirmation\|ask \*\*one\*\* confirmation' "$SK" | awk '{print ($1>0)?"yes":"no"}')" "yes"
check "inbox is declared suggestions-only in the skill" "$(grep -c -- '--inbox' "$SK" | awk '{print ($1>0)?"yes":"no"}')" "yes"

# --- Windows: the documented junction unlink keeps the target (Windows only) ---
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    T="$TMP/junction-target"; mkdir -p "$T"; echo keep >"$T/precious.txt"
    J="$P/linked"
    if cmd //c mklink //J "$(cygpath -w "$J")" "$(cygpath -w "$T")" >/dev/null 2>&1; then
      cmd //c rmdir "$(cygpath -w "$J")" >/dev/null 2>&1
      check "junction unlinked" "$([ -e "$J" ] && echo present || echo gone)" "gone"
      check "junction target untouched" "$(cat "$T/precious.txt")" "keep"
    else
      echo "skip - could not create a junction here"
    fi ;;
  *) echo "skip - junction guard is Windows-only" ;;
esac
exit $fail
