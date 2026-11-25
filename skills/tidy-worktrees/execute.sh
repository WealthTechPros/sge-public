#!/usr/bin/env bash
# execute.sh: runs an approved tidy delete plan (issue #3621). Deterministic,
# so every host (Claude Code, GitHub Copilot CLI or VS Code agent mode, with
# or without subagents) gets the same safe outcome on any Git host (GitHub,
# Azure DevOps, Forgejo). On Windows run it from Git Bash.
#
#   execute.sh --audit <audit.json> [--audit <file>...]
#              (--select all | --select <token> ... | --select-file <file>)
#              [--buckets A,D|B] [--recovery <csv>] [--remote] [--dry-run]
#
# Input is audit.sh JSON (one array per file, any number of repos). Only A/D
# items that carry plan commands, or B items named by a literal token after an
# explicit discard decision (--buckets B), in repos whose audit was not
# refused, can be selected; C never. Tokens are literal and pinned to the
# audited tip, optionally qualified with the audit's repo path:
#   [<repo>::]<kind>:<name>@<40-hex tip>   kind = worktree | branch | remote-branch
#   [<repo>::]<worktree-path>@<40-hex tip>
# An unqualified token that matches in more than one repo is refused (exit 2).
# `--select all` selects every local (worktree, branch) A/D item and NEVER a B
# item or a remote branch: remote deletion needs --remote AND a literal
# remote-branch:<name>@<tip> token per branch.
#
# Order of safety:
#   1. The recovery CSV (repo, kind, name, path, tip, bucket, reason, restore
#      command) is written BEFORE anything is touched; if it cannot be written,
#      or already exists, nothing runs (exit 4). Created exclusively.
#   2. Per repo: worktrees, then local branches, then remote branches.
#   3. Each item is re-checked immediately before acting: tip unchanged,
#      tracked tree clean, not git-locked, no .sge-wt-claim lease within its TTL
#      (roc_claim_state; an unreadable claim counts as live), not the current
#      checkout, default branch or a protected name. Any failed check or failed
#      lookup is a SKIP, never a deletion.
#   4. The interactive link guard unlinks untracked directory links without
#      following them. Bulk reclaim leaves Windows directory reparse points
#      untouched and parks eligible checkouts with Git without deleting contents.
#   5. `git -c core.longpaths=true worktree remove` without --force; a refusal
#      is a SKIP. Then prune, and `git branch -D` only on a re-confirmed tip.
#   6. A remote branch is deleted only when a fresh per-branch open-PR lookup
#      (hpr_open_pr_heads, fail closed) does not list it, `git ls-remote`
#      still shows the audited tip, and no same-named local branch is left
#      (a local item skipped in this run or an earlier one keeps its remote).
#      The delete carries a lease on the audited tip (compare-and-delete), so
#      a push that lands in between is never deleted.
# It never overwrites a ref, never pushes code and never touches labels or PR
# state; its only host API call is that read-only open-PR lookup.
#
# Output: one tab-separated line per item
#   <DONE|SKIP|GONE|WOULD> <repo> <kind> <name> <tip12> <reason> [<detail>]
# then `SUMMARY: done=N skipped=N gone=N would=N`.
# Exit: 0 ran (SKIPs are normal), 2 usage, 4 recovery CSV refused.
#
# Names and paths come from JSON and are untrusted DATA: validated, only ever
# passed as quoted arguments, never eval'd.
set -u

_TX_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_TX_HERE/../worktrees/lease-lock.sh"
_TX_PROTECTED='^(main|master|develop|trunk|gh-pages|staging|production|prod|dev|stable|next|release/.*|hotfix/.*)$'
[ -z "${SGE_AUDIT_PROTECTED_REGEX:-}" ] || _TX_PROTECTED="$SGE_AUDIT_PROTECTED_REGEX"

_tx_usage() { sed -n '8,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; return 2; }
_tx_is_win() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }
_tx_safe_name() { [[ "$1" =~ ^[A-Za-z0-9._/@+-]+$ ]] && [[ "$1" != -* ]] && [[ "$1" != *..* ]]; }
_tx_csv() { local s="${1//\"/\"\"}"; printf '"%s"' "$s"; }
_tx_real() { [ -n "$1" ] && (cd "$1" 2>/dev/null && pwd -P); } # canonical dir path, empty if missing

_TX_N_DONE=0; _TX_N_SKIP=0; _TX_N_GONE=0; _TX_N_WOULD=0
_tx_out() { # <status> <repo> <kind> <name> <tip> <reason> [<detail>]
  case "$1" in DONE) _TX_N_DONE=$((_TX_N_DONE + 1)) ;; SKIP) _TX_N_SKIP=$((_TX_N_SKIP + 1)) ;;
    GONE) _TX_N_GONE=$((_TX_N_GONE + 1)) ;; WOULD) _TX_N_WOULD=$((_TX_N_WOULD + 1)) ;; esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "${2##*/}" "$3" "$4" "${5:0:12}" "$6" "${7:-}"
}

# Unlink every UNTRACKED directory junction / symlink under <dir> without
# following it. Links git tracks (mode 120000) are left alone: git removes them
# as links, and unlinking one would read as a modification and make git refuse.
# In preserve mode, refuse Windows directory reparse points without unlinking
# anything. Native POSIX symlinks are handled by Git. Prints the number unlinked.
_tx_link_guard() {
  local dir="$1" mode="${2:-}" n=0 l ps skip rc rel ps_mode=()
  if [ "$mode" = preserve ]; then
    if ! _tx_is_win; then
      [ ! -L "$dir" ] || return 1
      echo 0
      return
    fi
    ps_mode=(-CheckOnly)
  fi
  local -; set -o pipefail # a failed ls-files must fail the guard, not read as "no tracked links"
  skip="$(mktemp)" || return 1
  git -C "$dir" ls-files -s -z 2>/dev/null | tr '\0' '\n' | awk '$1 == "120000" { sub(/^[^\t]*\t/, ""); print }' >"$skip" \
    || { rm -f "$skip"; return 1; }
  if _tx_is_win; then
    ps="$(command -v pwsh 2>/dev/null || command -v powershell.exe 2>/dev/null || command -v powershell 2>/dev/null)"
    [ -n "$ps" ] || { rm -f "$skip"; echo "no PowerShell for the junction guard" >&2; return 1; }
    "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$_TX_HERE/junction-guard.ps1")" \
      -Path "$(cygpath -w "$dir")" -SkipFile "$(cygpath -w "$skip")" "${ps_mode[@]}" | tr -d '\r'
    rc="${PIPESTATUS[0]}"
    rm -f "$skip"
    return "$rc"
  fi
  [ ! -L "$dir" ] || { rm -f "$skip"; echo "worktree path is itself a link" >&2; return 1; }
  local list; list="$(mktemp)" || { rm -f "$skip"; return 1; }
  # find never descends into a link; an unreadable subtree fails the guard (closed)
  find "$dir" -type l -print0 >"$list" 2>/dev/null || { rm -f "$list" "$skip"; return 1; }
  while IFS= read -r -d '' l; do
    [ -d "$l" ] || continue # file links and dangling links are removed as links by git
    rel="${l#"$dir"/}"; ! grep -qxF -- "$rel" "$skip" || continue
    rm -- "$l" && [ ! -e "$l" ] && [ ! -L "$l" ] || { rm -f "$list" "$skip"; return 1; } # the link only; never -r
    n=$((n + 1))
  done <"$list"
  rm -f "$list" "$skip"
  echo "$n"
}

_tx_protected() { [ "$1" = "$2" ] || [[ "$1" =~ $_TX_PROTECTED ]]; }

# <repo> <name> <tip> -> deletes refs/heads/<name> only when it still equals <tip>
_tx_branch() {
  local repo="$1" name="$2" tip="$3" cur
  cur="$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$name" 2>/dev/null | tr -d '\r')"
  [ -n "$cur" ] || { echo "GONE"; return; }
  [ "$cur" = "$tip" ] || { echo "SKIP tip-changed now=$cur"; return; }
  [ "$_TX_DRY" -eq 0 ] || { echo "WOULD branch -D"; return; }
  git -C "$repo" branch -D "$name" >/dev/null 2>&1 || { echo "SKIP git-refused-branch-delete"; return; }
  echo "DONE"
}

_tx_ignored_free() {
  local ignored
  ignored="$(git -C "$1" ls-files --others --ignored --exclude-standard --directory --no-empty-directory)" || return 1
  [ -z "$ignored" ]
}

# ls-files quotes names containing line breaks. Lowercase tags mark
# assume-unchanged entries and S marks skip-worktree. Neither is safe to drop.
_tx_index_visible() {
  (set -o pipefail
   git -C "$1" ls-files -v | LC_ALL=C awk '/^[a-zS] / { hidden=1 } END { exit hidden+0 }')
}

# The parking container is a sibling of the original path.
_tx_parked_path() {
  case "$2" in ''|*[!A-Za-z0-9]*) return 1 ;; esac
  printf '%s.sge-parked-%s/%s\n' "$1" "$2" "${1##*/}"
}

_tx_reverse_move() {
  local repo path parked parent
  printf -v repo '%q' "$1"; printf -v path '%q' "$2"; printf -v parked '%q' "$3"; printf -v parent '%q' "${2%/*}"
  # Git appends the parked basename to the parent, checking the exact target.
  printf '[ ! -e %s ] && [ ! -L %s ] && git -C %s worktree move %s %s\n' "$path" "$path" "$repo" "$parked" "$parent"
}

_tx_recent_reason() {
  local minutes="${SGE_WT_RECENCY_GUARD_MIN:-10}" recent
  case "$minutes" in ''|*[!0-9]*) echo recency-guard-unavailable; return ;; esac
  [ "$minutes" -eq 0 ] && return 0
  recent="$(find "$1" -type f ! -name .git -mmin "-$minutes" -print -quit 2>/dev/null)" \
    || { echo recency-guard-unavailable; return; }
  [ -z "$recent" ] || echo recent-files
}

# <worktree> -> 0 only when its .sge-wt-claim lease is absent or older than the
# lease TTL (sge#3697): the same roc_claim_state predicate resume-or-create uses,
# so an abandoned session's lease no longer pins a worktree forever. A claim
# file that is not a regular "<owner> <epoch>" file is NOT free (fail closed).
_TX_CLAIM_SEEN=""
_tx_claim_free() {
  local f="$1/.sge-wt-claim" c state re=$'^[^[:space:]]+ [0-9]+\n$'
  _TX_CLAIM_SEEN=""
  if [ -e "$f" ] || [ -L "$f" ]; then
    [ -f "$f" ] && [ ! -L "$f" ] || return 1
    [ "$(wc -c <"$f" 2>/dev/null)" -le 4096 ] 2>/dev/null || return 1
    # Exactly one "<owner> <epoch>\n" line: roc_claim_state reads only the first
    # two fields of the first line, so a third field, a CR or a second line would
    # make it misread a live or unknown record as expired, i.e. free.
    c="$(cat "$f" 2>/dev/null; echo x)" || return 1
    c="${c%x}"
    [[ "$c" =~ $re ]] || return 1
    _TX_CLAIM_SEEN="$(cat "$f" 2>/dev/null)" || return 1
  fi
  state="$(SGE_AGENT_ID= bash "$_TX_HERE/../worktrees/resume-or-create.sh" claim-state "$1" 2>/dev/null | tr -d '\r')"
  [ "$state" = free ]
}

# <worktree> -> re-checks the lease under the shared lease lock (the caller holds
# it, see worktrees/lease-lock.sh) and drops the EXPIRED lease _tx_claim_free just
# read, so the no-force `git worktree remove` is not refused by that one marker.
# It refuses when the file no longer holds exactly what was judged expired, or
# when a lease has appeared where there was none. Lease writers take the same
# lock, so nothing can refresh the lease between this check and the removal.
# Any other untracked file keeps blocking `git worktree remove` as before.
_tx_drop_expired_claim() {
  local f="$1/.sge-wt-claim"
  if [ -z "$_TX_CLAIM_SEEN" ]; then
    [ ! -e "$f" ] && [ ! -L "$f" ]; return
  fi
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  [ "$(cat "$f" 2>/dev/null)" = "$_TX_CLAIM_SEEN" ] || return 1
  rm -f -- "$f"
}

_tx_worktree() { # <repo> <def> <name> <path> <tip> <bucket>
  local repo="$1" def="$2" name="$3" path="$4" tip="$5" bucket="${6:-A}" por blk="" line cur want st n r
  [ "$path" != - ] || { _tx_out SKIP "$repo" worktree "$name" "$tip" no-path; return 1; }
  case "$path" in
    *.sge-parked-*/*) _tx_out SKIP "$repo" worktree "$name" "$tip" already-parked; return 1 ;;
  esac
  if [ "$name" != "(detached)" ]; then
    _tx_safe_name "$name" || { _tx_out SKIP "$repo" worktree "$name" "$tip" unsafe-name; return 1; }
    ! _tx_protected "$name" "$def" || { _tx_out SKIP "$repo" worktree "$name" "$tip" protected; return 1; }
  fi
  por="$(git -C "$repo" worktree list --porcelain 2>/dev/null)" || { _tx_out SKIP "$repo" worktree "$name" "$tip" lookup-failed; return 1; }
  por="$(printf '%s\n' "$por" | tr -d '\r')"
  want="$(_tx_real "$path")"
  [ -n "$want" ] || [ ! -e "$path" ] || { _tx_out SKIP "$repo" worktree "$name" "$tip" path-unreadable; return 1; }
  if [ -z "$want" ]; then # directory already gone: prune and settle the branch on its tip
    [ "${_SGE_BULK_RECLAIM:-0}" != 1 ] || { _tx_out SKIP "$repo" worktree "$name" "$tip" path-missing; return 1; }
    printf '%s\n' "$por" | grep -qxF "worktree $path" && [ "$_TX_DRY" -eq 0 ] && git -C "$repo" worktree prune >/dev/null 2>&1
    r="GONE"; [ "$name" = "(detached)" ] || r="$(_tx_branch "$repo" "$name" "$tip")"
    _tx_out "${r%% *}" "$repo" worktree "$name" "$tip" worktree-already-gone "branch: $r"
    [ "${r%% *}" != SKIP ]; return
  fi
  [ "$want" != "$(_tx_real "$repo")" ] || { _tx_out SKIP "$repo" worktree "$name" "$tip" main-worktree; return 1; }
  [ "$want" != "$(_tx_real "$(git rev-parse --show-toplevel 2>/dev/null)")" ] || { _tx_out SKIP "$repo" worktree "$name" "$tip" current-checkout; return 1; }
  local inblk=0
  while IFS= read -r line; do # find this worktree's porcelain block and its lock line
    case "$line" in
      "worktree "*) inblk=0; [ "$(_tx_real "${line#worktree }")" = "$want" ] && { inblk=1; blk=x; } ;;
      locked*) [ "$inblk" -eq 0 ] || blk=locked ;;
    esac
  done <<<"$por"
  [ -n "$blk" ] || { _tx_out SKIP "$repo" worktree "$name" "$tip" not-a-registered-worktree; return 1; }
  [ "$blk" != locked ] || { _tx_out SKIP "$repo" worktree "$name" "$tip" locked; return 1; }
  _tx_claim_free "$path" || { _tx_out SKIP "$repo" worktree "$name" "$tip" live-claim; return 1; }
  cur="$(git -C "$path" rev-parse --verify --quiet HEAD 2>/dev/null | tr -d '\r')"
  [ "$cur" = "$tip" ] || { _tx_out SKIP "$repo" worktree "$name" "$tip" tip-changed "now=${cur:-unreadable}"; return 1; }
  if [ "$name" != "(detached)" ]; then
    cur="$(git -C "$path" symbolic-ref -q --short HEAD 2>/dev/null | tr -d '\r')"
    [ "$cur" = "$name" ] || { _tx_out SKIP "$repo" worktree "$name" "$tip" branch-changed "now=${cur:-detached}"; return 1; }
  fi
  st="$(git -C "$path" status --porcelain --untracked-files=no 2>/dev/null)" || { _tx_out SKIP "$repo" worktree "$name" "$tip" status-failed; return 1; }
  if [ -n "$st" ] && { [ "${_SGE_BULK_RECLAIM:-0}" != 1 ] || [ "$bucket" != B ]; }; then
    _tx_out SKIP "$repo" worktree "$name" "$tip" dirty; return 1
  fi
  if [ "${_SGE_BULK_RECLAIM:-0}" = 1 ]; then
    _tx_ignored_free "$path" || { _tx_out SKIP "$repo" worktree "$name" "$tip" ignored-files; return 1; }
    _tx_index_visible "$path" || { _tx_out SKIP "$repo" worktree "$name" "$tip" hidden-or-unreadable-index; return 1; }
    r="$(_tx_recent_reason "$path")"
    [ -z "$r" ] || { _tx_out SKIP "$repo" worktree "$name" "$tip" "$r"; return 1; }
  fi
  if [ "$_TX_DRY" -eq 1 ]; then
    r=remove-worktree-and-branch
    [ "${_SGE_BULK_RECLAIM:-0}" != 1 ] || r=park-worktree
    _tx_out WOULD "$repo" worktree "$name" "$tip" "$r"; return 0
  fi
  # The lease lock is held from the re-check through `git worktree remove` (which
  # deletes the admin dir and the lock with it), so no lease can be written or
  # refreshed between the check and the removal.
  sge_lease_lock "$path" || { _tx_out SKIP "$repo" worktree "$name" "$tip" lease-lock-busy; return 1; }
  if [ "${_SGE_BULK_RECLAIM:-0}" = 1 ]; then
    local parked
    _tx_claim_free "$path" || { sge_lease_unlock; _tx_out SKIP "$repo" worktree "$name" "$tip" live-claim; return 1; }
    _tx_link_guard "$path" preserve >/dev/null || { sge_lease_unlock; _tx_out SKIP "$repo" worktree "$name" "$tip" link-guard-failed; return 1; }
    # Set POSIX permissions at creation. NTFS inherits the parent directory's ACL.
    parked="$(_tx_parked_path "$path" "${_SGE_PARKING_ID:-}")" && (umask 077; mkdir -- "${parked%/*}") \
      || { sge_lease_unlock; _tx_out SKIP "$repo" worktree "$name" "$tip" parking-path-unavailable; return 1; }
    if ! git -C "$repo" -c core.longpaths=true worktree move "$path" "${parked%/*}" >/dev/null 2>&1; then
      # Keep even a partially moved checkout discoverable in the journal.
      sge_lease_unlock; _tx_out SKIP "$repo" worktree "$name" "$tip" parking-refused "$parked"; return 1
    fi
    sge_lease_unlock
    _tx_out DONE "$repo" worktree "$name" "$tip" parked "$parked"
    return
  fi
  _tx_drop_expired_claim "$path" || { sge_lease_unlock; _tx_out SKIP "$repo" worktree "$name" "$tip" live-claim claim-changed; return 1; }
  n="$(_tx_link_guard "$path")" || { sge_lease_unlock; _tx_out SKIP "$repo" worktree "$name" "$tip" link-guard-failed; return 1; }
  git -C "$repo" -c core.longpaths=true worktree remove "$path" >/dev/null 2>&1 \
    || { sge_lease_unlock; _tx_out SKIP "$repo" worktree "$name" "$tip" git-refused "links unlinked: ${n:-0}"; return 1; }
  sge_lease_unlock
  git -C "$repo" worktree prune >/dev/null 2>&1
  r="GONE"; [ "$name" = "(detached)" ] || r="$(_tx_branch "$repo" "$name" "$tip")"
  _tx_out DONE "$repo" worktree "$name" "$tip" removed "links unlinked: ${n:-0}; branch: $r"
}

_tx_local_branch() { # <repo> <def> <name> <tip>
  local r
  _tx_safe_name "$3" || { _tx_out SKIP "$1" branch "$3" "$4" unsafe-name; return 1; }
  ! _tx_protected "$3" "$2" || { _tx_out SKIP "$1" branch "$3" "$4" protected; return 1; }
  r="$(_tx_branch "$1" "$3" "$4")"
  case "$r" in DONE) _tx_out DONE "$1" branch "$3" "$4" deleted ;; GONE) _tx_out GONE "$1" branch "$3" "$4" already-gone ;;
    WOULD*) _tx_out WOULD "$1" branch "$3" "$4" branch-delete ;;
    *) _tx_out SKIP "$1" branch "$3" "$4" "$(printf '%s' "${r#SKIP }" | cut -d' ' -f1)" "${r#SKIP }"; return 1 ;; esac
}

# Open-PR heads for <repo>, fail closed (sge-public#47): a fresh read-only lookup
# just before remote deletion, so a PR opened since the audit is never closed by
# deleting its branch. Subshell: hpr_host_kind caches per shell and per repo.
_tx_open_prs() { ( cd "$1" || exit 1; source "$_TX_HERE/../lib/host-pr-read.sh"; set +e; hpr_open_pr_heads ) 2>/dev/null; }

_tx_remote_branch() { # <repo> <def> <name> <tip>
  local repo="$1" def="$2" name="$3" tip="$4" open ls rc live
  _tx_safe_name "$name" || { _tx_out SKIP "$repo" remote-branch "$name" "$tip" unsafe-name; return 1; }
  ! _tx_protected "$name" "$def" || { _tx_out SKIP "$repo" remote-branch "$name" "$tip" protected; return 1; }
  # A same-named local branch still exists: its local item was skipped (this run or
  # an earlier one) or never approved, so the remote copy stays too.
  [ -z "$(git -C "$repo" rev-parse --verify --quiet "refs/heads/$name" 2>/dev/null)" ] \
    || { _tx_out SKIP "$repo" remote-branch "$name" "$tip" local-copy-present; return 1; }
  open="$(_tx_open_prs "$repo")" || { _tx_out SKIP "$repo" remote-branch "$name" "$tip" open-pr-set-unknown; return 1; }
  ! printf '%s\n' "$open" | awk -F'\t' -v b="$name" '$2==b{f=1} END{exit !f}' \
    || { _tx_out SKIP "$repo" remote-branch "$name" "$tip" open-pr; return 1; }
  ls="$(git -C "$repo" ls-remote --exit-code origin "refs/heads/$name" 2>/dev/null)"; rc=$?
  [ "$rc" -ne 2 ] || { _tx_out GONE "$repo" remote-branch "$name" "$tip" already-gone; return 0; }
  [ "$rc" -eq 0 ] || { _tx_out SKIP "$repo" remote-branch "$name" "$tip" lookup-failed; return 1; }
  live="$(printf '%s\n' "$ls" | tr -d '\r' | awk -F'\t' -v r="refs/heads/$name" '$2==r{print $1; exit}')"
  [ "$live" = "$tip" ] || { _tx_out SKIP "$repo" remote-branch "$name" "$tip" tip-changed "now=${live:-unreadable}"; return 1; }
  [ "$_TX_DRY" -eq 0 ] || { _tx_out WOULD "$repo" remote-branch "$name" "$tip" remote-delete; return 0; }
  # The lease makes the delete a compare-and-delete: the server-side ref must still
  # equal the audited tip in this same push, so a push that lands after the
  # ls-remote above is never deleted. It adds a check; it does not force anything.
  git -C "$repo" push --force-with-lease="refs/heads/$name:$tip" origin ":refs/heads/$name" >/dev/null 2>&1 \
    || { _tx_out SKIP "$repo" remote-branch "$name" "$tip" push-refused; return 1; }
  _tx_out DONE "$repo" remote-branch "$name" "$tip" deleted
}

tx_main() {
  local audits=() sels=() buckets="A,D" rec="" remote=0 f t plan repo def kind name path tip bucket reason
  _TX_DRY=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --audit) shift; [ -n "${1:-}" ] || { _tx_usage; return 2; }; audits+=("$1") ;;
      --select) shift; [ -n "${1:-}" ] || { _tx_usage; return 2; }; sels+=("$1") ;;
      --select-file) shift; [ -r "${1:-}" ] || { _tx_usage; return 2; }
        while IFS= read -r t; do t="${t%$'\r'}"; [ -z "$t" ] || [ "${t:0:1}" = "#" ] || sels+=("$t"); done <"$1" ;;
      --buckets) shift; buckets="${1:-}" ;;
      --recovery) shift; rec="${1:-}" ;;
      --remote) remote=1 ;;
      --dry-run) _TX_DRY=1 ;;
      *) _tx_usage; return 2 ;;
    esac
    shift
  done
  [ "${#audits[@]}" -gt 0 ] && [ "${#sels[@]}" -gt 0 ] || { _tx_usage; return 2; }
  [[ "$buckets" =~ ^[ABD](,[ABD]){0,2}$ ]] || { echo "--buckets takes A, B and/or D (comma-separated)" >&2; return 2; }
  command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; return 2; }
  for f in "${audits[@]}"; do
    jq -e 'type == "array"' "$f" >/dev/null 2>&1 || { echo "not an audit.sh JSON array: $f" >&2; return 2; }
  done
  [ -n "$rec" ] || rec="$PWD/tidy-recovery-$(date +%Y%m%dT%H%M%S).csv"

  # Candidates: A/D items with plan commands (and B items, for an explicit discard),
  # from repos whose audit was not refused. C is never selectable.
  plan="$(jq -r --arg buckets "$buckets" '
      .[]? | if (.refused != false) or (.delete_plan == null) then "REFUSED\t\(.repo)"
      else .repo as $r | .default_branch as $d
        | .items[] | select((.bucket | IN($buckets | split(",")[]))
                            and (((.commands // []) | length > 0) or .bucket == "B")
                            and (.kind | IN("worktree", "branch", "remote-branch")))
        | ["ITEM", $r, $d, .kind, .name, (.path // "-"), .tip, .bucket, (.reason // "-")] | map(. // "" | tostring)
      | if any(.[]; test("[\t\r\n]") or (explode | index(0) != null)) then error("unsupported control character in audit field")
        else join("\t") end end' "${audits[@]}" 2>/dev/null)" \
    || { echo "cannot read the audit JSON" >&2; return 2; }
  plan="$(printf '%s\n' "$plan" | tr -d '\r')"

  # Selection: every token literal and pinned to the audited tip.
  # A token may be qualified with its repo (`<repo>::<token>`, repo as in the
  # audit's "repo" field); an unqualified kind:name token that matches in more
  # than one repo is refused, so one approval never deletes in another clone.
  local selected="" tag rest body i matched
  local -A hits=()
  while IFS=$'\t' read -r tag repo def kind name path tip bucket reason; do
    [ "$tag" = REFUSED ] && { printf 'REFUSED\t%s\topen-PR set unknown: nothing in this repo is selectable\n' "${repo##*/}"; continue; }
    [ "$tag" = ITEM ] || continue
    [[ "$tip" =~ ^[0-9a-f]{40}$ ]] || continue
    matched=""
    for i in "${!sels[@]}"; do # record every selector that hits, so the ambiguity check sees them all
      t="${sels[$i]}"; rest=""; body="$t"
      if [[ "$t" == *::* ]]; then [ "${t%%::*}" = "$repo" ] || continue; body="${t#*::}"; fi
      if [ "$body" = all ]; then [ "$kind" != remote-branch ] && [ "$bucket" != B ] && rest=1
      elif [ "$body" = "$kind:$name@$tip" ] || { [ "$path" != - ] && [ "$body" = "$path@$tip" ]; }; then rest=1; fi
      [ -n "$rest" ] || continue
      [[ "${hits[$i]:-}" == *$'\n'"$repo"$'\n'* ]] || hits[$i]+=$'\n'"$repo"$'\n'
      matched=1
    done
    [ -z "$matched" ] || selected+="$repo"$'\t'"$def"$'\t'"$kind"$'\t'"$name"$'\t'"$path"$'\t'"$tip"$'\t'"$bucket"$'\t'"$reason"$'\n'
  done <<<"$plan"
  for i in "${!hits[@]}"; do
    t="${sels[$i]}"
    [ "$t" != all ] && [[ "$t" != *::* ]] && [ "$(printf '%s' "${hits[$i]}" | grep -c .)" -gt 1 ] && {
      echo "ambiguous token '$t' matches in more than one repo; qualify it as '<repo>::$t'" >&2; return 2; }
  done
  if [ "$remote" -eq 0 ]; then
    selected="$(printf '%s' "$selected" | awk -F'\t' '$3 != "remote-branch"')"
    [ -z "$selected" ] || selected+=$'\n'
  fi

  # 1. Recovery CSV first, created exclusively (noclobber = O_EXCL): an existing
  #    file, or one a concurrent run creates first, is never overwritten.
  [ ! -e "$rec" ] || { echo "recovery file exists, refusing to overwrite: $rec" >&2; return 4; }
  local qr qn
  ( set -C
  {
    echo 'repo,kind,name,path,tip,bucket,reason,restore'
    while IFS=$'\t' read -r repo def kind name path tip bucket reason; do
      [ -n "$repo" ] || continue
      printf -v qr '%q' "$repo"; printf -v qn '%q' "$name"
      if [ "${_SGE_BULK_RECLAIM:-0}" = 1 ]; then
        [ "$kind" = worktree ] || exit 1
        t="$(_tx_reverse_move "$repo" "$path" "$(_tx_parked_path "$path" "${_SGE_PARKING_ID:-}")")"
      elif [ "$kind" = remote-branch ]; then t="git -C $qr push origin $tip:refs/heads/$qn"
      else t="git -C $qr branch $qn $tip"; fi
      printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$(_tx_csv "$repo")" "$kind" "$(_tx_csv "$name")" "$(_tx_csv "$path")" \
        "$(_tx_csv "$tip")" "$bucket" "$(_tx_csv "$reason")" "$(_tx_csv "$t")"
    done <<<"$selected"
  } >"$rec" ) 2>/dev/null \
    && [ "$(wc -l <"$rec" | tr -d ' ')" -eq "$(( $(printf '%s' "$selected" | grep -c .) + 1 ))" ] \
    || { echo "cannot write the recovery CSV: $rec" >&2; return 4; }
  echo "RECOVERY $rec"

  # 2. Per repo, in order: worktrees, local branches, remote branches.
  local repos skipped
  repos="$(printf '%s' "$selected" | awk -F'\t' 'NF && !seen[$1]++ {print $1}')"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    skipped=" "
    for k in worktree branch remote-branch; do
      while IFS=$'\t' read -r repo def kind name path tip bucket reason; do
        [ "$repo" = "$r" ] && [ "$kind" = "$k" ] || continue
        case "$kind" in
          worktree) _tx_worktree "$repo" "$def" "$name" "$path" "$tip" "$bucket" || skipped+="$name " ;;
          branch) _tx_local_branch "$repo" "$def" "$name" "$tip" || skipped+="$name " ;;
          remote-branch)
            if [[ "$skipped" == *" $name "* ]]; then _tx_out SKIP "$repo" remote-branch "$name" "$tip" local-copy-skipped
            else _tx_remote_branch "$repo" "$def" "$name" "$tip"; fi ;;
        esac
      done <<<"$selected"
    done
  done <<<"$repos"
  echo "SUMMARY: done=$_TX_N_DONE skipped=$_TX_N_SKIP gone=$_TX_N_GONE would=$_TX_N_WOULD (recovery: $rec)"
  if [ "${_SGE_BULK_RECLAIM:-0}" = 1 ] && [ "$_TX_DRY" -eq 0 ] && [ "$_TX_N_DONE" -ne "${#sels[@]}" ]; then
    return 6
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then tx_main "$@"; exit $?; fi
