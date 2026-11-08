#!/usr/bin/env bash
# audit.test.sh — tests for audit.sh (issue #3399, SPEC-139 tidy audit engine).
# Throwaway repos, no network: origin/* refs are made with update-ref, and the
# PR host is stubbed (hpr_host_kind / hpr_open_pr_heads / hpr_completed_pr_heads
# overrides plus a fake `gh` on PATH for the GitHub bulk lookup). Run:
#   bash skills/tidy-worktrees/audit.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/audit.sh"
set +e

fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1"; echo "       want: [$3]"; echo "       got : [$2]"; fail=1; fi; }

export SGE_WT_RECENCY_GUARD_MIN=0 # fixtures are brand new; recency has its own test
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo one"
git init -q -b main "$R"; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
(cd "$R" && git update-ref refs/heads/main "$(git commit-tree "$(git hash-object -w -t tree /dev/null)" -m init)")
INIT="$(git -C "$R" rev-parse HEAD)"

# mkremote <name> <file> <content>... : commit(s) on top of INIT, published as origin/<name>
mkremote() {
  local name="$1"; shift
  git -C "$R" checkout -q --detach "$INIT"
  while [ $# -ge 2 ]; do printf '%s\n' "$2" >"$R/$1"; git -C "$R" add "$1"; git -C "$R" commit -q -m "$name $1"; shift 2; done
  git -C "$R" update-ref "refs/remotes/origin/$name" HEAD
  git -C "$R" checkout -q main
}
tipof() { git -C "$R" rev-parse "refs/remotes/origin/$1"; }

mkremote feat/merged-ff m.txt one
mkremote feat/squash s.txt a s.txt ab
mkremote feat/open o.txt one
mkremote feat/none-live n.txt one
mkremote feat/closed-live c.txt one
mkremote feat/superseded sup.txt one
mkremote feat/postmerge p.txt one p.txt two
mkremote feat/lookup-fails l.txt one
mkremote feat/localcopy lc.txt one
mkremote release/1.0 rel.txt one
mkremote "feat/it's" q.txt one
mkremote feat/recent r.txt one

# main moves: merge feat/merged-ff, squash feat/squash (different patch), cherry-pick superseded
git -C "$R" merge -q --no-ff -m "merge ff" "$(tipof feat/merged-ff)"
printf 'ab\nextra\n' >"$R/s.txt"; git -C "$R" add s.txt; git -C "$R" commit -q -m "squash of feat/squash (#5)"
git -C "$R" cherry-pick "$(tipof feat/superseded)" >/dev/null 2>&1
# localcopy: remote is at main's init (ancestor => would be A), local branch has extra work
git -C "$R" update-ref refs/remotes/origin/feat/localcopy "$INIT"
git -C "$R" branch feat/localcopy "$INIT"; git -C "$R" checkout -q feat/localcopy
echo w >"$R/w.txt"; git -C "$R" add w.txt; git -C "$R" commit -q -m "local only"; git -C "$R" checkout -q main
git -C "$R" update-ref refs/remotes/origin/main HEAD

# local: a merged branch, a dirty worktree, a locked merged worktree, a stash
git -C "$R" branch feat/local-merged main
mkdir -p "$TMP/repo one-worktrees"
git -C "$R" worktree add -q -b feat/dirty "$TMP/repo one-worktrees/dirty" main; echo wip >"$TMP/repo one-worktrees/dirty/wip.txt"
git -C "$R" worktree add -q -b feat/locked "$TMP/repo one-worktrees/locked" main
git -C "$R" worktree lock "$TMP/repo one-worktrees/locked"
echo st >"$R/st.txt"; git -C "$R" add st.txt; git -C "$R" stash -q
cd "$TMP"

# ---- stub host: GitHub (bulk gh lookup) ----
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ -z "${GH_STUB_FAIL:-}" ] || { echo "gh: simulated failure" >&2; exit 1; }
cat "$GH_STUB_JSON"
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_STUB_JSON="$TMP/gh.json"
jq -n --arg sq "$(tipof feat/squash)" --arg pm "$(git -C "$R" rev-parse "$(tipof feat/postmerge)^")" \
      --arg mf "$(tipof feat/merged-ff)" --arg cl "$(tipof feat/closed-live)" '
  [ {number:5, headRefName:"feat/squash", headRefOid:$sq, state:"MERGED", mergedAt:"2026-11-01T00:00:00Z"},
    {number:6, headRefName:"feat/postmerge", headRefOid:$pm, state:"MERGED", mergedAt:"2026-11-01T00:00:00Z"},
    {number:7, headRefName:"feat/merged-ff", headRefOid:$mf, state:"MERGED", mergedAt:"2026-11-01T00:00:00Z"},
    {number:8, headRefName:"feat/closed-live", headRefOid:$cl, state:"CLOSED", mergedAt:null},
    {number:9, headRefName:"feat/open", headRefOid:"x", state:"OPEN", mergedAt:null} ]' >"$GH_STUB_JSON"
hpr_host_kind() { echo "${STUB_HOST:-github}"; }
hpr_open_pr_heads() { printf '9\tfeat/open\n'; }
STUB_HOST=github

REPORT="$(ta_audit_repo "$R")"
it() { printf '%s' "$REPORT" | jq -r --arg k "$1" --arg n "$2" ".items[] | select(.kind==\$k and .name==\$n) | $3" | tr -d '\r'; }
rb() { it remote-branch "$1" '.bucket'; }
rs() { it remote-branch "$1" '.sub_verdict'; }

check "report is valid JSON with items" "$(printf '%s' "$REPORT" | jq '.items | length > 0')" "true"
check "merge-commit merged remote branch -> A" "$(rb feat/merged-ff)" "A"
check "squash-merged remote branch (PR head == tip) -> A" "$(rb feat/squash):$(rs feat/squash)" "A:MERGED"
check "open PR remote branch -> C keep" "$(rb feat/open):$(rs feat/open)" "C:KEEP:open-pr"
check "no PR, net work -> B NEEDS-DECISION" "$(rb feat/none-live):$(rs feat/none-live)" "B:NEEDS-DECISION:LIVE-UNMERGED"
check "closed PR, net work -> B closed-pr-unmerged" "$(rs feat/closed-live)" "NEEDS-DECISION:CLOSED-PR-UNMERGED"
check "superseded (patch already in main) -> D" "$(rb feat/superseded):$(rs feat/superseded)" "D:SUPERSEDED"
check "commits after a merged PR -> B post-merge" "$(rb feat/postmerge):$(rs feat/postmerge)" "B:NEEDS-DECISION:POST-MERGE-COMMITS"
check "protected branch name -> C" "$(rb release/1.0):$(rs release/1.0)" "C:KEEP:protected-branch-name"
check "unsafe branch name -> C and no command" "$(rb "feat/it's"):$(it remote-branch "feat/it's" '.commands | length')" "C:0"
check "remote with unresolved local copy -> C" "$(rs feat/localcopy)" "KEEP:local-copy-unresolved"
check "origin/main and HEAD are not listed" "$(printf '%s' "$REPORT" | jq '[.items[] | select(.kind=="remote-branch" and (.name=="main" or .name=="HEAD"))] | length')" "0"
check "ahead/behind recorded" "$(it remote-branch feat/none-live '(.ahead|tostring) + "/" + (.behind|tostring)')" "1/4" # main: ff commit, merge, squash, cherry-pick
check "last author recorded" "$(it remote-branch feat/none-live '.last_author')" "t"
check "pr state recorded (merged)" "$(it remote-branch feat/squash '.pr_state + "#" + .pr_number')" "merged#5"

# ---- literal per-branch remote commands, local before remote ----
check "remote delete is a literal quoted per-branch command" \
  "$(printf '%s' "$REPORT" | jq -r '.delete_plan.merged_A.remote[] | select(.item=="remote-branch:feat/squash") | .commands[0]' | tr -d '\r')" \
  "git push origin --delete 'feat/squash'"
check "no command uses a shell variable" "$(printf '%s' "$REPORT" | jq -r '[.. | .commands? // empty | .[]] | map(select(test("[$`]"))) | length')" "0"
check "A remote list = merged-ff + squash" \
  "$(printf '%s' "$REPORT" | jq -r '[.delete_plan.merged_A.remote[].item] | sort | join(",")' | tr -d '\r')" "remote-branch:feat/merged-ff,remote-branch:feat/squash"
check "D remote list = superseded only" \
  "$(printf '%s' "$REPORT" | jq -r '[.delete_plan.discard_D.remote[].item] | join(",")' | tr -d '\r')" "remote-branch:feat/superseded"
check "B/C items never carry delete commands" \
  "$(printf '%s' "$REPORT" | jq '[.items[] | select((.bucket=="B" or .bucket=="C") and (.commands|length)>0)] | length')" "0"
check "every plan entry records the tip sha" \
  "$(printf '%s' "$REPORT" | jq '[.delete_plan | .. | objects | select(has("commands")) | select(.tip | test("^[0-9a-f]{40}$") | not)] | length')" "0"

# ---- locals ----
check "merged local branch -> A with safe -d" "$(it branch feat/local-merged '.bucket + ":" + .commands[0]' | tr -d '\r')" "A:git branch -d 'feat/local-merged'"
check "dirty worktree -> C uncommitted" "$(it worktree feat/dirty '.bucket + ":" + .sub_verdict')" "C:NEEDS-DECISION:UNCOMMITTED"
check "git-locked merged worktree -> C keep" "$(it worktree feat/locked '.bucket + ":" + .sub_verdict')" "C:KEEP:git-locked"
check "local branch with net work -> B" "$(it branch feat/localcopy '.bucket')" "B"
check "stash is listed as a decision, never deletable" "$(it stash 'stash@{0}' '.bucket + ":" + .sub_verdict + ":" + (.commands|length|tostring)')" "C:NEEDS-DECISION:STASH:0"
check "counts add up" "$(printf '%s' "$REPORT" | jq '(.counts.A + .counts.B + .counts.C + .counts.D) == .counts.total')" "true"
check "bucket counts present per kind" "$(printf '%s' "$REPORT" | jq '.counts_by_kind["remote-branch"] | has("A") and has("D")')" "true"

# ---- fail safe: lookup failures ----
hpr_open_pr_heads() { return 1; }
RF="$(ta_audit_repo "$R")"
check "open-PR set unknown -> refused, empty plan" "$(printf '%s' "$RF" | jq '.refused and (.delete_plan == null)')" "true"
check "open-PR set unknown -> no A/B/D items" "$(printf '%s' "$RF" | jq '[.items[] | select(.bucket!="C")] | length')" "0"
hpr_open_pr_heads() { printf '9\tfeat/open\n'; }
GH_STUB_FAIL=1 RF="$(GH_STUB_FAIL=1 ta_audit_repo "$R")"
check "gh bulk lookup failure -> remote branches kept, none deletable" \
  "$(printf '%s' "$RF" | jq '[.items[] | select(.kind=="remote-branch" and .bucket!="C")] | length')" "0"
check "gh failure reason recorded" "$(printf '%s' "$RF" | jq -r '.items[] | select(.name=="feat/squash") | .sub_verdict' | tr -d '\r')" "KEEP:pr-lookup-failed"
RT="$(SGE_AUDIT_PR_LIMIT=5 ta_audit_repo "$R")"
check "truncated PR list: found records still used" "$(printf '%s' "$RT" | jq -r '.items[] | select(.name=="feat/squash" and .kind=="remote-branch") | .bucket' | tr -d '\r')" "A"
check "truncated PR list: absence is not 'none' (keep)" \
  "$(printf '%s' "$RT" | jq -r '.items[] | select(.name=="feat/none-live" and .kind=="remote-branch") | .sub_verdict' | tr -d '\r')" "KEEP:pr-lookup-failed"
git -C "$R" update-ref -d refs/remotes/origin/main
RB="$(ta_audit_repo "$R")"
check "unresolvable base -> nothing deletable" "$(printf '%s' "$RB" | jq '[.items[] | select(.bucket=="A" or .bucket=="D")] | length')" "0"
git -C "$R" update-ref refs/remotes/origin/main main

# ---- other hosts via the shim ----
STUB_HOST=azdo
hpr_completed_pr_heads() {
  case "$1" in
    feat/squash) printf '5\t%s\t2026-11-01T00:00:00Z\n' "$(tipof feat/squash)" ;;
    feat/lookup-fails) return 1 ;;
    *) return 0 ;;
  esac
}
RA="$(ta_audit_repo "$R")"
ra() { printf '%s' "$RA" | jq -r --arg n "$1" '.items[] | select(.kind=="remote-branch" and .name==$n) | .bucket + ":" + .sub_verdict' | tr -d '\r'; }
check "azdo: completed PR with matching head -> A" "$(ra feat/squash)" "A:MERGED"
check "azdo: no completed PR, net work -> B" "$(ra feat/none-live)" "B:NEEDS-DECISION:LIVE-UNMERGED"
check "azdo: completed-PR lookup failure -> C keep" "$(ra feat/lookup-fails)" "C:KEEP:pr-lookup-failed"
STUB_HOST=forgejo
RG="$(ta_audit_repo "$R")"
check "forgejo: no closed-PR lookup -> squash merge is not A on PR evidence" \
  "$(printf '%s' "$RG" | jq -r '.items[] | select(.kind=="remote-branch" and .name=="feat/squash") | .bucket' | tr -d '\r')" "B"
check "forgejo: git-reachable branch still A" "$(printf '%s' "$RG" | jq -r '.items[] | select(.kind=="remote-branch" and .name=="feat/merged-ff") | .bucket' | tr -d '\r')" "A"
STUB_HOST=unknown
RU="$(ta_audit_repo "$R")"
check "unknown host -> every item kept (lookup failed)" "$(printf '%s' "$RU" | jq '[.items[] | select(.kind=="remote-branch" and .bucket!="C")] | length')" "0"
STUB_HOST=github

# ---- recency guard ----
RR="$(SGE_WT_RECENCY_GUARD_MIN=60 ta_audit_repo "$R")"
check "recent tip -> remote branch kept" "$(printf '%s' "$RR" | jq -r '.items[] | select(.kind=="remote-branch" and .name=="feat/merged-ff") | .sub_verdict' | tr -d '\r')" "KEEP:recently-committed"

# ---- read-only ----
before="$(git -C "$R" for-each-ref | cksum)|$(git -C "$R" worktree list --porcelain | cksum)|$(git -C "$R" stash list | cksum)|$(git -C "$TMP/repo one-worktrees/dirty" status --porcelain)"
ta_main "$R" >/dev/null; ta_main --summary "$R" >"$TMP/sum.txt"
after="$(git -C "$R" for-each-ref | cksum)|$(git -C "$R" worktree list --porcelain | cksum)|$(git -C "$R" stash list | cksum)|$(git -C "$TMP/repo one-worktrees/dirty" status --porcelain)"
check "audit changed nothing (refs, worktrees, stash, working tree)" "$after" "$before"
check "summary prints bucket counts and the read-only footer" "$(grep -c 'A merged' "$TMP/sum.txt"):$(grep -c 'nothing deleted, pushed or opened' "$TMP/sum.txt")" "1:1"
check "ta_main --json-out writes a JSON array" "$(ta_main --json-out "$TMP/o.json" "$R" >/dev/null; jq 'type + ":" + (length|tostring)' "$TMP/o.json" | tr -d '\r')" '"array:1"'
check "non-repo dir reported, others still audited" "$(ta_main "$TMP" "$R" 2>/dev/null | jq 'length')" "1"
exit $fail
