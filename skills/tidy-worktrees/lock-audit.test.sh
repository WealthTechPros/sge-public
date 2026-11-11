#!/usr/bin/env bash
# lock-audit.test.sh — tests for lock-audit.sh (issue #3408, SPEC-139).
# Throwaway repo, no network: the PR host is stubbed (hpr_* overrides plus a fake
# `gh` on PATH for the GitHub bulk lookup); the Windows junction probe/unlink are
# stubbed so the Windows paths run on any OS. Run:
#   bash skills/tidy-worktrees/lock-audit.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/lock-audit.sh"
set +e

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       want: [$3]"; echo "       got : [$2]"; fail=1; fi; }

export SGE_WT_RECENCY_GUARD_MIN=0
unset SGE_AGENT_ID
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo one"
git init -q -b main "$R"; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
git -C "$R" update-ref refs/heads/main "$(git -C "$R" commit-tree "$(git -C "$R" hash-object -w -t tree /dev/null)" -m init)"
git -C "$R" update-ref refs/remotes/origin/main HEAD
mkdir -p "$TMP/repo one-worktrees"
# "hostile" is a worktree whose PATH carries shell metacharacters (quote + command substitution)
TMPW="$TMP"
# MSYS/Git-for-Windows does not convert POSIX paths in arguments that contain quotes or $(...), so a
# hostile path cannot even be addressed by native git there (the audit correctly fails closed to
# `unknown`). The hostile-path cases therefore run where paths are real POSIX paths (Linux/macOS CI).
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) HOSTILE=0 ;; *) HOSTILE=1 ;; esac
WTP() { case "$1" in hostile) echo "$TMPW/repo one-worktrees/ev'\$(touch PWNED)'il" ;; *) echo "$TMP/repo one-worktrees/$1" ;; esac; }
tipof() { git -C "$(WTP "$1")" rev-parse HEAD; }

# mkwt <name> [owner-session|none]: locked linked worktree holding one commit of its own
mkwt() {
  local n="$1" owner="${2:-s1}" p
  p="$(WTP "$n")"
  git -C "$R" worktree add -q -b "feat/$n" "$p" main
  ( cd "$p" && echo "$n" >"$n.txt" && git add "$n.txt" && git commit -q -m "$n" )
  [ "$owner" = none ] || wl_register "$p" "$owner" >/dev/null
  git -C "$R" worktree lock --reason "retain for review of $n" "$p"
}
for n in stale claimed foreign:s2 unrecorded:none openpr dirty stashed movedtip nopr junc ignored; do
  mkwt "${n%%:*}" "$( [ "$n" = "${n#*:}" ] && echo s1 || echo "${n#*:}" )"
done
printf 'other-agent %s\n' "$(date +%s)" >"$(WTP claimed)/.sge-wt-claim"
echo wip >"$(WTP dirty)/wip.txt"
( cd "$(WTP stashed)" && echo q >q.txt && git add q.txt && git stash -q )   # "WIP on feat/stashed", tree clean again
( cd "$(WTP ignored)" && printf 'node_modules/\n*.tmp\n' >.gitignore && git add .gitignore && git commit -q -m ign && mkdir node_modules && echo x >node_modules/dep.js \
  && for i in $(seq 1 25); do : >"f$i.tmp"; done )   # 26 ignored entries: more than any display cap
[ "$HOSTILE" -eq 0 ] || { mkwt hostile s1; NITEMS=12; CANDS="feat/hostile,feat/ignored,feat/junc,feat/stale"; }
[ "$HOSTILE" -eq 1 ] || { NITEMS=11; CANDS="feat/ignored,feat/junc,feat/stale"; }
git -C "$R" worktree add -q -b feat/unlocked "$(WTP unlocked)" main   # never locked: never listed

# ---- stub host ----
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ -z "${GH_STUB_FAIL:-}" ] || { echo "gh: simulated failure" >&2; exit 1; }
cat "$GH_STUB_JSON"
EOF
chmod +x "$TMP/bin/gh"; export PATH="$TMP/bin:$PATH"; export GH_STUB_JSON="$TMP/gh.json"
mkgh() {
  local args=() n
  for n in stale claimed foreign unrecorded dirty stashed junc ignored hostile; do args+=(--arg "$n" "$(tipof "$n")"); done
  jq -n "${args[@]}" '
    def m($n; $b; $h): {number:$n, headRefName:$b, headRefOid:$h, state:"MERGED", mergedAt:"2026-11-01T00:00:00Z"};
    [ m(1;"feat/stale";$stale), m(2;"feat/claimed";$claimed), m(3;"feat/foreign";$foreign), m(4;"feat/unrecorded";$unrecorded),
      m(6;"feat/dirty";$dirty), m(7;"feat/stashed";$stashed), m(10;"feat/junc";$junc), m(11;"feat/ignored";$ignored), m(12;"feat/hostile";$hostile),
      m(8;"feat/movedtip";"0000000000000000000000000000000000000000"),
      {number:5, headRefName:"feat/openpr", headRefOid:"x", state:"OPEN", mergedAt:null} ]' >"$GH_STUB_JSON"
}
mkgh
hpr_host_kind() { echo github; }
hpr_open_pr_heads() { printf '5\tfeat/openpr\n'; }
JUNC_LIST=""; JUNC_FAIL=0; UNLINK_FAIL=0; PROBE_FAIL_AFTER_UNLINK=0; IGN_FAIL=0; MT_EMPTY=0
_la_junctions() { [ "$JUNC_FAIL" -eq 0 ] || return 1; [ -z "$JUNC_LIST" ] || printf '%s\n' "$JUNC_LIST"; }
_la_unlink_junction() { [ "$UNLINK_FAIL" -eq 0 ] || return 1; JUNC_LIST=""; [ "$PROBE_FAIL_AFTER_UNLINK" -eq 0 ] || JUNC_FAIL=1; return 0; }
# probe stubs (same shape as the real helpers; a switch makes them fail)
_la_ignored() { [ "$IGN_FAIL" -eq 0 ] || return 1; local o; o="$(git -C "$1" status --porcelain --ignored 2>/dev/null)" || return 1; printf '%s\n' "$o" | sed -n 's/^!! //p'; }
_la_mtime() { [ "$MT_EMPTY" -eq 0 ] || return 0; stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
SID=s1
audit() { ( cd "$R" && la_audit "$R" "$SID" ); }
REPORT="$(audit)"
it() { printf '%s' "$REPORT" | jq -r --arg b "feat/$1" ".items[] | select(.branch==\$b) | $2" | tr -d '\r'; }
cr() { it "$1" '.class + ":" + .reason'; }
snap() { echo "$(git -C "$R" for-each-ref | cksum)|$(git -C "$R" worktree list --porcelain | cksum)|$(ls "$(WTP stale)" | tr '\n' ,)"; }

# ---- classification: stale retention locks are decisions, not silent KEEP ----
check "locked worktrees listed, unlocked one is not" "$(printf '%s' "$REPORT" | jq '.items | length'):$(it unlocked .class)" "$NITEMS:"
check "stale retention lock + merged PR + exact head -> candidate" "$(cr stale)" "candidate:inactive-clean-merged-pr-exact-head"
check "lock reason surfaced as data" "$(it stale .lock_reason)" "retain for review of stale"
check "lock age and owner session surfaced" "$(it stale '(.lock_age_days|tostring) + ":" + .owner_session')" "0:s1"
check "completed PR reference recorded" "$(it stale '.pr_state + "#" + .pr_number')" "merged#1"
check "fresh claim -> protected KEEP" "$(cr claimed)" "protected:live-claim"
check "foreign owner -> protected KEEP" "$(cr foreign)" "protected:foreign-owner"
check "unrecorded owner -> unknown (fails closed, surfaced)" "$(cr unrecorded)" "unknown:owner-unrecorded"
check "open PR -> protected" "$(cr openpr)" "protected:active-pr"
check "dirty tracked tree -> protected" "$(cr dirty)" "protected:uncommitted-changes"
check "attributed stash -> protected" "$(cr stashed)" "protected:attributed-stash"
check "merged PR head differs from tip -> protected" "$(cr movedtip)" "protected:tip-differs-from-merged-pr-head"
check "clean but no PR -> protected (clean does not mean merged)" "$(cr nopr)" "protected:no-completed-pr"
check "ignored files listed separately: EVERY path, none truncated" "$(it ignored '(.ignored_count|tostring) + ":" + (.ignored_paths|length|tostring) + ":" + ((.ignored_paths|index("node_modules/")) != null | tostring)')" "26:26:true"
check "candidates = stale, junc, ignored, hostile" "$(printf '%s' "$REPORT" | jq -r '[.decision.candidates[].branch] | sort | join(",")' | tr -d '\r')" "$CANDS"
check "decision offers keep / release / remove" "$(printf '%s' "$REPORT" | jq '.decision.options | length')" "3"
check "approval token is path@full-tip" "$(printf '%s' "$REPORT" | jq -r '.decision.candidates[] | select(.branch=="feat/stale") | .approval' | tr -d '\r')" "$(it stale .path)@$(tipof stale)"
check "ignored-file disclosure in the decision" "$(printf '%s' "$REPORT" | jq -r '.decision.candidates[] | select(.branch=="feat/ignored") | .ignored_files.paths|length' | tr -d '\r')" "26"
check "discard token binds consent to the full ignored set" "$(printf '%s' "$REPORT" | jq -r '.decision.candidates[] | select(.branch=="feat/ignored") | (.discard_approval == (.approval + "@" + .ignored_files.digest)) | tostring' | tr -d '\r')" "true"

# ---- hostile worktree path: commands are quoted data, never evaluated ----
mkdir -p "$TMP/chk"
Q="$(printf '%s' "$REPORT" | jq -r '.decision.candidates[] | select(.branch=="feat/hostile") | .commands.release[0]' | tr -d '\r')"
printf 'printf "%%s" %s\n' "${Q#git worktree unlock }" >"$TMP/chk/q.sh"
if [ "$HOSTILE" -eq 1 ]; then
check "hostile path survives its quoted command as ONE literal argument" "$(cd "$TMP/chk" && bash q.sh)" "$(it hostile .path)"
check "hostile path: no command substitution ran" "$([ -e "$TMP/chk/PWNED" ] && echo ran || echo clean)" "clean"
else echo "skip - hostile-path cases (MSYS cannot address such paths; covered on Linux CI)"; fi
check "remove commands are literal, release is unlock only" \
  "$(printf '%s' "$REPORT" | jq -r '.decision.candidates[] | select(.branch=="feat/stale") | (.commands.release|length|tostring) + ":" + (.commands.remove|length|tostring) + ":" + (.commands.remove[2])' | tr -d '\r')" "1:3:git branch -D 'feat/stale'"

# ---- fail-closed evidence ----
RF="$(cd "$R" && GH_STUB_FAIL=1 la_audit "$R" "$SID")"
check "host PR lookup failure -> no candidates, surfaced as unknown" "$(printf '%s' "$RF" | jq -r '[.items[] | select(.branch=="feat/stale")][0] | .class + ":" + .reason' | tr -d '\r')" "unknown:pr-lookup-failed"
check "host PR lookup failure -> decision not required" "$(printf '%s' "$RF" | jq '.decision.required')" "false"
JUNC_FAIL=1; RJ="$(audit)"; JUNC_FAIL=0
IGN_FAIL=1; RI="$(audit)"; IGN_FAIL=0
check "ignored-files probe failure -> unknown (never read as zero ignored files)" "$(printf '%s' "$RI" | jq -r '[.items[] | select(.branch=="feat/stale")][0] | .class + ":" + .reason' | tr -d '\r')" "unknown:state-unreadable"
MT_EMPTY=1; RM="$(audit)"; MT_EMPTY=0
AGE_VERDICT="$(printf '%s' "$RM" | jq -r '[.items[] | select(.branch=="feat/stale")][0] | .class + ":" + .reason' | tr -d '\r')"
check "unreadable age evidence -> unknown, not candidate" "$AGE_VERDICT" "unknown:age-unreadable"
RN="$( SGE_WT_RECENCY_GUARD_MIN=ten; export SGE_WT_RECENCY_GUARD_MIN; audit )"
check "non-numeric recency guard -> unknown (guard is not silently disabled)" "$(printf '%s' "$RN" | jq -r '[.items[] | select(.branch=="feat/stale")][0] | .class + ":" + .reason' | tr -d '\r')" "unknown:age-unreadable"
check "junction probe unavailable -> unknown, not candidate" "$(printf '%s' "$RJ" | jq -r '[.items[] | select(.branch=="feat/stale")][0] | .class + ":" + .reason' | tr -d '\r')" "unknown:junction-probe-failed"
RS="$(SID=s9 && cd "$R" && la_audit "$R" s9)"
check "another session sees every worktree as foreign (never a candidate)" "$(printf '%s' "$RS" | jq '[.items[] | select(.class=="candidate")] | length')" "0"
RR="$(SGE_WT_RECENCY_GUARD_MIN=600 audit)"
check "recently created -> protected" "$(printf '%s' "$RR" | jq -r '[.items[] | select(.branch=="feat/stale")][0] | .class + ":" + .reason' | tr -d '\r')" "protected:recently-created"

# ---- the audit is read-only; keep performs no mutation ----
before="$(snap)"; audit >/dev/null; ( cd "$R" && la_main audit --summary --session s1 "$R" ) >"$TMP/sum.txt"; after="$(snap)"
check "audit changed nothing" "$after" "$before"
check "summary has the read-only footer" "$(grep -c 'nothing unlocked, removed or changed' "$TMP/sum.txt")" "1"
mkdir -p "$TMP/not-a-repo"
( cd "$TMP/not-a-repo" && la_main audit --summary --session s1 "$TMP/not-a-repo" ) >/dev/null 2>&1; check "audit --summary on a non-repo keeps exit 3 (la_audit status not hidden by the pipe)" "$?" "3"
( cd "$TMP/not-a-repo" && la_main audit --session s1 "$TMP/not-a-repo" ) >/dev/null 2>&1; check "audit on a non-repo exits 3" "$?" "3"
( cd "$R" && la_main apply --mode remove --session s1 "$R" ) >/dev/null 2>&1; rc=$?
check "interrupted decision: no approved items -> exit 2, nothing changed" "$rc:$([ "$(snap)" = "$before" ] && echo same)" "2:same"
check "unlocked state untouched: stale still locked" "$(git -C "$R" worktree list --porcelain | grep -c '^locked retain for review of stale')" "1"

# ---- apply: revalidation ----
APPLY() { ( cd "$R" && la_apply "$R" "$SID" "$@" ); }
STALE_P="$(it stale .path)"; STALE_T="$(tipof stale)"
OUT="$(APPLY remove no "$STALE_P@0000000000000000000000000000000000000000")"
check "stale approval evidence (wrong tip) stops the item" "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].reason')" "stopped:tip-changed-since-approval"
OUT="$(APPLY remove no "$STALE_P@abc")"
check "malformed approval stops" "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].reason')" "stopped:approval-not-path-at-full-tip-sha"
OUT="$(APPLY remove no "$(it claimed .path)@$(tipof claimed)")"
check "protected item cannot be forced through approval" "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].reason')" "stopped:revalidation-protected:live-claim"
OUT="$(APPLY release no "$(it unrecorded .path)@$(tipof unrecorded)")"
check "unknown ownership cannot be approved" "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].reason')" "stopped:revalidation-unknown:owner-unrecorded"
check "stopped items left everything as found" "$(snap)" "$before"
# changed tip after the audit: the user approved the old tip
( cd "$(WTP stale)" && echo more >>stale.txt && git commit -qam more )
OUT="$(APPLY remove no "$STALE_P@$STALE_T")"
check "tip moved after approval -> stopped (PR head no longer matches)" "$(printf '%s' "$OUT" | jq -r '.[0].status')" "stopped"
check "tip moved: worktree and lock intact" "$(git -C "$R" worktree list --porcelain | grep -c '^locked retain for review of stale')" "1"
( cd "$(WTP stale)" && git reset -q --hard "$STALE_T" )
# a live claim appears after the audit
printf 'other-agent %s\n' "$(date +%s)" >"$(WTP stale)/.sge-wt-claim"
OUT="$(APPLY release no "$STALE_P@$STALE_T")"
check "claim appearing after the audit stops the item" "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].reason')" "stopped:revalidation-protected:live-claim"
rm -f "$(WTP stale)/.sge-wt-claim"
echo dirt >"$(WTP stale)/new.txt"
OUT="$(APPLY release no "$STALE_P@$STALE_T")"
check "new uncommitted file after the audit stops the item" "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].reason')" "stopped:revalidation-protected:uncommitted-changes"
rm -f "$(WTP stale)/new.txt"

# ---- apply: release only ----
OUT="$(APPLY release no "$STALE_P@$STALE_T")"
check "release-only unlocks the approved item" "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].recovery_sha + ":" + .[0].completed_pr' | tr -d '\r')" "released:$STALE_T:1"
check "release-only does not delete worktree or branch" "$([ -d "$(WTP stale)" ] && echo dir):$(git -C "$R" rev-parse --verify -q refs/heads/feat/stale >/dev/null && echo branch)" "dir:branch"
check "release-only left it unlocked, others still locked" "$(git -C "$R" worktree list --porcelain | grep -c '^locked')" "$((NITEMS - 1))"
check "re-audit after release no longer lists it" "$(audit | jq '[.items[] | select(.branch=="feat/stale")] | length')" "0"

# ---- apply: remove, ignored data, junctions ----
IGN_P="$(it ignored .path)"; IGN_T="$(tipof ignored)"
IGN_D="$(it ignored .ignored_digest)"
OUT="$(APPLY remove no "$IGN_P@$IGN_T")"
check "ignored files need explicit consent to discard" "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].reason')" "stopped:ignored-files-present-need-discard-consent"
check "no consent -> nothing unlocked or removed" "$([ -d "$(WTP ignored)/node_modules" ] && echo kept):$(git -C "$R" worktree list --porcelain | grep -c '^locked retain for review of ignored')" "kept:1"
OUT="$(APPLY remove yes "$IGN_P@$IGN_T")"
check "discard flag without the ignored-set token stops the item" "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].reason')" "stopped:ignored-set-changed-since-consent"
: >"$(WTP ignored)/appeared-later.tmp"
OUT="$(APPLY remove yes "$IGN_P@$IGN_T@$IGN_D")"
check "ignored file appearing after consent stops the item (fresh consent needed)" "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].reason'):$([ -d "$(WTP ignored)" ] && echo kept)" "stopped:ignored-set-changed-since-consent:kept"
rm -f "$(WTP ignored)/appeared-later.tmp"
check "stopped item stays locked" "$(git -C "$R" worktree list --porcelain | grep -c '^locked retain for review of ignored')" "1"
OUT="$(APPLY remove yes "$IGN_P@$IGN_T@$IGN_D")"
check "remove with consent records SHA, PR and ignored disposition" \
  "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].recovery_sha + ":" + .[0].completed_pr + ":" + .[0].ignored_disposition' | tr -d '\r')" "removed:$IGN_T:11:discarded:26"
check "removed worktree and local branch gone, remote refs untouched" \
  "$([ -d "$(WTP ignored)" ] && echo dir || echo gone):$(git -C "$R" rev-parse --verify -q refs/heads/feat/ignored >/dev/null && echo branch || echo nobranch):$(git -C "$R" rev-parse --verify -q refs/remotes/origin/main >/dev/null && echo origin)" "gone:nobranch:origin"
J_P="$(it junc .path)"; J_T="$(tipof junc)"
JUNC_LIST="$TMP/junction-link"; JUNC_FAIL=1
OUT="$(APPLY remove no "$J_P@$J_T")"; JUNC_FAIL=0
check "junction probe unavailable at apply time stops the item" "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].reason')" "stopped:revalidation-unknown:junction-probe-failed"
JUNC_LIST="$TMP/junction-link"; UNLINK_FAIL=1
OUT="$(APPLY remove no "$J_P@$J_T")"; UNLINK_FAIL=0
check "junction that cannot be unlinked: stop and restore the lock" \
  "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].reason'):$(git -C "$R" worktree list --porcelain | grep -c '^locked retain for review of junc')" "stopped:remove-failed-lock-restored:1"
JUNC_LIST="$TMP/junction-link"; PROBE_FAIL_AFTER_UNLINK=1
OUT="$(APPLY remove no "$J_P@$J_T")"; PROBE_FAIL_AFTER_UNLINK=0; JUNC_FAIL=0
check "post-unlink junction probe failure fails closed: no remove, lock restored" \
  "$(printf '%s' "$OUT" | jq -r '.[0].status + ":" + .[0].reason'):$([ -d "$J_P" ] && echo dir):$(git -C "$R" worktree list --porcelain | grep -c '^locked retain for review of junc')" "stopped:remove-failed-lock-restored:dir:1"
JUNC_LIST="$TMP/junction-link"
OUT="$(APPLY remove no "$J_P@$J_T")"
check "junctions are unlinked (links only) before removal" "$(printf '%s' "$OUT" | jq -r '.[0].status'):$([ -d "$J_P" ] && echo dir || echo gone)" "removed:gone"

# ---- hostile approval token is data end to end ----
if [ "$HOSTILE" -eq 1 ]; then
H_P="$(it hostile .path)"; H_T="$(tipof hostile)"
OUT="$(APPLY release no "$H_P@$H_T")"
check "hostile path: release works and runs no embedded command" "$(printf '%s' "$OUT" | jq -r '.[0].status' | tr -d '\r'):$([ -e "$R/PWNED" ] || [ -e "$PWD/PWNED" ] && echo ran || echo clean)" "released:clean"
fi

# ---- argument handling ----
( cd "$R" && la_main audit ) >/dev/null 2>&1; check "missing session id -> usage error" "$?" "2"
( cd "$R" && la_main apply --session s1 --mode bogus "$R" "x@y" ) >/dev/null 2>&1; check "bad mode -> usage error" "$?" "2"
exit $fail
