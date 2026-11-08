#!/usr/bin/env bash
# audit.sh — READ-ONLY deterministic tidy audit (issue #3399, SPEC-139).
# Classifies EVERY local worktree, local branch, stash and origin/* branch of a
# repo into one of four outcome buckets and emits JSON. It never deletes, pushes,
# commits, stashes, checkpoints, labels or opens anything: the remote-delete and
# local-delete commands it prints are a PLAN for the main session to put in front
# of the user.
#
#   audit.sh [--json-out <file>] [--summary] [--fetch] [<repo-dir> ...]
#   source audit.sh; ta_audit_repo <repo-dir>      # JSON object for one repo
#
# Buckets (the skill's Objective):
#   A  merged                 -> goes in ONE delete plan (tip SHA recorded)
#   B  unmerged, net work     -> NEEDS-DECISION: candidate PR after the
#                                supersession check; assessors confirm value
#   C  part-complete / in-flight / protected / uncertain -> named blocker,
#                                continue-or-keep decision; never deleted
#   D  superseded or empty    -> discard, tip SHA recorded first
# Sub-verdicts (replace the old overloaded VALUABLE):
#   MERGED, SUPERSEDED, NEEDS-DECISION:LIVE-UNMERGED, :POST-MERGE-COMMITS,
#   :CLOSED-PR-UNMERGED, :UNCOMMITTED, :STASH, and KEEP:<reason> (bucket C).
#
# FAIL SAFE: any PR/base/supersession/status lookup failure, unknown host,
# unsafe branch name, live claim, git lock, recency, open PR, or unresolved local
# copy of a remote branch yields bucket C (keep). An item is deleted-eligible
# (A/D) only on positive evidence. If the open-PR set cannot be determined the
# delete plan is empty and `refused` is true.
#
# Remote deletes are emitted as LITERAL per-branch commands (single-quoted via
# jq @sh, names validated first): the sge git-policy-guard blocks
# `git push origin --delete` with a variable-driven branch name. Order in the
# plan is worktrees -> local branches -> remote branches (local before remote).
#
# Branch names, paths and author names are untrusted DATA: only ever passed as
# quoted arguments or jq --arg, never to eval.
#
# Exit codes: 0 ok, 2 usage, 3 a given dir is not a git repo (others still run).

_TA_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_TA_HERE/inbox.sh"
# shellcheck source=/dev/null
source "$_TA_HERE/../lib/host-pr-read.sh"
set +e

_ta_safe_name() { # branch names we are willing to put in a literal command
  [[ "$1" =~ ^[A-Za-z0-9._/@+-]+$ ]] && [[ "$1" != -* ]] && [[ "$1" != *..* ]]
}

# <ref> <base> -> live | superseded | unknown (same two signals as rg_supersession)
_ta_supersession() {
  local ref="$1" base="$2" cherry n
  git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || { echo unknown; return; }
  git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1 || { echo unknown; return; }
  cherry="$(git cherry "$base" "$ref" 2>/dev/null)" || { echo unknown; return; }
  n="$(printf '%s\n' "$cherry" | grep -c '^+ ')"
  [ "$n" -eq 0 ] && { echo superseded; return; }
  if git diff --quiet "$base" "$ref" 2>/dev/null; then echo superseded; return; fi
  echo live
}

# Load the host-routed PR evidence once per repo (cwd must be the repo).
ta_pr_load() {
  local cap raw n
  _TA_HOST="$(hpr_host_kind 2>/dev/null)"; [ -n "$_TA_HOST" ] || _TA_HOST=unknown
  _TA_OPEN_OK=1; _TA_OPEN=""
  _TA_OPEN="$(hpr_open_pr_heads 2>/dev/null)" || { _TA_OPEN_OK=0; _TA_OPEN=""; }
  _TA_ALL_OK=0; _TA_ALL_TRUNC=0; _TA_ALL=""
  if [ "$_TA_HOST" = github ] && [ "$_TA_OPEN_OK" -eq 1 ]; then
    cap="${SGE_AUDIT_PR_LIMIT:-2000}"
    case "$cap" in ''|*[!0-9]*|0) cap=2000 ;; esac
    if raw="$(_hpr_timed gh pr list --state all --limit "$cap" --json number,headRefName,headRefOid,state,mergedAt 2>/dev/null)" \
       && n="$(printf '%s' "$raw" | jq -e 'if type=="array" then length else error("x") end' 2>/dev/null)"; then
      n="${n%$'\r'}"
      _TA_ALL="$raw"; _TA_ALL_OK=1
      [ "$n" -ge "$cap" ] && _TA_ALL_TRUNC=1
    fi
  fi
}

# ta_pr_record <branch> -> "<state>\t<number>\t<head-sha>" (state open|merged|closed|none)
# rc 1 = lookup failed/unknown: the caller MUST keep.
ta_pr_record() {
  local b="$1" line out rc
  [ "${_TA_OPEN_OK:-0}" -eq 1 ] || return 1
  line="$(printf '%s\n' "$_TA_OPEN" | awk -F'\t' -v b="$b" '$2==b{print "open\t"$1"\t-"; exit}')"
  if [ -n "$line" ]; then printf '%s\n' "$line"; return 0; fi
  case "$_TA_HOST" in
    github)
      [ "$_TA_ALL_OK" -eq 1 ] || return 1
      line="$(printf '%s' "$_TA_ALL" | jq -r --arg b "$b" '
          [.[] | select(.headRefName == $b)]
          | ((map(select(.state == "MERGED")) | sort_by(.mergedAt) | last) // (sort_by(.number) | last))
          | if . == null then empty
            else "\(.state | ascii_downcase)\t\(.number)\t\(.headRefOid)" end' 2>/dev/null | tr -d '\r')" || return 1
      if [ -n "$line" ]; then printf '%s\n' "$line"; return 0; fi
      [ "$_TA_ALL_TRUNC" -eq 1 ] && return 1 # absence is not proof when the list may be truncated
      printf 'none\t-\t-\n'; return 0 ;;
    azdo)
      out="$(hpr_completed_pr_heads "$b" 2>/dev/null)"; rc=$?
      [ "$rc" -eq 0 ] || return 1
      if [ -n "$out" ]; then
        printf '%s\n' "$out" | sort -t$'\t' -k3 | tail -1 | awk -F'\t' '{print "merged\t"$1"\t"$2}'
      else printf 'none\t-\t-\n'; fi
      return 0 ;;
    forgejo)
      # The Forgejo adapter has no closed/merged-PR lookup: only the open set is
      # known, so a branch reads "none" and can only reach A/D on git evidence.
      printf 'none\t-\t-\n'; return 0 ;;
    *) return 1 ;;
  esac
}

# ta_classify_ref <ref> <branch> <base>
# Sets TA_BUCKET TA_SUB TA_REASON TA_PRS TA_PRN TA_SUP TA_VIA
ta_classify_ref() {
  local ref="$1" br="$2" base="$3" tip rec head
  TA_BUCKET=C; TA_SUB="KEEP:unclassified"; TA_REASON=unclassified; TA_PRS=unknown; TA_PRN=-; TA_SUP=unknown; TA_VIA=-
  tip="$(git rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)" \
    || { TA_SUB="KEEP:ref-unreadable"; TA_REASON=ref-unreadable; return; }
  rec="$(ta_pr_record "$br")" || { TA_SUB="KEEP:pr-lookup-failed"; TA_REASON=open-pr-lookup-failed; return; }
  IFS=$'\t' read -r TA_PRS TA_PRN head <<<"$rec"
  if [ "$TA_PRS" = open ]; then TA_SUB="KEEP:open-pr"; TA_REASON=open-pr-in-flight; return; fi
  if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
    TA_SUB="KEEP:base-unresolved"; TA_REASON=base-unresolvable; return
  fi
  if git merge-base --is-ancestor "$tip" "$base" 2>/dev/null; then
    TA_BUCKET=A; TA_SUB=MERGED; TA_VIA=ancestor; TA_SUP=superseded
    TA_REASON=reachable-from-base; [ "$TA_PRS" = merged ] && TA_REASON=merged-pr-and-reachable-from-base
    return
  fi
  if [ "$TA_PRS" = merged ] && [ "$head" = "$tip" ]; then
    TA_BUCKET=A; TA_SUB=MERGED; TA_VIA=squash-pr; TA_SUP=superseded
    TA_REASON=merged-pr-head-equals-tip; return
  fi
  TA_SUP="$(_ta_supersession "$ref" "$base")"
  case "$TA_SUP" in
    superseded) TA_BUCKET=D; TA_SUB=SUPERSEDED; TA_REASON=no-net-work-vs-base-record-tip-sha ;;
    live)
      TA_BUCKET=B; TA_SUB="NEEDS-DECISION:LIVE-UNMERGED"; TA_REASON=net-work-not-in-base
      [ "$TA_PRS" = merged ] && { TA_SUB="NEEDS-DECISION:POST-MERGE-COMMITS"; TA_REASON=commits-after-merged-pr; }
      [ "$TA_PRS" = closed ] && { TA_SUB="NEEDS-DECISION:CLOSED-PR-UNMERGED"; TA_REASON=pr-closed-without-merge-net-work-remains; } ;;
    *) TA_SUB="KEEP:supersession-unknown"; TA_REASON=supersession-unknown ;;
  esac
}

# Emit one TSV record (19 columns, "-" for empty).
_ta_emit() { # kind name path tip bucket sub reason prs prn ahead behind age author sup dirty unpushed owner nameok via
  local f out="" first=1
  for f in "$@"; do
    [ -n "$f" ] || f=-
    if [ "$first" -eq 1 ]; then out="$(_wi_clean "$f")"; first=0; else out+=$'\t'"$(_wi_clean "$f")"; fi
  done
  printf '%s\n' "$out"
}

_ta_ab() { # <base> <ref> -> "<ahead>\t<behind>" (ahead = ref commits not in base)
  local lr
  lr="$(git rev-list --left-right --count "$1...$2" 2>/dev/null)" || { printf 'unknown\tunknown\n'; return; }
  awk '{print $2"\t"$1}' <<<"$lr"
}

# TSV rows for one repo (cwd = repo top). Locals first, then stashes, then remotes.
_ta_rows() {
  local top="$1" def base tmp
  def="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [ -n "$def" ] || def=main
  base="origin/$def"
  declare -A local_bucket=() locked=()
  local wt="" line
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt="${line#worktree }" ;;
      locked*) [ -z "$wt" ] || locked["$(_wi_clean "$wt")"]=1 ;;
      "") wt="" ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null; echo)

  local a r k repo p b tip d u pr age o ab_a ab_b author nameok ref
  tmp="$(wi_scan "$top")"
  while IFS=$'\t' read -r a r k repo p b tip d u pr age o; do
    [ -n "$a" ] || continue
    nameok=yes; _ta_safe_name "$b" || nameok=no
    ref="refs/heads/$b"; [ "$k" = worktree ] && [ "$b" = "(detached)" ] && ref="$tip"
    IFS=$'\t' read -r ab_a ab_b <<<"$(_ta_ab "$base" "$ref")"
    author="$(git log -1 --format=%an "$ref" 2>/dev/null)"
    TA_BUCKET=C; TA_SUB="KEEP:$r"; TA_REASON="$r"; TA_PRS="$pr"; TA_PRN=-; TA_SUP=-; TA_VIA=-
    case "$a" in
      delete|open-a-pr)
        if [ "$b" = "(detached)" ]; then TA_SUB="KEEP:detached-head"; TA_REASON=detached-head
        elif [ -n "${locked[$p]:-}" ]; then TA_SUB="KEEP:git-locked"; TA_REASON=git-ownership-lock
        elif [ "$nameok" = no ]; then TA_SUB="KEEP:unsafe-branch-name"; TA_REASON=unsafe-branch-name
        else ta_classify_ref "$ref" "$b" "$base"; fi ;;
      checkpoint-then-decide) TA_SUB="NEEDS-DECISION:UNCOMMITTED"; TA_REASON="$r"; TA_SUP=unknown ;;
      continue)
        TA_SUB="KEEP:$r"
        case "$r" in
          open-pr-with-uncommitted-changes) TA_SUB="NEEDS-DECISION:UNCOMMITTED" ;;
          open-pr) TA_SUB="KEEP:open-pr" ;;
        esac ;;
      *) TA_SUB="KEEP:$r" ;;
    esac
    [ "$k" = worktree ] && [ -n "${locked[$p]:-}" ] && [ "$TA_BUCKET" != C ] && { TA_BUCKET=C; TA_SUB="KEEP:git-locked"; TA_REASON=git-ownership-lock; TA_VIA=-; }
    # a dirty worktree is never delete-eligible whatever its branch evidence says
    [ "$d" = yes ] && [ "$TA_BUCKET" != C ] && { TA_BUCKET=C; TA_SUB="NEEDS-DECISION:UNCOMMITTED"; TA_REASON=uncommitted-changes; TA_VIA=-; }
    [ "$b" = "(detached)" ] || local_bucket["$b"]="$TA_BUCKET"
    _ta_emit "$k" "$b" "$p" "$tip" "$TA_BUCKET" "$TA_SUB" "$TA_REASON" "$TA_PRS" "$TA_PRN" "$ab_a" "$ab_b" "$age" "$author" "$TA_SUP" "$d" "$u" "$o" "$nameok" "$TA_VIA"
  done <<<"$tmp"

  # the branch checked out in the main checkout is never removed: list it as KEEP
  mainbr="$(git symbolic-ref -q --short HEAD 2>/dev/null)"
  if [ -n "$mainbr" ] && [ "$mainbr" != "$def" ]; then
    local_bucket["$mainbr"]=C
    IFS=$'\t' read -r ab_a ab_b <<<"$(_ta_ab "$base" "refs/heads/$mainbr")"
    _ta_emit branch "$mainbr" - "$(git rev-parse "refs/heads/$mainbr" 2>/dev/null)" C "KEEP:main-checkout" \
      current-checkout-of-the-repo - - "$ab_a" "$ab_b" "$(_wi_age_days "$top" "refs/heads/$mainbr")" \
      "$(git log -1 --format=%an "refs/heads/$mainbr" 2>/dev/null)" - - - - yes -
  fi

  # stashes (repo-global): always a decision, never deleted by the plan
  local sref ssub sbr sage
  while IFS=$'\t' read -r sref ssub; do
    [ -n "$sref" ] || continue
    sbr="$(printf '%s' "$ssub" | sed -n 's/^\(WIP on\|On\) \([^:]*\):.*/\2/p')"
    sage="$(_wi_age_days "$top" "$sref")"
    _ta_emit stash "$sref" - "$(git rev-parse "$sref" 2>/dev/null)" C "NEEDS-DECISION:STASH" \
      "stash-on-branch:${sbr:-none}" - - - - "$sage" - unknown - - - yes -
  done < <(git stash list --format='%gd%x09%gs' 2>/dev/null)

  # origin/* branches
  local rn rtip rct rauth now ref_full recent protected_re mainbr
  protected_re='^(main|master|develop|trunk|gh-pages|staging|production|prod|dev|stable|next|release/.*|hotfix/.*)$'
  [ -z "${SGE_AUDIT_PROTECTED_REGEX:-}" ] || protected_re="$SGE_AUDIT_PROTECTED_REGEX"
  now="$(date +%s)"
  while IFS=$'\t' read -r ref_full rtip rct rauth; do
    rn="${ref_full#refs/remotes/origin/}"
    [ "$rn" != HEAD ] && [ "$rn" != "$def" ] || continue
    case "$rn" in HEAD|HEAD/*) continue ;; esac
    nameok=yes; _ta_safe_name "$rn" || nameok=no
    age="unknown"; case "$rct" in ''|*[!0-9]*) ;; *) age=$(( (now - rct) / 86400 )) ;; esac
    IFS=$'\t' read -r ab_a ab_b <<<"$(_ta_ab "$base" "$ref_full")"
    TA_BUCKET=C; TA_SUB="KEEP:unclassified"; TA_REASON=unclassified; TA_PRS=unknown; TA_PRN=-; TA_SUP=-; TA_VIA=-
    recent=1; case "$rct" in ''|*[!0-9]*) ;; *) [ $(( (now - rct) / 60 )) -lt "${SGE_WT_RECENCY_GUARD_MIN:-10}" ] || recent=0 ;; esac
    if [[ "$rn" =~ $protected_re ]]; then
      TA_SUB="KEEP:protected-branch-name"; TA_REASON=protected-branch-name
    elif [ "$nameok" = no ]; then TA_SUB="KEEP:unsafe-branch-name"; TA_REASON=unsafe-branch-name
    elif [ "$recent" -eq 1 ]; then
      TA_SUB="KEEP:recently-committed"; TA_REASON=tip-committed-within-recency-guard
    else
      ta_classify_ref "$ref_full" "$rn" "$base"
      if [ "$TA_BUCKET" != C ] && [ -n "${local_bucket[$rn]:-}" ] && [ "${local_bucket[$rn]}" != A ] && [ "${local_bucket[$rn]}" != D ]; then
        TA_BUCKET=C; TA_SUB="KEEP:local-copy-unresolved"; TA_REASON=local-branch-of-same-name-not-resolved; TA_VIA=-
      fi
    fi
    _ta_emit remote-branch "$rn" - "$rtip" "$TA_BUCKET" "$TA_SUB" "$TA_REASON" "$TA_PRS" "$TA_PRN" "$ab_a" "$ab_b" "$age" "$rauth" "$TA_SUP" - - - "$nameok" "$TA_VIA"
  done < <(git for-each-ref --format='%(refname)%09%(objectname)%09%(committerdate:unix)%09%(authorname)' refs/remotes/origin 2>/dev/null)
}

# JSON report for one repo on stdout.
ta_audit_repo() {
  local repo="$1" top rows def base
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || { echo "error:not-a-git-repo:$repo" >&2; return 3; }
  (
    cd "$top" || exit 3
    def="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"; [ -n "$def" ] || def=main
    base="origin/$def"
    ta_pr_load
    rows="$(_ta_rows "$top")"
    local win=false
    case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) win=true ;; esac
    printf '%s\n' "$rows" | jq -R -s \
      --arg repo "$top" --arg def "$def" --arg base "$base" --arg host "${_TA_HOST:-unknown}" \
      --argjson open_ok "$([ "${_TA_OPEN_OK:-0}" -eq 1 ] && echo true || echo false)" \
      --argjson win "$win" '
      def nz: if . == "-" then null else . end;
      def cmds($i):
        if ($i.bucket != "A" and $i.bucket != "D") or $i.name_ok != "yes" then []
        elif $i.kind == "worktree" then
          ["git worktree remove " + ($i.path | @sh),
           (if $i.merged_via == "ancestor" then "git branch -d " else "git branch -D " end) + ($i.name | @sh)]
        elif $i.kind == "branch" then
          [(if $i.merged_via == "ancestor" then "git branch -d " else "git branch -D " end) + ($i.name | @sh)]
        elif $i.kind == "remote-branch" then ["git push origin --delete " + ($i.name | @sh)]
        else [] end;
      (split("\n") | map(select(length > 0) | split("\t"))
        | map({kind: .[0], name: .[1], path: (.[2] | nz), tip: .[3], bucket: .[4], sub_verdict: .[5],
               reason: .[6], pr_state: .[7], pr_number: (.[8] | nz), ahead: .[9], behind: .[10],
               age_days: .[11], last_author: (.[12] | nz), supersession: .[13], dirty: .[14],
               unpushed: .[15], owner: (.[16] | nz), name_ok: .[17], merged_via: .[18]})
        | map(. + {commands: cmds(.)})
        | map(. + {needs_junction_guard: ($win and .kind == "worktree" and (.commands | length) > 0)})
        | map(del(.name_ok, .merged_via))
      ) as $items
      | def plan($b; $kinds): [$items[] | select(.bucket == $b and (.kind | IN($kinds[])) and (.commands | length) > 0)
            | {item: (.kind + ":" + .name), tip: .tip, pr_state: .pr_state, commands: .commands,
               needs_junction_guard: .needs_junction_guard}];
      {
        repo: $repo, default_branch: $def, base: $base, host: $host,
        open_pr_set_known: $open_ok, refused: ($open_ok | not),
        counts: ({A: 0, B: 0, C: 0, D: 0} + ($items | group_by(.bucket) | map({key: .[0].bucket, value: length}) | from_entries)
                 + {total: ($items | length)}),
        counts_by_kind: ($items | group_by(.kind) | map({key: .[0].kind,
            value: ({A: 0, B: 0, C: 0, D: 0} + (group_by(.bucket) | map({key: .[0].bucket, value: length}) | from_entries))}) | from_entries),
        items: $items,
        delete_plan: (if $open_ok then {
          order: "worktrees, then local branches, then remote branches; re-verify each tip before running",
          merged_A: {local: (plan("A"; ["worktree"]) + plan("A"; ["branch"])), remote: plan("A"; ["remote-branch"])},
          discard_D: {local: (plan("D"; ["worktree"]) + plan("D"; ["branch"])), remote: plan("D"; ["remote-branch"])}
        } else null end)
      }'
  )
}

ta_summary() { # JSON array of reports on stdin -> short human text
  jq -r '.[] |
    "repo: \(.repo)  base: \(.base)  host: \(.host)  open-PR set known: \(.open_pr_set_known)",
    (if .refused then "  REFUSED: open-PR set unknown, nothing is delete-eligible" else empty end),
    "  total \(.counts.total)  A merged \(.counts.A)  B unmerged-valuable \(.counts.B)  C part-complete/keep \(.counts.C)  D superseded/empty \(.counts.D)",
    (.counts_by_kind | to_entries[] | "    \(.key): A=\(.value.A) B=\(.value.B) C=\(.value.C) D=\(.value.D)"),
    (.items[] | select(.bucket == "B" or .bucket == "D" or (.bucket == "C" and (.sub_verdict | startswith("NEEDS-DECISION")))) |
       "  [\(.bucket)] \(.kind) \(.name)  \(.sub_verdict)  tip=\(.tip[0:12])  ahead=\(.ahead) behind=\(.behind) age=\(.age_days)d")'
  echo "(read-only audit: nothing deleted, pushed or opened; commands in delete_plan are a plan for the user to confirm)"
}

ta_main() {
  local out="" summary=0 fetch=0 repos=() rc=0 reports="" r one
  while [ $# -gt 0 ]; do
    case "$1" in
      --json-out) shift; out="${1:-}"; [ -n "$out" ] || { echo "usage: --json-out <file>" >&2; return 2; } ;;
      --summary) summary=1 ;;
      --fetch) fetch=1 ;;
      -*) echo "usage: audit.sh [--json-out <file>] [--summary] [--fetch] [<repo-dir> ...]" >&2; return 2 ;;
      *) repos+=("$1") ;;
    esac
    shift
  done
  if [ "${#repos[@]}" -eq 0 ] && [ -n "${SGE_INBOX_REPOS:-}" ]; then
    local IFS=':'; read -r -a repos <<<"$SGE_INBOX_REPOS"; unset IFS
  fi
  [ "${#repos[@]}" -gt 0 ] || repos=(.)
  for r in "${repos[@]}"; do
    # --fetch only refreshes remote-tracking refs (Phase 0); nothing else moves.
    [ "$fetch" -eq 0 ] || git -C "$r" fetch --prune origin >/dev/null 2>&1
    one="$(ta_audit_repo "$r")" || { rc=3; continue; }
    reports+="$one"$'\n'
  done
  reports="$(printf '%s' "$reports" | jq -s '.')"
  [ -z "$out" ] || printf '%s\n' "$reports" >"$out"
  if [ "$summary" -eq 1 ]; then printf '%s' "$reports" | ta_summary; else printf '%s\n' "$reports"; fi
  return $rc
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then ta_main "$@"; exit $?; fi
