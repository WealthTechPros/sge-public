#!/usr/bin/env bash
# checkpoint.test.sh — tests for checkpoint.sh (issue #3234, epic #3216, SPEC-139).
#
# Self-contained: throwaway repo + linked worktree + store in a temp dir. No
# network. Secret-looking fixtures are assembled at runtime so this file itself
# never contains a credential-shaped literal. Run:
#   bash skills/worktrees/checkpoint.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CK="$HERE/checkpoint.sh"
# shellcheck source=/dev/null
source "$HERE/../lib/worktree-lifecycle.sh"
set +e # the sourced libs enable errexit; this tool handles every status explicitly

fail=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else
    echo "FAIL - $1"; echo "       want: [$3]"; echo "       got : [$2]"; fail=1
  fi
}
check_has() { # desc haystack needle
  case "$2" in *"$3"*) echo "ok   - $1" ;; *) echo "FAIL - $1"; echo "       missing: [$3]"; echo "       in: [$2]"; fail=1 ;; esac
}
check_lacks() {
  case "$2" in *"$3"*) echo "FAIL - $1"; echo "       unexpected: [$3]"; fail=1 ;; *) echo "ok   - $1" ;; esac
}

# /tmp spelling: MSYS pwd -P is inconsistent between /c/... and C:/... forms.
TMP="$(mktemp -d /tmp/ckt.XXXXXX)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1
export SGE_CHECKPOINT_DIR="$TMP/store"
unset SGE_CHECKPOINT_TEST_FAULT

SID=sess-1
ck() { bash "$CK" "$@"; }

# Fresh repo + registered linked worktree with a name containing spaces.
new_fixture() { # <name> -> sets ROOT, WT
  ROOT="$TMP/$1/repo"
  WT="$TMP/$1/wt dir/feature wt"
  mkdir -p "$ROOT"
  git init -q -b main "$ROOT"
  git -C "$ROOT" config user.email t@t.t
  git -C "$ROOT" config user.name t
  git -C "$ROOT" config core.autocrlf false
  git -C "$ROOT" config commit.gpgsign false
  printf 'one\n' >"$ROOT/a.txt"
  printf 'two\n' >"$ROOT/sp ace.txt"
  printf 'del\n' >"$ROOT/del.txt"
  printf 'm2\n' >"$ROOT/mod2.txt"
  printf '\000\001\002base' >"$ROOT/bin.dat"
  git -C "$ROOT" add -A
  git -C "$ROOT" commit -q -m init
  git -C "$ROOT" worktree add -q -b feat/x "$WT"
  wl_register "$WT" "$SID" >/dev/null
}

dirty_fixture() {
  printf 'staged\n' >>"$WT/a.txt";            git -C "$WT" add a.txt
  printf 'stagedpart\n' >>"$WT/mod2.txt";     git -C "$WT" add mod2.txt
  printf 'unstagedpart\n' >>"$WT/mod2.txt"
  git -C "$WT" rm -q del.txt
  printf '\000\377\376bin2' >"$WT/bin.dat"
  printf '\000\200new' >"$WT/new.bin";        git -C "$WT" add new.bin
  printf 'edit\n' >>"$WT/sp ace.txt"
  mkdir -p "$WT/un tracked"
  printf 'u1\n' >"$WT/un tracked/file one.txt"
  printf '#!/bin/sh\necho hi\n' >"$WT/x.sh"; chmod +x "$WT/x.sh"
  printf '\000\001untracked-bin' >"$WT/u.bin"
}

snapshot() { # prints a comparable fingerprint of the checkout
  local gi
  gi="$(git -C "$WT" rev-parse --path-format=absolute --git-path index)"
  {
    echo "HEAD=$(git -C "$WT" rev-parse HEAD) $(git -C "$WT" symbolic-ref -q HEAD)"
    echo "INDEX=$(cksum <"$gi")"
    echo "HEADS=$(git -C "$WT" for-each-ref refs/heads)"
    git -C "$WT" status --porcelain=v1 -z --untracked-files=all | tr '\0' '|'
    echo
    (cd "$WT" && find . -name .git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 cksum)
  }
}

# ---------------------------------------------------------------- RED/complete
new_fixture f1; dirty_fixture
before="$(snapshot)"
out="$(ck checkpoint "$WT" "$SID" 2>&1)"; rc=$?
check "complete checkpoint exits 0" "$rc" "0"
check_has "result complete" "$out" "result:complete"
check_has "coverage complete" "$out" "coverage:complete"
check_has "never claims removal safety" "$out" "safe-to-remove:no"
id="$(printf '%s\n' "$out" | sed -n 's/^id://p')"
check "id has expected shape" "$(printf '%s' "$id" | grep -Ec '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$')" "1"
check "original checkout unchanged (branch, index, files)" "$(snapshot)" "$before"
check "recovery ref points at HEAD" "$(git -C "$ROOT" rev-parse "refs/sge/checkpoints/$id")" "$(git -C "$WT" rev-parse HEAD)"
check "store is outside the checkout" "$(case "$(cd "$TMP/store" && pwd -P)/" in "$(cd "$WT" && pwd -P)/"*|"$(cd "$ROOT" && pwd -P)/"*) echo inside ;; *) echo outside ;; esac)" "outside"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) : ;;
  *) check "store dir is owner-only" "$(stat -c %a "$TMP/store" 2>/dev/null || stat -f %Lp "$TMP/store")" "700" ;;
esac
lst="$(ck list "$WT")"
check_has "list shows complete checkpoint" "$lst" "checkpoint:$id status=complete"

# Restore round trip into an isolated location.
DEST="$TMP/restore one"
rout="$(ck restore "$WT" "$id" "$DEST" 2>&1)"; rrc=$?
check "restore exits 0" "$rrc" "0"
check "restored status (staged vs unstaged) identical" \
  "$(git -C "$DEST" status --porcelain=v1 -z --untracked-files=all | tr '\0' '|')" \
  "$(git -C "$WT" status --porcelain=v1 -z --untracked-files=all | tr '\0' '|')"
check "restored staged diff identical" "$(git -C "$DEST" diff --cached --binary | cksum)" "$(git -C "$WT" diff --cached --binary | cksum)"
check "restored unstaged diff identical" "$(git -C "$DEST" diff --binary | cksum)" "$(git -C "$WT" diff --binary | cksum)"
check "restored untracked text with spaces" "$(cat "$DEST/un tracked/file one.txt")" "u1"
check "restored untracked binary identical" "$(cmp "$DEST/u.bin" "$WT/u.bin" && echo same)" "same"
check "restored modified binary identical" "$(cmp "$DEST/bin.dat" "$WT/bin.dat" && echo same)" "same"
check "restored staged-deletion present" "$([ -e "$DEST/del.txt" ] && echo exists || echo gone)" "gone"
check "restored exec bit" "$([ -x "$DEST/x.sh" ] && echo x || echo no)" "x"
check "restore left original unchanged" "$(snapshot)" "$before"

# ---------------------------------------------------------------- GC safety
new_fixture f2
printf 'c\n' >"$WT/committed.txt"; git -C "$WT" add committed.txt; git -C "$WT" commit -q -m "wip commit"
tip="$(git -C "$WT" rev-parse HEAD)"
out="$(ck checkpoint "$WT" "$SID" 2>&1)"; id2="$(printf '%s\n' "$out" | sed -n 's/^id://p')"
git -C "$WT" checkout -q --detach main
git -C "$ROOT" branch -D feat/x -q 2>/dev/null || git -C "$ROOT" branch -D -f feat/x >/dev/null 2>&1
git -C "$ROOT" reflog expire --expire=now --all
git -C "$ROOT" gc -q --prune=now 2>/dev/null
check "committed tip survives branch delete + gc" "$(git -C "$ROOT" cat-file -t "$tip" 2>/dev/null)" "commit"
DEST2="$TMP/restore two"
ck restore "$WT" "$id2" "$DEST2" >/dev/null 2>&1
check "restore of committed work after gc" "$(git -C "$DEST2" rev-parse HEAD 2>/dev/null)" "$tip"

# ---------------------------------------------------------------- clean worktree
new_fixture f3
out="$(ck checkpoint "$WT" "$SID" 2>&1)"; rc=$?
check "clean worktree checkpoint is complete" "$rc" "0"

# ---------------------------------------------------------------- ignored files
new_fixture f4; dirty_fixture
printf 'build/\n*.log\n' >"$ROOT/.gitignore"; git -C "$ROOT" add .gitignore; git -C "$ROOT" commit -q -m ign
git -C "$WT" merge -q main 2>/dev/null
mkdir -p "$WT/build"; printf 'objdata\n' >"$WT/build/out.o"; printf 'log\n' >"$WT/run.log"
before="$(snapshot)"
out="$(ck checkpoint "$WT" "$SID" 2>&1)"; rc=$?
check "ignored content -> partial exit 10" "$rc" "10"
check_has "names unsupported ignored coverage" "$out" "unsupported:ignored"
check_has "worktree retained" "$out" "retain-worktree:yes"
check_has "not safe to remove" "$out" "safe-to-remove:no"
check_has "coverage partial" "$out" "coverage:partial"
check_lacks "never described as fully backed up" "$out" "fully backed up"
check_lacks "never described as complete" "$out" "result:complete"
check_lacks "ignored file contents not exposed" "$out" "objdata"
pid="$(printf '%s\n' "$out" | sed -n 's/^id://p')"
check "partial recorded as partial" "$(ck list "$WT" | grep -c "checkpoint:$pid status=partial")" "1"
rr="$(ck restore "$WT" "$pid" "$TMP/restore partial" 2>&1)"; rrc=$?
check "restore of partial refused without flag" "$rrc" "9"
check "no dest created for refused restore" "$([ -e "$TMP/restore partial" ] && echo yes || echo no)" "no"
ck restore "$WT" "$pid" "$TMP/restore partial2" --allow-partial >/dev/null 2>&1
check "restore allowed with --allow-partial" "$(cat "$TMP/restore partial2/un tracked/file one.txt" 2>/dev/null)" "u1"
check "ignored file not restored" "$([ -e "$TMP/restore partial2/build" ] && echo yes || echo no)" "no"
check "partial checkpoint left checkout unchanged" "$(snapshot | grep -v '^HEAD=' | head -n 3 | cksum)" "$(printf '%s\n' "$before" | grep -v '^HEAD=' | head -n 3 | cksum)"

# ---------------------------------------------------------------- secrets
new_fixture f5
tok="gh""p_""abcdefghijklmnopqrstuvwxyz0123456789"
pk="-----BEGIN ""RSA PRIVATE ""KEY-----"
printf 'TOKEN=%s\n' "$tok" >"$WT/.env"
printf '%s\nMIIB\n' "$pk" >"$WT/notes.txt"
printf 'fine\n' >"$WT/ok.txt"
printf 'x\n' >"$WT/Clients.XLSX"
printf 'key = "%s"\n' "$tok" >>"$WT/a.txt"
out="$(ck checkpoint "$WT" "$SID" 2>&1)"; rc=$?
check "secret-pattern files -> partial exit 10" "$rc" "10"
check_has "names secret-pattern coverage" "$out" "unsupported:secret-pattern"
check_has "worktree retained (secrets)" "$out" "retain-worktree:yes"
check_lacks "token value not printed" "$out" "$tok"
check_lacks "key material not printed" "$out" "MIIB"
sid5="$(printf '%s\n' "$out" | sed -n 's/^id://p')"
check "secret strings absent from the whole store" "$(grep -rlaF -e "$tok" -e "MIIB" "$TMP/store" | wc -l | tr -d ' ')" "0"
check "secret strings absent from recovery objects reachable via ref" "$(git -C "$ROOT" grep -c -e "$tok" "refs/sge/checkpoints/$sid5" 2>/dev/null | wc -l | tr -d ' ')" "0"
ck restore "$WT" "$sid5" "$TMP/restore sec" --allow-partial >/dev/null 2>&1
check "permitted file restored" "$(cat "$TMP/restore sec/ok.txt" 2>/dev/null)" "fine"
check "secret file not restored" "$([ -e "$TMP/restore sec/.env" ] && echo yes || echo no)" "no"
check "client-data spreadsheet not restored" "$([ -e "$TMP/restore sec/Clients.XLSX" ] && echo yes || echo no)" "no"

# ---------------------------------------------------------------- inaccessible / special files
new_fixture f6
printf 'locked\n' >"$WT/locked.txt"; chmod 000 "$WT/locked.txt"
if [ ! -r "$WT/locked.txt" ]; then
  out="$(ck checkpoint "$WT" "$SID" 2>&1)"; rc=$?
  check "unreadable file -> partial" "$rc" "10"
  check_has "names inaccessible coverage" "$out" "unsupported:inaccessible"
  check_has "retained (inaccessible)" "$out" "retain-worktree:yes"
else
  echo "skip - cannot make a file unreadable on this platform/user"
fi
chmod 600 "$WT/locked.txt" 2>/dev/null
new_fixture f6b
ln -s a.txt "$WT/link" 2>/dev/null
if [ -L "$WT/link" ]; then
  out="$(ck checkpoint "$WT" "$SID" 2>&1)"; rc=$?
  check "untracked symlink is unsupported, not followed" "$rc" "10"
  check_has "names symlink coverage" "$out" "unsupported:symlink"
else
  echo "skip - symlinks unavailable"
fi

# ---------------------------------------------------------------- unmerged paths
new_fixture f7
git -C "$WT" checkout -q -b c1; printf 'A\n' >"$WT/a.txt"; git -C "$WT" commit -qam c1
git -C "$WT" checkout -q -b c2 HEAD~1; printf 'B\n' >"$WT/a.txt"; git -C "$WT" commit -qam c2
git -C "$WT" merge c1 >/dev/null 2>&1
out="$(ck checkpoint "$WT" "$SID" 2>&1)"; rc=$?
check "merge conflict -> partial" "$rc" "10"
check_has "names unmerged coverage" "$out" "unsupported:unmerged"

# ---------------------------------------------------------------- ownership
new_fixture f8; dirty_fixture
out="$(ck checkpoint "$WT" other-session 2>&1)"; rc=$?
check "foreign session -> refused exit 4" "$rc" "4"
check_has "ownership refusal explained" "$out" "result:refused"
check_has "ownership refusal retains worktree" "$out" "retain-worktree:yes"
out="$(ck checkpoint "$ROOT" "$SID" 2>&1)"; rc=$?
check "main checkout (not a registered linked worktree) refused" "$rc" "4"
git -C "$ROOT" worktree add -q -b feat/unreg "$TMP/f8/unreg" 2>/dev/null
out="$(ck checkpoint "$TMP/f8/unreg" "$SID" 2>&1)"; rc=$?
check "unregistered worktree refused" "$rc" "4"
out="$(ck checkpoint "$WT" 'bad id;x' 2>&1)"; rc=$?
check "bad session id rejected" "$rc" "5"
before_count="$(find "$TMP/store" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l | tr -d ' ')"
ck checkpoint "$WT" other-session >/dev/null 2>&1
check "refusals write nothing" "$(find "$TMP/store" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l | tr -d ' ')" "$before_count"

# ---------------------------------------------------------------- unsafe store locations
new_fixture f9; dirty_fixture
for bad in "$WT/store" "$ROOT/.state" "$TMP/OneDrive - Corp/sge/checkpoints" "$TMP/Dropbox/x" "relative/path"; do
  out="$(SGE_CHECKPOINT_DIR="$bad" ck checkpoint "$WT" "$SID" 2>&1)"; rc=$?
  check "unsafe store refused: ${bad##*/}" "$rc" "6"
  check_has "unsafe store explained" "$out" "result:refused"
done
check "nothing created in unsafe locations" "$([ -e "$WT/store" ] || [ -e "$TMP/OneDrive - Corp" ] || [ -e "$TMP/Dropbox" ] && echo yes || echo no)" "no"

# ---------------------------------------------------------------- interrupted writes
new_fixture f10; dirty_fixture
before="$(snapshot)"
for fault in after-payload before-rename; do
  out="$(SGE_CHECKPOINT_TEST_ALLOW=1 SGE_CHECKPOINT_TEST_FAULT=$fault ck checkpoint "$WT" "$SID" 2>&1)"; rc=$?
  check "interrupted ($fault) exits non-zero" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
  check "interrupted ($fault) never advertised as a checkpoint" "$(ck list "$WT" | grep -c '^checkpoint:')" "0"
done
check "interrupted leftovers are reported, not purged" "$(ck list "$WT" | grep -c '^interrupted:')" "2"
check "interrupted runs left checkout unchanged" "$(snapshot)" "$before"
out="$(ck checkpoint "$WT" "$SID" 2>&1)"; rc=$?
check "a later checkpoint succeeds after interruption" "$rc" "0"
check "leftovers still present (never auto-purged)" "$(ck list "$WT" | grep -c '^interrupted:')" "2"

# ---------------------------------------------------------------- untrusted names
new_fixture f11
mkdir -p "$WT/dir with space"
printf 'x\n' >"$WT/dir with space/\$(touch PWNED).txt"
printf 'y\n' >"$WT/-rf"
printf 'z\n' >"$WT/semi;touch PWNED2"
printf 'q\n' >"$WT/back\`touch PWNED3\`"
out="$(ck checkpoint "$WT" "$SID" 2>&1)"; rc=$?
check "hostile file names checkpoint cleanly" "$rc" "0"
idh="$(printf '%s\n' "$out" | sed -n 's/^id://p')"
ck restore "$WT" "$idh" "$TMP/restore hostile" >/dev/null 2>&1
check "dollar-paren name restored literally" "$(cat "$TMP/restore hostile/dir with space/\$(touch PWNED).txt" 2>/dev/null)" "x"
check "dash-leading name restored" "$(cat "$TMP/restore hostile/-rf" 2>/dev/null)" "y"
check "no command was executed from a path name" "$(ls "$WT" "$TMP/restore hostile" "$PWD" 2>/dev/null | grep -c '^PWNED')" "0"

# ---------------------------------------------------------------- restore hardening
new_fixture f12; dirty_fixture
out="$(ck checkpoint "$WT" "$SID" 2>&1)"; idr="$(printf '%s\n' "$out" | sed -n 's/^id://p')"
ck restore "$WT" "$idr" "$WT/inside" >/dev/null 2>&1; rc=$?
check "restore into the original worktree refused" "$rc" "6"
mkdir -p "$TMP/nonempty"; printf 'k\n' >"$TMP/nonempty/keep"
ck restore "$WT" "$idr" "$TMP/nonempty" >/dev/null 2>&1; rc=$?
check "restore into non-empty dir refused" "$rc" "6"
check "non-empty dir untouched" "$(cat "$TMP/nonempty/keep")" "k"
ck restore "$WT" "../../etc" "$TMP/rr1" >/dev/null 2>&1; rc=$?
check "restore with path-like id refused" "$rc" "2"
ck restore "$WT" "20200101T000000Z-deadbeef" "$TMP/rr2" >/dev/null 2>&1; rc=$?
check "restore of unknown id fails" "$([ "$rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
key_dir="$(find "$TMP/store" -mindepth 2 -maxdepth 2 -type d -name "$idr")"
printf 'tampered\n' >>"$key_dir/staged.patch"
ck restore "$WT" "$idr" "$TMP/rr3" >/dev/null 2>&1; rc=$?
check "tampered payload refused (integrity)" "$rc" "8"
check "tampered restore creates nothing" "$([ -e "$TMP/rr3" ] && echo yes || echo no)" "no"

# ---------------------------------------------------------------- manual prune only
new_fixture f13; dirty_fixture
out="$(ck checkpoint "$WT" "$SID" 2>&1)"; idp="$(printf '%s\n' "$out" | sed -n 's/^id://p')"
ck checkpoint "$WT" "$SID" >/dev/null 2>&1
ck prune "$WT" "$idp" >/dev/null 2>&1; rc=$?
check "prune without --yes refused" "$rc" "2"
check "prune without --yes deletes nothing" "$(ck list "$WT" | grep -c "checkpoint:$idp")" "1"
ck prune "$WT" "$idp" --yes >/dev/null 2>&1; rc=$?
check "explicit prune succeeds" "$rc" "0"
check "pruned checkpoint gone" "$(ck list "$WT" | grep -c "checkpoint:$idp")" "0"
check "pruned recovery ref gone" "$(git -C "$ROOT" rev-parse -q --verify "refs/sge/checkpoints/$idp" >/dev/null 2>&1 && echo yes || echo no)" "no"
check "other checkpoint kept" "$(ck list "$WT" | grep -c '^checkpoint:')" "1"

# ---------------------------------------------------------------- hidden changes + large staged secret (review findings)
new_fixture f14
git -C "$WT" update-index --assume-unchanged a.txt
printf 'hidden edit\n' >>"$WT/a.txt"
out="$(ck checkpoint "$WT" "$SID" 2>&1)"; rc=$?
check "assume-unchanged edit is reported, not silently complete" "$rc" "10"
check_has "names hidden-change coverage" "$out" "unsupported:hidden-change"
new_fixture f15
{ printf 'api_key = "%s"\n' "$tok"; head -c 300000 /dev/zero | tr '\0' 'a'; printf '\n'; } >"$WT/big.cfg"
git -C "$WT" add big.cfg
printf 'clean now\n' >"$WT/big.cfg"
out="$(ck checkpoint "$WT" "$SID" 2>&1)"; rc=$?
check "large staged secret blob is detected (no SIGPIPE fail-open)" "$rc" "10"
check_has "staged secret named as secret-pattern" "$out" "unsupported:secret-pattern"
check "staged secret absent from the store" "$(grep -rlaF -e "$tok" "$TMP/store" | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------- tampered store (review findings)
new_fixture f16
printf 'u\n' >"$WT/u.txt"
out="$(ck checkpoint "$WT" "$SID" 2>&1)"; idt="$(printf '%s\n' "$out" | sed -n 's/^id://p')"
kd="$(find "$TMP/store" -mindepth 2 -maxdepth 2 -type d -name "$idt")"
printf '../../../x\tdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\t-\n' >"$kd/untracked.idx"
newh="$(git hash-object "$kd/untracked.idx")"
sed -i "s/^untracked_idx=.*/untracked_idx=$newh/" "$kd/manifest"
ck restore "$WT" "$idt" "$TMP/rt1" >/dev/null 2>&1; rc=$?
check "tampered untracked index (traversal field) refused" "$rc" "8"
check "tampered restore creates nothing" "$([ -e "$TMP/rt1" ] && echo yes || echo no)" "no"
# shellcheck source=/dev/null
source "$CK"
bad_allowed=""
for p in .GIT/hooks/x 'a/.git./x' 'git~1/x' 'a:b' '../x' '/abs'; do _ck_safe_rel "$p" && bad_allowed="$bad_allowed $p"; done
check "hostile recorded paths rejected (.GIT, ADS, traversal)" "$bad_allowed" ""
check ".gitignore-style names remain allowed" "$(_ck_safe_rel ".gitignore" && _ck_safe_rel "sub/.github/x.yml" && echo ok)" "ok"

exit "$fail"
