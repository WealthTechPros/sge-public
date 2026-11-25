#!/usr/bin/env bash
# reclaim.sh: deterministic bulk worktree reclaim (sge#3697). There is no model
# in the loop. It is built for hundreds of abandoned worktrees in one pass. Run
# it from a plain terminal (Git Bash on Windows) with every agent session closed.
#
#   reclaim.sh --recovery <csv> [--confirm "RECLAIM <n>"] [--multi <parent-dir>] [<repo-dir> ...]
#   reclaim.sh --dry-run [--multi <parent-dir>] [<repo-dir> ...]
#
# Each audit makes one fetch, one open-PR read and one completed-PR index per
# repo. A confirmed run refreshes the open-PR set before making snapshots. Each linked worktree gets one
# class:
#   RECLAIM           clean, and merged into the default branch or the head of
#                     a completed PR (audit bucket A). No open PR, past the
#                     recency guard, no lease within its TTL, not git-locked.
#   SNAPSHOT+RECLAIM  the same guards hold, it is on a branch, and its work is
#                     either uncommitted or not in the default branch (buckets
#                     B and D, or uncommitted changes). The work is committed
#                     first through a temporary index to
#                     refs/sge/rescue/<ts>/<branch>: tracked changes and
#                     untracked files, never ignored files.
#   UNKNOWN           anything else: open PR, live lease, recent, git-locked,
#                     detached HEAD, a stash on its branch, an unknown PR
#                     state, staged changes, ignored files, Windows directory
#                     reparse points, or the main or current checkout. Listed only.
#
# Order of safety:
#   1. It refuses (exit 5) while any claude or copilot process is running.
#   2. Any failed fetch, failed host lookup or refused audit stops the run
#      (exit 3) before anything is written.
#   3. The recovery CSV (one row per reclaimable worktree, with its tip, the
#      snapshot ref and a restore command) is written first, exclusively.
#   4. One confirmation: the exact text `RECLAIM <n>`, typed on stdin or given
#      with --confirm. Anything else exits 1 with nothing touched.
#   5. Each snapshot runs under the shared lease lock after identity and
#      coverage checks. The verified rescue ref is created without changing
#      the original checkout.
#   6. The executor parks each approved registered checkout in an exclusively
#      created sibling directory. It keeps the contents and the branch.
#      The CSV records the parked path and a reverse move.
#
# Output: `CLASS <repo> <class> <name> <path> <tip12> <reason>` per worktree,
# then SNAPSHOT lines, execute.sh's own lines and its SUMMARY.
# Exit: 0 ran, 1 not confirmed, 2 usage, 3 audit failed (nothing done),
#       4 recovery CSV refused, 5 process safety refusal, 6 incomplete reclaim.
#
# Names and paths come from git and are untrusted DATA: validated, only ever
# passed as quoted arguments, never eval'd.
set -u

_RC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# execute.sh brings _tx_link_guard, _tx_safe_name, _tx_real and _tx_csv;
# lease-lock.sh the shared lease lock (sge#3697) that every lease writer takes.
# shellcheck source=/dev/null
source "$_RC_HERE/execute.sh"
# shellcheck source=/dev/null
source "$_RC_HERE/../worktrees/lease-lock.sh"

_rc_usage() { sed -n '6,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; return 2; }

# Lists running processes, one per line (name and command line). Non-zero when
# the list cannot be read. Tests give a fixed list in SGE_RECLAIM_PS_FILE.
_rc_processes() {
  if [ -n "${SGE_RECLAIM_PS_FILE:-}" ]; then cat -- "$SGE_RECLAIM_PS_FILE"; return; fi
  if _tx_is_win; then
    local ps
    ps="$(command -v powershell.exe 2>/dev/null || command -v pwsh 2>/dev/null)"
    if [ -n "$ps" ]; then
      "$ps" -NoProfile -NonInteractive -Command \
        'Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object { "$($_.Name) $($_.CommandLine)" }' 2>/dev/null
      return
    fi
    # An executable-only listing cannot identify node-hosted agents.
    return 2
  fi
  ps -A -o comm= -o args= 2>/dev/null
}

# 0 when a Claude Code or Copilot CLI process is running (native or node-hosted),
# 2 when the process list cannot be read or is empty (the caller refuses: fail closed).
_rc_agent_running() {
  local list
  list="$(_rc_processes)" || return 2
  list="${list//$'\r'/}"
  [ -n "$list" ] || return 2
  if grep -Eiq \
    '(^|[/\\" ])(claude|copilot)(\.exe)?("|[[:space:]]|$)|@anthropic-ai[/\\]claude-code|@github[/\\]copilot' <<<"$list"; then
    return 0
  fi
  if _tx_is_win && grep -Eiq '^[[:blank:]]*node(\.exe)?[[:blank:]]*$' <<<"$list"; then
    return 2
  fi
  return 1
}

_rc_require_no_agents() {
  local status=0
  _rc_agent_running || status=$?
  case "$status" in
    1) return 0 ;;
    0) echo "refusing: a claude or copilot process is running; close every agent session and run this from a plain terminal" >&2 ;;
    *) echo "refusing: cannot list running processes to rule out a live agent session" >&2 ;;
  esac
  return 5
}

_rc_keep_reason() {
  case "$1" in *.sge-parked-*/*) echo already-parked; return ;; esac
  local real cwd dirs
  real="$(_tx_real "$1")" && cwd="$(pwd -P)" || { echo path-unreadable; return; }
  case "$cwd/" in "$real/"*) echo current-checkout; return ;; esac
  dirs="$(git -C "$1" rev-parse --path-format=absolute --git-dir --git-common-dir)" || { echo git-dir-unreadable; return; }
  [ "${dirs%%$'\n'*}" != "${dirs#*$'\n'}" ] || { echo main-worktree; return; }
  _tx_index_visible "$1" || { echo hidden-or-unreadable-index; return; }
  _tx_link_guard "$1" preserve >/dev/null || { echo directory-link-or-unreadable; return; }
  _tx_ignored_free "$1" || { echo ignored-files; return; }
  git -C "$1" diff --cached --quiet -- || { echo staged-changes-or-unreadable-index; return; }
  _rc_claim_free "$1" || { echo live-claim; return; }
  _tx_recent_reason "$1"
}

# <audit.json> -> TSV rows "repo class name path tip reason" for each worktree.
_rc_classify() {
  local audit="$1" repositories repo def locked classified row cls name path tip why
  repositories="$(jq -r '
    .[] | [.repo, (.default_branch // "")]
    | if (.[0] | type) != "string" or .[0] == "" then error("invalid repository ID")
      elif (.[0] | contains("::")) or any(.[]; test("[\t\r\n]") or (explode | index(0) != null))
      then error("unsupported character or selector delimiter in repository ID")
      else join("\t") end' "$audit")" || return 1
  while IFS=$'\t' read -r repo def; do
    [ -n "$repo" ] || continue
    # git-locked worktree paths and stashed branch names, for the UNKNOWN rule
    locked="$(git -C "$repo" worktree list --porcelain 2>/dev/null | tr -d '\r' \
      | awk '/^worktree /{p=substr($0,10)} /^locked/{print p}')"
    classified="$(jq -r --arg repo "$repo" --arg locked "$locked" '
      .[] | select(.repo == $repo) as $r
      | ($locked | split("\n") | map(select(length > 0))) as $lk
      | ([$r.items[] | select(.kind == "stash") | .reason | ltrimstr("stash-on-branch:")]) as $stashed
      | $r.items[] | select(.kind == "worktree")
      | . as $i
      | (if ($i.path // "") == "" then ["UNKNOWN", "no-path"]
         elif ($i.path | IN($lk[])) then ["UNKNOWN", "git-locked"]
         elif $i.name == "(detached)" then ["UNKNOWN", "detached-head"]
         elif ($i.name | IN($stashed[])) then ["UNKNOWN", "stash-on-branch"]
         elif ($i.pr_state | IN("open", "unknown")) then ["UNKNOWN", "pr-" + $i.pr_state]
         elif $i.bucket == "A" and $i.dirty != "yes" then ["RECLAIM", $i.reason]
         elif ($i.bucket | IN("B", "D")) and $i.dirty != "yes" then ["SNAPSHOT+RECLAIM", $i.sub_verdict]
         elif $i.reason == "uncommitted-changes" and $i.dirty == "yes" then ["SNAPSHOT+RECLAIM", "uncommitted-changes"]
         else ["UNKNOWN", $i.sub_verdict] end) as $c
      | [$repo, $c[0], $i.name, $i.path, $i.tip, $c[1]] | map(. // "" | tostring)
      | if any(.[]; test("[\t\r\n]") or (explode | index(0) != null)) then error("unsupported control character in audit field")
        else join("\t") end' "$audit")" || return 1
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      IFS=$'\t' read -r _ cls name path tip why <<<"$row"
      if [ "$cls" != UNKNOWN ] && _tx_protected "$name" "$def"; then
        printf '%s\tUNKNOWN\t%s\t%s\t%s\tprotected\n' "$repo" "$name" "$path" "$tip"
      else
        printf '%s\n' "$row"
      fi
    done <<<"$classified"
  done <<<"${repositories//$'\r'/}"
}

# <worktree> -> 0 when its .sge-wt-claim lease is absent or older than its TTL
# (roc_claim_state). A claim that is not exactly one "<owner> <epoch>" line
# counts as live (fail closed), as in execute.sh.
_rc_claim_free() {
  local f="$1/.sge-wt-claim" c re=$'^[^[:space:]]+ [0-9]+\n$'
  if [ -e "$f" ] || [ -L "$f" ]; then
    [ -f "$f" ] && [ ! -L "$f" ] || return 1
    [ "$(wc -c <"$f" 2>/dev/null)" -le 4096 ] 2>/dev/null || return 1
    # Exactly one "<owner> <epoch>\n" line, as execute.sh checks: claim-state
    # reads only the first line, so more data must not pass as an expired lease.
    c="$(cat "$f" 2>/dev/null; echo x)" || return 1
    c="${c%x}"
    [[ "$c" =~ $re ]] || return 1
  fi
  [ "$(SGE_AGENT_ID='' bash "$_RC_HERE/../worktrees/resume-or-create.sh" claim-state "$1" 2>/dev/null | tr -d '\r')" = free ]
}

# <repo> <worktree> -> 0 only when Git confirms it is registered and unlocked.
_rc_unlocked_legacy() {
  local common admin backlink actual
  git -C "$1" worktree list --porcelain >/dev/null 2>&1 || return 1
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  admin="$(git -C "$2" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  common="$(_tx_real "${common%$'\r'}")"
  admin="$(_tx_real "${admin%$'\r'}")"
  [ -n "$common" ] && [ "${admin%/*}" = "$common/worktrees" ] || return 1
  [ -f "$admin/gitdir" ] && [ ! -L "$admin/gitdir" ] || return 1
  backlink="$(cat -- "$admin/gitdir" 2>/dev/null)" || return 1
  backlink="${backlink%$'\r'}"
  [ "${backlink##*/}" = ".git" ] || return 1
  actual="$(_tx_real "${backlink%/*}")"
  [ -n "$actual" ] && [ "$actual" = "$3" ] &&
    [ ! -e "$admin/locked" ] && [ ! -L "$admin/locked" ]
}

# <repo> <worktree> -> 0 only when Git confirms it is registered and unlocked.
_rc_unlocked() {
  local want field path="" found=0
  want="$(_tx_real "$2")"
  [ -n "$want" ] || return 1
  while IFS= read -r -d '' field; do
    case "$field" in
      "worktree "*) path="$(_tx_real "${field#worktree }")" ;;
      locked|"locked "*) [ "$path" != "$want" ] || return 1 ;;
      "") [ "$path" != "$want" ] || found=1; path="" ;;
      sge-worktree-list-complete) [ "$found" -eq 1 ]; return ;;
    esac
  done < <(git -C "$1" worktree list --porcelain -z 2>/dev/null && printf 'sge-worktree-list-complete\0')
  _rc_unlocked_legacy "$1" "$2" "$want"
}

_rc_check_identity() {
  local path="$1" branch="$2" tip="$3" cur
  cur="$(git -C "$path" rev-parse --verify --quiet HEAD 2>/dev/null)" &&
    [ "${cur%$'\r'}" = "$tip" ] || { echo tip-changed; return 1; }
  cur="$(git -C "$path" symbolic-ref -q --short HEAD 2>/dev/null)" &&
    [ "${cur%$'\r'}" = "$branch" ] || { echo branch-changed; return 1; }
}

# <repo> <path> <branch> <tip> <ref> -> creates <ref> holding the worktree's
# work without modifying the checkout. Non-zero = not eligible for parking.
_rc_snapshot() {
  local repo="$1" path="$2" branch="$3" tip="$4" ref="$5" gd idx tree commit cur
  ! _tx_protected "$branch" "${6:-}" || { echo protected; return 1; }
  sge_lease_lock "$path" || { echo "lease-lock-busy"; return 1; }
  cur="$(_rc_check_identity "$path" "$branch" "$tip")" || { sge_lease_unlock; echo "$cur"; return 1; }
  _rc_unlocked "$repo" "$path" || { sge_lease_unlock; echo "locked-or-unverifiable"; return 1; }
  cur="$(_rc_keep_reason "$path")"
  [ -z "$cur" ] || { sge_lease_unlock; echo "$cur"; return 1; }
  # Git stores native symlinks as link entries and does not follow their targets.
  gd="$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null | tr -d '\r')" || { sge_lease_unlock; echo "git-dir"; return 1; }
  idx="$gd/sge-reclaim-index.$$"
  rm -f -- "$idx"
  tree="$(GIT_INDEX_FILE="$idx" git -C "$path" read-tree HEAD 2>/dev/null \
    && GIT_INDEX_FILE="$idx" git -C "$path" add -A -- . ':(exclude).sge-wt-claim' 2>/dev/null \
    && GIT_INDEX_FILE="$idx" git -C "$path" write-tree 2>/dev/null)"
  rm -f -- "$idx"
  tree="$(printf '%s' "$tree" | tr -d '\r')"
  [[ "$tree" =~ ^[0-9a-f]{40}$ ]] || { sge_lease_unlock; echo "snapshot-tree-failed"; return 1; }
  sge_lease_touch
  if [ "$tree" = "$(git -C "$path" rev-parse "$tip^{tree}" 2>/dev/null | tr -d '\r')" ]; then
    commit="$tip" # nothing uncommitted: the rescue ref holds the tip itself
  else
    commit="$(GIT_AUTHOR_NAME=sge-reclaim GIT_AUTHOR_EMAIL=sge-reclaim@localhost \
      GIT_COMMITTER_NAME=sge-reclaim GIT_COMMITTER_EMAIL=sge-reclaim@localhost \
      git -C "$path" commit-tree "$tree" -p "$tip" -m "sge reclaim snapshot of $branch (uncommitted work)" 2>/dev/null | tr -d '\r')"
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { sge_lease_unlock; echo "snapshot-commit-failed"; return 1; }
  fi
  # create-only: an existing ref of that name is never overwritten
  git -C "$repo" update-ref "$ref" "$commit" 0000000000000000000000000000000000000000 2>/dev/null \
    || { sge_lease_unlock; echo "snapshot-ref-exists"; return 1; }
  [ "$(git -C "$repo" rev-parse "$ref^{tree}" 2>/dev/null | tr -d '\r')" = "$tree" ] \
    || { sge_lease_unlock; echo "snapshot-verify-failed"; return 1; }
  cur="$(_rc_check_identity "$path" "$branch" "$tip")" || { sge_lease_unlock; echo "$cur snapshot=$ref"; return 1; }
  cur="$(_rc_keep_reason "$path")"
  [ -z "$cur" ] || { sge_lease_unlock; echo "$cur snapshot=$ref"; return 1; }
  sge_lease_unlock
  echo "$commit"
}

_rc_parking_plan() { # <selection file> <audit JSON>
  jq --rawfile sel "$1" '
    INDEX($sel | split("\n")[] | select(length > 0); .) as $selected
    | map(.repo as $r | .items |= map(
        if .kind == "worktree" and $selected[$r + "::worktree:" + .name + "@" + .tip] != null and (.bucket != "A" or .dirty == "yes")
        then .bucket = "B" else . end))' "$2"
}

rc_main() {
  local repos=() rec="" confirm="" dry=0 multi="" tmp audit rows n typed ts
  while [ $# -gt 0 ]; do
    case "$1" in
      --recovery) shift; rec="${1:-}"; [ -n "$rec" ] || { _rc_usage; return 2; } ;;
      --confirm) shift; confirm="${1:-}"; [ -n "$confirm" ] && [[ "$confirm" != --* ]] || { _rc_usage; return 2; } ;;
      --dry-run) dry=1 ;;
      --multi) shift; [ -d "${1:-}" ] || { _rc_usage; return 2; }; multi="$1" ;;
      -*) _rc_usage; return 2 ;;
      *) repos+=("$1") ;;
    esac
    shift
  done
  [ "$dry" -eq 1 ] || [ -n "$rec" ] || { _rc_usage; return 2; }
  command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; return 2; }

  # 1. No agent may be running: a live session's worktree could look abandoned.
  _rc_require_no_agents || return $?

  # 2. One audit per repo (one fetch, one open-PR read, one completed-PR index).
  tmp="$(mktemp -d)" || return 3
  _RC_TMP="$tmp"; trap 'rm -rf -- "$_RC_TMP"' EXIT # every exit path, dry run included
  audit="$tmp/audit.json"
  local aargs=(--fetch --json-out "$audit")
  [ -z "$multi" ] || aargs+=(--multi "$multi")
  [ "${#repos[@]}" -gt 0 ] || [ -n "$multi" ] || repos=(.)
  SGE_TIDY_BULK_COMPLETED="${SGE_TIDY_BULK_COMPLETED:-1}" bash "$_RC_HERE/audit.sh" "${aargs[@]}" "${repos[@]}" >/dev/null 2>"$tmp/audit.err" \
    || { cat "$tmp/audit.err" >&2; echo "audit failed: nothing reclaimed" >&2; return 3; }
  if [ "$(jq '[.[] | select(.refused != false)] | length' "$audit" | tr -d '\r')" != 0 ]; then
    jq -r '.[] | select(.refused != false) | "refused: \(.repo): open-PR set unknown"' "$audit" >&2
    echo "audit refused: nothing reclaimed" >&2; return 3
  fi

  local repo cls name path tip why keep classified
  classified="$(_rc_classify "$audit")" || { echo "cannot classify the audit JSON" >&2; return 3; }
  rows="$(while IFS=$'\t' read -r repo cls name path tip why; do
    [ -n "$repo" ] || continue
    if [ "$cls" != UNKNOWN ]; then
      keep="$(_rc_keep_reason "$path")"
      if [ -n "$keep" ]; then cls=UNKNOWN; why="$keep"; fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$cls" "$name" "$path" "$tip" "$why"
  done <<<"$classified")"
  while IFS=$'\t' read -r repo cls name path tip why; do
    [ -n "$repo" ] || continue
    printf 'CLASS\t%s\t%s\t%s\t%s\t%s\t%s\n' "${repo##*/}" "$cls" "$name" "$path" "${tip:0:12}" "$why"
  done <<<"$rows"
  n="$(printf '%s\n' "$rows" | awk -F'\t' '$2=="RECLAIM" || $2=="SNAPSHOT+RECLAIM"' | grep -c .)"
  echo "RECLAIMABLE $n (RECLAIM $(printf '%s\n' "$rows" | awk -F'\t' '$2=="RECLAIM"' | grep -c .), SNAPSHOT+RECLAIM $(printf '%s\n' "$rows" | awk -F'\t' '$2=="SNAPSHOT+RECLAIM"' | grep -c .)); UNKNOWN $(printf '%s\n' "$rows" | awk -F'\t' '$2=="UNKNOWN"' | grep -c .)"
  if [ "$dry" -eq 1 ] || [ "$n" -eq 0 ]; then return 0; fi

  # 3. Recovery CSV first, created exclusively.
  ts="$(date -u +%Y%m%dT%H%M%SZ)-${tmp##*.}"
  [ ! -e "$rec" ] || { echo "recovery file exists, refusing to overwrite: $rec" >&2; return 4; }
  local parking_id="${tmp##*.}" qr qref qfresh snapref parked restore snapshot_restore
  ( set -C
  {
    echo 'repo,class,name,path,tip,snapshot_ref,parked_path,restore,snapshot_restore'
    while IFS=$'\t' read -r repo cls name path tip why; do
      [ "$cls" = RECLAIM ] || [ "$cls" = SNAPSHOT+RECLAIM ] || continue
      parked="$(_tx_parked_path "$path" "$parking_id")" || exit 1
      restore="$(_tx_reverse_move "$repo" "$path" "$parked")"
      snapref=-; snapshot_restore=-
      if [ "$cls" = SNAPSHOT+RECLAIM ]; then
        snapref="refs/sge/rescue/$ts/$name"
        printf -v qr '%q' "$repo"; printf -v qref '%q' "$snapref^{commit}"
        printf -v qfresh '%q' "$path.sge-recovered-XXXXXX"
        snapshot_restore="snapshot=\$(git -C $qr rev-parse --verify $qref) && fresh=\$(mktemp -d -- $qfresh) && git -C $qr worktree add --detach \"\$fresh\" \"\$snapshot\" && printf 'RECOVERED\\t%s\\n' \"\$fresh\""
      fi
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(_tx_csv "$repo")" "$cls" "$(_tx_csv "$name")" "$(_tx_csv "$path")" \
        "$(_tx_csv "$tip")" "$(_tx_csv "$snapref")" "$(_tx_csv "$parked")" "$(_tx_csv "$restore")" "$(_tx_csv "$snapshot_restore")"
    done <<<"$rows"
  } >"$rec" ) 2>/dev/null && [ "$(wc -l <"$rec" | tr -d ' ')" -eq $((n + 1)) ] \
    || { echo "cannot write the recovery CSV: $rec" >&2; return 4; }
  echo "RECOVERY $rec"

  # 4. One confirmation for the whole plan.
  if [ -n "$confirm" ]; then typed="$confirm"
  else
    printf 'Type RECLAIM %s to reclaim %s worktree(s); anything else stops: ' "$n" "$n" >&2
    IFS= read -r typed || typed=""
  fi
  typed="${typed%$'\r'}"
  [ "$typed" = "RECLAIM $n" ] || { echo "not confirmed: nothing reclaimed (recovery CSV kept: $rec)" >&2; return 1; }
  _rc_require_no_agents || return $?

  # 5. Snapshots. A failed snapshot drops that worktree from the parking plan.
  local sel="$tmp/select.txt" exec_rec="${rec%.csv}.execute.csv" out def
  # Refuse known collisions before snapshotting. The executor still creates
  # this journal exclusively, including if another caller creates it later.
  if [ -e "$exec_rec" ] || [ -L "$exec_rec" ]; then
    echo "executor recovery file exists, refusing to overwrite: $exec_rec" >&2
    return 4
  fi
  # Refresh each selected repo before changing anything in any repo.
  local -A queried=() open_heads=()
  local open_prs number branch
  while IFS=$'\t' read -r repo cls name path tip why; do
    [ "$cls" != UNKNOWN ] && [ -n "$repo" ] || continue
    [ -z "${queried[$repo]+yes}" ] || continue
    open_prs="$(_tx_open_prs "$repo")" || { echo "cannot refresh open PRs for $repo" >&2; return 3; }
    queried["$repo"]=1
    while IFS=$'\t' read -r number branch; do
      [ -n "$branch" ] && open_heads["$repo::${branch%$'\r'}"]=1
    done <<<"$open_prs"
  done <<<"$rows"
  : >"$sel"
  while IFS=$'\t' read -r repo cls name path tip why; do
    if [ "$cls" != UNKNOWN ] && [ -n "${open_heads[$repo::$name]+yes}" ]; then
      printf 'SKIP\t%s\tworktree\t%s\t%s\topen-pr\n' "${repo##*/}" "$name" "${tip:0:12}"
      continue
    fi
    case "$cls" in
      RECLAIM) printf '%s::worktree:%s@%s\n' "$repo" "$name" "$tip" >>"$sel" ;;
      SNAPSHOT+RECLAIM)
        _tx_safe_name "$name" || { printf 'SKIP\t%s\tsnapshot\t%s\t%s\tunsafe-name\n' "${repo##*/}" "$name" "${tip:0:12}"; continue; }
        def="$(jq -r --arg repo "$repo" '.[] | select(.repo == $repo) | (.default_branch // "")' "$audit")" || return 3
        if out="$(_rc_snapshot "$repo" "$path" "$name" "$tip" "refs/sge/rescue/$ts/$name" "${def%$'\r'}")"; then
          printf 'SNAPSHOT\t%s\tworktree\t%s\t%s\trefs/sge/rescue/%s/%s\t%s\n' "${repo##*/}" "$name" "${tip:0:12}" "$ts" "$name" "${out:0:12}"
          printf '%s::worktree:%s@%s\n' "$repo" "$name" "$tip" >>"$sel"
        else
          printf 'SKIP\t%s\tsnapshot\t%s\t%s\t%s\n' "${repo##*/}" "$name" "${tip:0:12}" "$out"
        fi ;;
    esac
  done <<<"$rows"

  # 6. Reversible parking through execute.sh. Bucket B carries a verified rescue ref.
  _rc_parking_plan "$sel" "$audit" >"$tmp/reclaim-audit.json" \
    || { echo "cannot build the parking plan" >&2; return 3; }
  local xrc=0
  if [ -s "$sel" ]; then
    _SGE_BULK_RECLAIM=1 _SGE_PARKING_ID="$parking_id" bash "$_RC_HERE/execute.sh" --audit "$tmp/reclaim-audit.json" --buckets A,B --select-file "$sel" \
      --recovery "$exec_rec" || xrc=$?
  fi
  [ "$xrc" -eq 0 ] || return "$xrc"
  local selected_count
  selected_count="$(wc -l <"$sel")" || return 3
  if [ "$selected_count" -ne "$n" ]; then
    echo "reclaim incomplete: $selected_count of $n approved worktrees passed snapshot checks" >&2
    return 6
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then rc_main "$@"; exit $?; fi
