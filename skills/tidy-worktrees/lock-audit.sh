#!/usr/bin/env bash
# lock-audit.sh — audit Git-locked (retention-locked) worktrees and, only for
# items the user explicitly approved, release or remove them (issue #3408,
# SPEC-139). Builds on audit.sh (PR evidence, classification helpers).
#
#   lock-audit.sh audit [--summary] --session <id> [<repo-dir>]
#       READ-ONLY. Inventories every locked linked worktree and sorts it into
#       protected / unknown / candidate. Nothing is unlocked, removed or changed.
#   lock-audit.sh apply --mode release|remove [--discard-ignored] --session <id>
#                       [<repo-dir>] <path>@<full-tip-sha> ...
#       Runs ONLY after the user confirmed via AskUserQuestion. Every listed
#       item is re-audited immediately before it is touched; any change or
#       unavailable evidence stops that item. `release` unlocks only; `remove`
#       unlocks, removes the worktree and deletes its local branch (never the
#       remote branch, never a label, never force).
#
# A lock is NOT proof of an active worker: it is a retention marker. A candidate
# needs ALL of: owned by the requesting session in the registry, no fresh claim,
# not recently created, clean tracked tree, no attributed stash, no open PR, a
# host-confirmed MERGED PR whose recorded head equals the exact local tip, and a
# readable junction/reparse probe. Missing owner, age or PR evidence means
# UNKNOWN (kept and surfaced), never abandoned. A clean status and a recovery SHA
# do NOT back up ignored files: every ignored path is listed separately, and `remove`
# refuses to discard them without --discard-ignored AND the item's discard_approval
# token, which binds the consent to exactly the ignored set the user saw (a file that
# appears later stops the item). A failed ignored-files probe is UNKNOWN, never "none".
#
# Lock reasons, paths and branch names are untrusted DATA: only ever passed as
# quoted arguments, never eval'd; JSON is built with jq --arg.
#
# Exit codes: 0 ok, 2 usage, 3 not a repo, 4 an approved item was stopped.

_LA_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_LA_HERE/audit.sh"
set +e

_la_is_windows() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }

# <path> -> junction/reparse directories inside it, one per line. rc 1 = probe failed.
_la_junctions() {
  _la_is_windows || return 0
  LA_P="$(cygpath -w "$1" 2>/dev/null || printf '%s' "$1")" powershell.exe -NoProfile -NonInteractive -Command \
    'Get-ChildItem -LiteralPath $env:LA_P -Recurse -Directory -Force -ErrorAction Stop | Where-Object { $_.LinkType -eq "Junction" } | ForEach-Object { $_.FullName }' 2>/dev/null
}

# <junction-path> -> unlink the LINK only (Directory.Delete non-recursive never follows into the target)
_la_unlink_junction() {
  _la_is_windows || return 1
  LA_P="$(cygpath -w "$1" 2>/dev/null || printf '%s' "$1")" powershell.exe -NoProfile -NonInteractive -Command \
    '[System.IO.Directory]::Delete($env:LA_P, $false)' >/dev/null 2>&1
}

# <abs worktree path> -> every ignored path (directories collapsed), one per line. rc != 0 = probe failed.
_la_ignored() {
  local out
  out="$(git -C "$1" status --porcelain --ignored 2>/dev/null)" || return 1
  printf '%s\n' "$out" | sed -n 's/^!! //p'
}

# <abs worktree path> -> mtime epoch seconds (empty when unreadable)
_la_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# <abs git dir of a worktree> -> whole days since its `locked` file changed, or -
_la_lock_age() {
  local f="$1/locked" m
  [ -f "$f" ] || { echo -; return; }
  m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) echo -; return ;; esac
  echo $(( ($(date +%s) - m) / 86400 ))
}

# TSV rows (18 columns, "-" for empty) for each locked linked worktree of the repo
# in cwd. $1 = requesting session id.
_la_rows() { # <sid> [only-path]
  local sid="$1" only="${2:-}" top common def base here owners stashes
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 3
  common="$(_wl_common_dir "$top")" || return 3
  here="$(_wl_abs "$top")"
  def="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"; [ -n "$def" ] || def=main
  base="origin/$def"
  owners="$(wl_list "$top" 2>/dev/null)"
  stashes="$(git stash list --format='%gs' 2>/dev/null | sed -n 's/^\(WIP on\|On\) \([^:]*\):.*/\2/p')"
  ta_pr_load

  local wt="" br="" lockreason="" islocked=0 first=1 line
  local -a P=() B=() L=() R=()
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt="${line#worktree }"; br="(detached)"; lockreason=""; islocked=0 ;;
      "branch "*) br="${line#branch refs/heads/}" ;;
      locked) islocked=1; lockreason="" ;;
      "locked "*) islocked=1; lockreason="${line#locked }" ;;
      "") if [ -n "$wt" ]; then
            if [ "$first" -eq 1 ]; then first=0
            elif [ "$islocked" -eq 1 ]; then P+=("$wt"); B+=("$br"); L+=("$lockreason"); fi
          fi; wt="" ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null; echo)

  local rec i path branch abs tip st strc dirty gd lage owner ostate claim ign ignrc icount isample idig stash up pr prs prn prhead jl jprobe cls why mtime
  for i in "${!P[@]}"; do
    path="${P[$i]}"; branch="${B[$i]}"
    abs="$(_wl_abs "$path" 2>/dev/null)"
    [ -z "$only" ] || [ "$abs" = "$only" ] || continue
    cls=""; why=""; tip=unknown; dirty=unknown; icount=0; isample=-; idig=-; stash=no; up=-; prs=unknown; prn=-; prhead=-; jl=-; lage=-; owner=-; claim=unknown
    if [ -z "$abs" ]; then
      cls=unknown; why=path-missing-or-unreadable
    else
      tip="$(git -C "$abs" rev-parse HEAD 2>/dev/null)" || tip=unknown
      gd="$(git -C "$abs" rev-parse --absolute-git-dir 2>/dev/null)"; lage="$(_la_lock_age "$gd")"
      st="$(git -C "$abs" status --porcelain 2>/dev/null)"; strc=$?
      dirty=no; [ -n "$st" ] && dirty=yes; [ "$strc" -eq 0 ] || dirty=unknown
      # Ignored files are NOT backed up by a clean status. A failed probe must not read as "none":
      # it makes the whole state unreadable (UNKNOWN), so the item can never reach `remove`.
      ign="$(_la_ignored "$abs")"; ignrc=$?
      [ "$ignrc" -eq 0 ] || dirty=unknown
      icount=0; [ -z "$ign" ] || icount="$(printf '%s\n' "$ign" | grep -c .)"
      # EVERY ignored path (no truncation): the user consents to discarding exactly this set.
      isample="$(printf '%s\n' "$ign" | tr '\n' '|' | sed 's/|$//')"; [ -n "$isample" ] || isample=-
      idig="$(printf '%s\n' "$ign" | LC_ALL=C sort | git hash-object --stdin 2>/dev/null)"; [ -n "$idig" ] || idig=-
      printf '%s\n' "$stashes" | grep -Fxq -- "$branch" && stash=yes
      up="$(git -C "$abs" rev-list --count '@{upstream}..HEAD' 2>/dev/null)" || up=no-upstream
      claim="$(roc_claim_state "$abs" 2>/dev/null)"; [ -n "$claim" ] || claim=unknown
      owner="$(printf '%s\n' "$owners" | awk -F'\t' -v p="$abs" '$2==p{print $1; exit}')"
      ostate=; if [ -z "$owner" ]; then ostate=unrecorded; owner=-
      elif [ "$owner" = "$sid" ]; then ostate=mine; else ostate=foreign; fi
      mtime="$(_la_mtime "$abs")"
      if [ "$branch" != "(detached)" ] && rec="$(ta_pr_record "$branch")"; then
        IFS=$'\t' read -r prs prn prhead <<<"$rec"
      else prs=unknown; fi
      if jl="$(_la_junctions "$abs")"; then jprobe=ok; else jprobe=failed; fi
      jl="$(printf '%s\n' "$jl" | grep . | tr '\n' '|' | sed 's/|$//')"; [ -n "$jl" ] || jl=-
      [ "$jprobe" = ok ] || jl="?"

      if [ "$abs" = "$here" ]; then cls=protected; why=current-session
      elif [ "$branch" = "$def" ]; then cls=protected; why=default-branch
      elif [ "$branch" = "(detached)" ]; then cls=protected; why=detached-head
      elif [ "$tip" = unknown ] || [ "$dirty" = unknown ]; then cls=unknown; why=state-unreadable
      elif [ "$ostate" = foreign ]; then cls=protected; why=foreign-owner
      elif [ "$ostate" = unrecorded ]; then cls=unknown; why=owner-unrecorded
      elif [ "$claim" = held-fresh ] || [ "$claim" = mine ]; then cls=protected; why=live-claim
      elif [ "$claim" = unknown ]; then cls=unknown; why=claim-unreadable
      elif case "$mtime" in ''|*[!0-9]*) true ;; *) false ;; esac \
        || case "${SGE_WT_RECENCY_GUARD_MIN:-10}" in ''|*[!0-9]*) true ;; *) false ;; esac; then
        cls=unknown; why=age-unreadable
      elif [ $(( ($(date +%s) - mtime) / 60 )) -lt "${SGE_WT_RECENCY_GUARD_MIN:-10}" ]; then
        cls=protected; why=recently-created
      elif [ "$dirty" = yes ]; then cls=protected; why=uncommitted-changes
      elif [ "$stash" = yes ]; then cls=protected; why=attributed-stash
      elif [ "$prs" = unknown ]; then cls=unknown; why=pr-lookup-failed
      elif [ "$prs" = open ]; then cls=protected; why=active-pr
      elif ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then cls=unknown; why=base-unresolved
      elif [ "$prs" != merged ]; then cls=protected; why=no-completed-pr
      elif [ "$prhead" != "$tip" ]; then cls=protected; why=tip-differs-from-merged-pr-head
      elif [ "$jprobe" != ok ]; then cls=unknown; why=junction-probe-failed
      else cls=candidate; why=inactive-clean-merged-pr-exact-head; fi
    fi
    [ -n "$lockreason" ] || true
    local f out="" sep=""
    for f in "$path" "$branch" "$tip" "${L[$i]}" "$lage" "$owner" "$claim" "$dirty" "$icount" "$isample" "$idig" "$stash" "$up" "$prs" "$prn" "$prhead" "$jl" "$cls" "$why"; do
      [ -n "$f" ] || f=-
      out+="$sep$(_wi_clean "$f")"; sep=$'\t'
    done
    printf '%s\n' "$out"
  done
}

_la_json() { # <repo> <sid> <host>; TSV on stdin
  jq -R -s --arg repo "$1" --arg sid "$2" --arg host "$3" '
    def nz: if . == "-" then null else . end;
    (split("\n") | map(select(length > 0) | split("\t"))
      | map({path: .[0], branch: .[1], tip: .[2], lock_reason: (.[3] | nz), lock_age_days: (.[4] | nz),
             owner_session: (.[5] | nz), claim: .[6], dirty: .[7], ignored_count: (.[8] | tonumber),
             ignored_paths: ((.[9] | nz) // "" | split("|") | map(select(length > 0))), ignored_digest: .[10],
             attributed_stash: .[11], unpushed: .[12], pr_state: .[13], pr_number: (.[14] | nz), pr_head: (.[15] | nz),
             junctions: (if .[16] == "?" then "probe-failed" else ((.[16] | nz) // "" | split("|") | map(select(length > 0))) end),
             class: .[17], reason: .[18]})) as $items
    | {repo: $repo, requesting_session: $sid, host: $host, items: $items,
       counts: {candidate: ([$items[] | select(.class == "candidate")] | length),
                protected: ([$items[] | select(.class == "protected")] | length),
                unknown: ([$items[] | select(.class == "unknown")] | length)},
       decision: {
         required: ([$items[] | select(.class == "candidate")] | length > 0),
         options: ["keep (no change)", "release locks and re-audit only", "release locks and remove the listed worktrees and local branches"],
         candidates: [$items[] | select(.class == "candidate") | {
           approval: (.path + "@" + .tip), path, branch, recovery_sha: .tip, completed_pr: .pr_number,
           discard_approval: (.path + "@" + .tip + "@" + .ignored_digest),
           ignored_files: {count: .ignored_count, paths: .ignored_paths, digest: .ignored_digest,
                           note: "paths lists EVERY ignored path; they are NOT backed up by a clean status or the recovery SHA; remove discards them, needs --discard-ignored and the discard_approval token (bound to exactly this set)"},
           junctions,
           commands: {
             release: ["git worktree unlock " + (.path | @sh)],
             remove: ["git worktree unlock " + (.path | @sh), "git worktree remove " + (.path | @sh), "git branch -D " + (.branch | @sh)]}}]}}'
}

la_audit() { # <repo> <sid>
  local repo="$1" sid="$2" top rows
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || { echo "error:not-a-git-repo:$repo" >&2; return 3; }
  ( cd "$top" || exit 3
    rows="$(_la_rows "$sid")" || exit 3
    printf '%s\n' "$rows" | _la_json "$top" "$sid" "${_TA_HOST:-unknown}" )
}

# Fresh row for ONE locked worktree path (re-audits everything; empty if not locked).
_la_row_for() { # <top> <sid> <path>
  local want
  want="$(_wl_abs "$3" 2>/dev/null)"; [ -n "$want" ] || return 0
  ( cd "$1" && _la_rows "$2" "$want" )
}

# <repo> <sid> <mode> <discard-ignored yes|no> <path@tip>...  -> JSON results on stdout
la_apply() {
  local repo="$1" sid="$2" mode="$3" discard="$4"; shift 4
  local top; top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || { echo "error:not-a-git-repo:$repo" >&2; return 3; }
  local results="[]" rc=0 item path want
  for item in "$@"; do
    # <path>@<40-hex tip>  or  <path>@<tip>@<40-hex ignored-set digest> (the discard_approval token)
    local wdig=""
    path="${item%@*}"; want="${item##*@}"
    if [[ "$want" =~ ^[0-9a-f]{40}$ ]] && [[ "${path##*@}" =~ ^[0-9a-f]{40}$ ]] && [ "$path" != "${path%@*}" ]; then
      wdig="$want"; want="${path##*@}"; path="${path%@*}"
    fi
    local status=stopped reason="" row cls abs ign idig tip prn branch lr junc j recovery="" disp="none"
    if ! [[ "$want" =~ ^[0-9a-f]{40}$ ]] || [ "$path" = "$item" ]; then
      reason=approval-not-path-at-full-tip-sha
    else
      row="$(_la_row_for "$top" "$sid" "$path")"
      if [ -z "$row" ]; then reason=no-longer-a-locked-worktree
      else
        # fields: path branch tip lockreason age owner claim dirty ignored paths digest stash up prs prn prhead junc class reason
        IFS=$'\t' read -r _ branch tip lr _ _ _ _ ign _ idig _ _ _ prn _ junc cls reason <<<"$row"
        if [ "$cls" != candidate ]; then reason="revalidation-$cls:$reason"
        elif [ "$tip" != "$want" ]; then reason="tip-changed-since-approval"
        elif [ "$mode" = remove ] && [ "$ign" != 0 ] && [ "$discard" != yes ]; then reason="ignored-files-present-need-discard-consent"
        elif [ "$mode" = remove ] && [ "$ign" != 0 ] && [ "$wdig" != "$idig" ]; then reason="ignored-set-changed-since-consent"
        else
          abs="$(_wl_abs "$path")"; recovery="$tip"; reason=""
          [ "$lr" = "-" ] && lr=""
          if ! git -C "$top" worktree unlock "$abs" >/dev/null 2>&1; then reason=unlock-failed
          elif [ "$mode" = release ]; then status=released
          else
            # remove: junction guard first (links only), then remove, then the local branch
            local ok=1 left
            if [ "$junc" != "-" ]; then
              local IFS_OLD="$IFS"; IFS='|'; for j in $junc; do _la_unlink_junction "$j" || ok=0; done; IFS="$IFS_OLD"
              # fail closed: a probe that errors (empty output, rc != 0) is NOT proof the links are gone
              if [ "$ok" -eq 1 ]; then left="$(_la_junctions "$abs")" && [ -z "$left" ] || ok=0; fi
            fi
            if [ "$ok" -eq 1 ] && git -C "$top" worktree remove "$abs" >/dev/null 2>&1 && git -C "$top" worktree prune >/dev/null 2>&1; then
              if git -C "$top" branch -D "$branch" >/dev/null 2>&1; then status=removed
              else status=removed-branch-kept; reason=branch-delete-failed; fi
              [ "$ign" = 0 ] || disp="discarded:$ign"
            else
              reason=remove-failed-lock-restored
              if [ -d "$abs" ]; then
                if [ -n "$lr" ]; then git -C "$top" worktree lock --reason "$lr" "$abs" >/dev/null 2>&1; else git -C "$top" worktree lock "$abs" >/dev/null 2>&1; fi
              fi
            fi
          fi
        fi
      fi
    fi
    [ "$status" = released ] || [ "$status" = removed ] || [ "$status" = removed-branch-kept ] || rc=4
    [ "$mode" = release ] && [ "$status" = released ] && disp="kept"
    results="$(printf '%s' "$results" | jq --arg path "$path" --arg status "$status" --arg reason "$reason" --arg sha "$recovery" \
      --arg pr "${prn:--}" --arg disp "$disp" --arg mode "$mode" \
      '. + [{path: $path, mode: $mode, status: $status, reason: (if $reason == "" then null else $reason end),
             recovery_sha: (if $sha == "" then null else $sha end), completed_pr: (if $pr == "-" then null else $pr end), ignored_disposition: $disp}]')"
    prn=-
  done
  printf '%s\n' "$results"
  return $rc
}

la_summary() { # JSON on stdin
  jq -r '"repo: \(.repo)  session: \(.requesting_session)  host: \(.host)",
    "  candidate \(.counts.candidate)  protected \(.counts.protected)  unknown \(.counts.unknown)",
    (.items[] | "  [\(.class)] \(.branch)  \(.reason)  tip=\(.tip[0:12])  lock-age=\(.lock_age_days // "unknown")d  owner=\(.owner_session // "unknown")  ignored=\(.ignored_count)"),
    "(read-only audit: nothing unlocked, removed or changed; apply runs only on explicit user approval)"'
}

la_main() {
  local cmd="${1:-}"; shift 2>/dev/null
  local sid="" mode="" discard=no summary=0 repo="" items=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) shift; sid="${1:-}" ;;
      --mode) shift; mode="${1:-}" ;;
      --discard-ignored) discard=yes ;;
      --summary) summary=1 ;;
      -*) echo "usage: lock-audit.sh audit|apply --session <id> ..." >&2; return 2 ;;
      *@*) items+=("$1") ;;
      *) repo="$1" ;;
    esac
    shift
  done
  [ -n "$repo" ] || repo=.
  _wl_valid_session "$sid" || { echo "error:bad-or-missing-session-id" >&2; return 2; }
  case "$cmd" in
    audit)
      if [ "$summary" -eq 1 ]; then
        # capture first so la_audit's exit status (e.g. 3 = not a repo) is not hidden by the pipe
        local report arc
        report="$(la_audit "$repo" "$sid")"; arc=$?
        [ "$arc" -eq 0 ] || return "$arc"
        printf '%s\n' "$report" | la_summary
      else la_audit "$repo" "$sid"; fi ;;
    apply)
      case "$mode" in release|remove) ;; *) echo "error:--mode release|remove required" >&2; return 2 ;; esac
      [ "${#items[@]}" -gt 0 ] || { echo "error:no-approved-items: nothing was changed" >&2; return 2; }
      la_apply "$repo" "$sid" "$mode" "$discard" "${items[@]}" ;;
    *) echo "usage: lock-audit.sh audit|apply --session <id> [--mode release|remove] [--discard-ignored] [repo] [path@tip...]" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then la_main "$@"; exit $?; fi
