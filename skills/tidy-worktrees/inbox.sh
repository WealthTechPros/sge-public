#!/usr/bin/env bash
# inbox.sh — READ-ONLY cross-repo "what's open" worktree inbox (issue #3236,
# epic #3216, SPEC-139 "Worktree inbox"). Tells an engineer which worktrees and
# branches are open across repos and what to do about each. It SUGGESTS only:
# it never deletes, pushes, commits, stashes, checkpoints or opens anything.
#
#   inbox.sh [--json] [--json-out <file>] [<repo-dir> ...]
#   source inbox.sh; wi_scan <repo-dir>      # TSV rows for one repo
#
# Repos: the dirs given, else each dir in $SGE_INBOX_REPOS (colon-separated),
# else the current repo. Each repo's LINKED worktrees are read from
# `git worktree list`, so worktrees that live in a sibling `<repo>-worktrees/`
# dir (outside the repo) are included. Local branches with no worktree are
# listed too.
#
# Per item: kind, repo, path, branch, tip SHA, dirty state, unpushed commits,
# linked-PR state, age, owner (the #3233 registry) and EXACTLY ONE action with
# its reason:
#   continue              active (live claim, recent, current session) or open PR
#   open-a-pr             ONLY when rescue-guard supersession is `live`; confirm
#                         the linked issue is still open before pushing
#   delete                clean and superseded/merged; the tip SHA is the
#                         recovery handle and MUST be recorded in the plan
#   checkpoint-then-decide  uncommitted work: run worktrees/checkpoint.sh first
#   keep                  audit uncertain (reason says why), or stash/default
#
# Fail safe: an open-PR lookup failure, an unresolvable base or any unreadable
# state yields `keep`, never `delete`. Branch names, paths and ids are
# untrusted DATA: only ever passed as quoted arguments, never to eval, and the
# JSON is built with jq --arg so they cannot break out of it.
#
# Exit codes: 0 ok, 2 usage, 3 a given dir is not a git repo (others still run).

_WI_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_WI_HERE/../lib/worktree-lifecycle.sh"
# shellcheck source=/dev/null
source "$_WI_HERE/../worktrees/resume-or-create.sh"
set +e # the sourced libs enable errexit; every status here is handled explicitly

_wi_clean() { printf '%s' "$1" | tr '\t\r\n' '   '; }

# <repo> <branch> <base> -> live | superseded | unknown. Mirrors
# rg_supersession (same two signals) for a branch that has no worktree.
_wi_branch_supersession() {
  local repo="$1" br="$2" base="$3" cherry n
  git -C "$repo" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1 || { echo unknown; return; }
  cherry="$(git -C "$repo" cherry "$base" "refs/heads/$br" 2>/dev/null)" || { echo unknown; return; }
  n="$(printf '%s\n' "$cherry" | grep -c '^+ ')"
  [ "$n" -eq 0 ] && { echo superseded; return; }
  if git -C "$repo" diff --quiet "$base" "refs/heads/$br" 2>/dev/null; then echo superseded; return; fi
  echo live
}

_wi_age_days() { # <repo> <ref> -> whole days since the tip commit, or "unknown"
  local ct
  ct="$(git -C "$1" log -1 --format=%ct "$2" 2>/dev/null)" || { echo unknown; return; }
  case "$ct" in ''|*[!0-9]*) echo unknown ;; *) echo $(( ($(date +%s) - ct) / 86400 )) ;; esac
}

# One TSV row per item on stdout:
# action reason kind repo path branch tip dirty unpushed pr age_days owner
wi_scan() {
  local repo="$1" top common base def heads pr_known=1 here
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || { echo "error:not-a-git-repo:$repo" >&2; return 3; }
  common="$(_wl_common_dir "$top")" || return 3
  here="$(git rev-parse --show-toplevel 2>/dev/null)"
  def="$(git -C "$top" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  [ -n "$def" ] || def=main
  base="origin/$def"

  if ! heads="$(cd "$top" && hpr_open_pr_heads 2>/dev/null)"; then pr_known=0; heads=""; fi

  local owners; owners="$(wl_list "$top" 2>/dev/null)"
  local stashes; stashes="$(git -C "$top" stash list --format='%gs' 2>/dev/null | sed -n 's/^\(WIP on\|On\) \([^:]*\):.*/\2/p')"

  local wt="" br="" first=1 line
  local -A checked_out=()
  local -a wts=() brs=()
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt="${line#worktree }"; br="(detached)" ;;
      "branch "*)   br="${line#branch refs/heads/}" ;;
      "")           if [ -n "$wt" ]; then
                      if [ "$first" -eq 1 ]; then first=0; else wts+=("$wt"); brs+=("$br"); fi
                      [ "$br" != "(detached)" ] && checked_out["$br"]=1
                    fi; wt="" ;;
    esac
  done < <(git -C "$top" worktree list --porcelain 2>/dev/null; echo)
  # the main checkout's branch is not listed as a branch row of its own
  local mainbr; mainbr="$(git -C "$top" symbolic-ref -q --short HEAD 2>/dev/null)"
  [ -n "$mainbr" ] && checked_out["$mainbr"]=1

  local i path branch tip dirty unpushed pr age owner action reason claim sup abs mtime st up
  for i in "${!wts[@]}"; do
    path="${wts[$i]}"; branch="${brs[$i]}"
    abs="$(_wl_abs "$path" 2>/dev/null)" || abs=""
    if [ -z "$abs" ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' keep path-missing-or-unreadable worktree \
        "$(_wi_clean "$top")" "$(_wi_clean "$path")" "$(_wi_clean "$branch")" - unknown unknown unknown unknown -
      continue
    fi
    tip="$(git -C "$path" rev-parse HEAD 2>/dev/null || echo unknown)"
    st="$(git -C "$path" status --porcelain 2>/dev/null)"; local strc=$?
    dirty=no; [ -n "$st" ] && dirty=yes
    up="$(git -C "$path" rev-list --count '@{upstream}..HEAD' 2>/dev/null)" || up=""
    if [ -n "$up" ]; then unpushed="$up"; else unpushed="no-upstream"; fi
    age="$(_wi_age_days "$path" HEAD)"
    owner="$(printf '%s\n' "$owners" | awk -F'\t' -v p="$abs" '$2==p{print $1; exit}')"; [ -n "$owner" ] || owner=-
    if [ "$pr_known" -eq 0 ]; then pr=unknown
    elif printf '%s\n' "$heads" | awk -F'\t' -v b="$branch" '$2==b{f=1} END{exit !f}'; then pr=open
    else pr=none; fi
    claim="$(roc_claim_state "$path" 2>/dev/null)"

    action=""; reason=""
    if [ "$strc" -ne 0 ]; then action=keep; reason=status-unreadable
    elif [ -n "$here" ] && [ "$abs" = "$(_wl_abs "$here" 2>/dev/null)" ]; then action=continue; reason=current-session
    elif [ "$claim" = "held-fresh" ] || [ "$claim" = "mine" ]; then action=continue; reason=live-claim
    elif mtime="$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null)" && [ -n "$mtime" ] \
         && [ $(( ($(date +%s) - mtime) / 60 )) -lt "${SGE_WT_RECENCY_GUARD_MIN:-10}" ]; then
      action=continue; reason=recently-created
    elif [ "$branch" = "$def" ]; then action=keep; reason=default-branch
    elif [ "$pr" = open ] && [ "$dirty" = yes ]; then action=continue; reason=open-pr-with-uncommitted-changes
    elif [ "$dirty" = yes ]; then action=checkpoint-then-decide; reason=uncommitted-changes
    elif [ "$branch" = "(detached)" ]; then action=keep; reason=detached-head
    elif printf '%s\n' "$stashes" | grep -Fxq -- "$branch"; then action=keep; reason=attributed-stash
    elif [ "$pr" = unknown ]; then action=keep; reason=open-pr-lookup-failed
    elif [ "$pr" = open ]; then action=continue; reason=open-pr
    else
      sup="$(rg_supersession "$path" "$base" 2>/dev/null | sed -n 's/^verdict://p')"
      case "$sup" in
        superseded) action=delete; reason=superseded-by-base-record-tip-sha ;;
        live)       action=open-a-pr; reason=unmerged-work-confirm-linked-issue-open ;;
        *)          action=keep; reason=supersession-unknown ;;
      esac
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$action" "$reason" worktree \
      "$(_wi_clean "$top")" "$(_wi_clean "$path")" "$(_wi_clean "$branch")" "$tip" "$dirty" "$unpushed" "$pr" "$age" "$(_wi_clean "$owner")"
  done

  # local branches with no worktree
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    [ -z "${checked_out[$branch]:-}" ] || continue
    [ "$branch" != "$def" ] || continue
    tip="$(git -C "$top" rev-parse "refs/heads/$branch" 2>/dev/null || echo unknown)"
    up="$(git -C "$top" rev-list --count "refs/heads/$branch@{upstream}..refs/heads/$branch" 2>/dev/null)" || up=""
    if [ -n "$up" ]; then unpushed="$up"; else unpushed="no-upstream"; fi
    age="$(_wi_age_days "$top" "refs/heads/$branch")"
    if [ "$pr_known" -eq 0 ]; then pr=unknown
    elif printf '%s\n' "$heads" | awk -F'\t' -v b="$branch" '$2==b{f=1} END{exit !f}'; then pr=open
    else pr=none; fi
    if printf '%s\n' "$stashes" | grep -Fxq -- "$branch"; then action=keep; reason=attributed-stash
    elif [ "$pr" = unknown ]; then action=keep; reason=open-pr-lookup-failed
    elif [ "$pr" = open ]; then action=continue; reason=open-pr
    else
      sup="$(_wi_branch_supersession "$top" "$branch" "$base")"
      case "$sup" in
        superseded) action=delete; reason=superseded-by-base-record-tip-sha ;;
        live)       action=open-a-pr; reason=unmerged-work-confirm-linked-issue-open ;;
        *)          action=keep; reason=supersession-unknown ;;
      esac
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$action" "$reason" branch \
      "$(_wi_clean "$top")" - "$(_wi_clean "$branch")" "$tip" - "$unpushed" "$pr" "$age" -
  done < <(git -C "$top" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
}

wi_json() { # TSV on stdin -> JSON array
  jq -R -s '
    split("\n") | map(select(length > 0) | split("\t")) | map({
      action: .[0], reason: .[1], kind: .[2], repo: .[3],
      path: (if .[4] == "-" then null else .[4] end), branch: .[5], tip: .[6],
      dirty: .[7], unpushed: .[8], pr: .[9], age_days: .[10],
      owner: (if .[11] == "-" then null else .[11] end)
    })'
}

wi_human() { # TSV on stdin -> short list, one suggested action per line
  local a r k repo p b tip d u pr age o n=0
  while IFS=$'\t' read -r a r k repo p b tip d u pr age o; do
    [ -n "$a" ] || continue
    n=$((n + 1))
    printf '%-22s %s %s (%s)\n    repo=%s tip=%s dirty=%s unpushed=%s pr=%s age=%sd owner=%s\n    why: %s\n' \
      "$a" "$k" "$b" "$([ "$p" = - ] && echo no-worktree || echo "$p")" "$repo" "${tip:0:12}" "$d" "$u" "$pr" "$age" "$o" "$r"
  done
  [ "$n" -gt 0 ] || echo "nothing open"
  echo "(suggestions only: nothing is deleted, pushed or opened without a confirmed plan)"
}

wi_main() {
  local mode=human out="" repos=() rc=0 tsv r one one
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) mode=json ;;
      --json-out) shift; out="${1:-}"; [ -n "$out" ] || { echo "usage: --json-out <file>" >&2; return 2; } ;;
      -*) echo "usage: inbox.sh [--json] [--json-out <file>] [<repo-dir> ...]" >&2; return 2 ;;
      *) repos+=("$1") ;;
    esac
    shift
  done
  if [ "${#repos[@]}" -eq 0 ] && [ -n "${SGE_INBOX_REPOS:-}" ]; then
    local IFS=':'; read -r -a repos <<<"$SGE_INBOX_REPOS"; unset IFS
  fi
  [ "${#repos[@]}" -gt 0 ] || repos=(.)
  tsv=""
  for r in "${repos[@]}"; do
    one="$(wi_scan "$r")" || rc=3
    [ -z "$one" ] || tsv+="$one"$'\n'
  done
  [ -z "$out" ] || printf '%s' "$tsv" | wi_json >"$out"
  if [ "$mode" = json ]; then printf '%s' "$tsv" | wi_json; else printf '%s' "$tsv" | wi_human; fi
  return $rc
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then wi_main "$@"; exit $?; fi
