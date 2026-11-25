#!/usr/bin/env bash
# reconcile.sh — evidence-led reconciliation of a locked, DIRTY linked worktree
# whose work was recovered and merged through ANOTHER branch (issue #3696,
# SPEC-139). It is a separate flow beside the lock audit (lock-audit.sh, #3408 /
# sge-public#139) and relaxes none of that audit's protections: lock-audit still
# never offers a dirty worktree.
#
#   reconcile.sh plan  --session <id> [--recovery <commit>] [--target <ref>] <worktree>
#       READ-ONLY. Inventories the worktree, compares every local version against
#       the current target and an independently verified recovery commit, lists
#       blockers and prints three SEPARATE decisions (reconcile, release, remove),
#       each with its own approval token bound to the exact evidence digest.
#       A token prevents staleness and replay across changed evidence; it is NOT proof of
#       consent (plan prints it). Consent is the AskUserQuestion decision plus the operator's
#       CLI approval of the apply command, as for lock-audit.sh.
#   reconcile.sh apply --session <id> --decision reconcile|release|remove
#                      --approval <token> [--discard-ignored <token>]
#                      [--recovery <commit>] [--target <ref>] <worktree>
#       Runs ONLY after the user approved that decision. The whole evidence set is
#       recomputed first; a changed digest (stale approval) or any blocker stops it.
#         reconcile: when anything is not already in the target or the verified
#                    recovery, captures it with checkpoint.sh, verifies the capture
#                    by restoring it to a private temp dir and comparing every
#                    version, then records the reconciliation. Otherwise retains.
#         release:   `git worktree unlock` only, and only once reconciled.
#         remove:    once reconciled (and, when ignored files exist, with the
#                    separate discard token): unlock, unlink junctions (links only),
#                    `git worktree remove` (with --force only because the tree is
#                    dirty, stated in the plan), delete the LOCAL branch.
#
# Never: following junction targets, deleting remote branches, changing labels or
# permissions, inferring consent. A commit SHA is never reported as a backup of
# uncommitted files. Unreadable or excluded content is "unknown", never preserved.
# Paths and branch names are untrusted DATA: quoted arguments only, JSON via jq.
#
# Exit codes: 0 ok, 2 usage, 3 not a linked worktree, 4 stopped or retained.

_RC_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_RC_HERE/lock-audit.sh"
set +e
export GIT_OPTIONAL_LOCKS=0
_RC_CK="$_RC_HERE/../worktrees/checkpoint.sh"
_RC_TMP=""

_rc_hash() { git hash-object --stdin; }
# Removes only this run's own private scratch dir (mktemp name pattern), never a user path.
_rc_cleanup() {
  case "$_RC_TMP" in */sge-reconcile.??????) ;; *) return 0 ;; esac
  if [ -d "$_RC_TMP" ] && [ ! -L "$_RC_TMP" ]; then
    rm -rf -- "$_RC_TMP"
  fi
  return 0
}

# <commit> <rel path> -> "<mode>:<blob sha>" (the mode matters: an exec-bit change keeps the
# blob id), or "absent". rc 1 = lookup failed.
_rc_blob_at() {
  local out
  out="$(git -C "$RC_ABS" ls-tree "$1" -- ":(literal)$2" 2>/dev/null)" || return 1
  out="${out%%$'\n'*}"
  case "$out" in *" blob "*) local mode="${out%% *}"; out="${out#* blob }"; printf '%s:%s\n' "$mode" "${out%%$'\t'*}" ;; *) echo absent ;; esac
}

# <repo dir> <rel path> <fallback mode> -> the mode Git would record for that working file
_rc_wt_mode() {
  if [ "$(git -C "$1" config --bool core.filemode 2>/dev/null)" = false ]; then printf '%s\n' "$3"
  elif [ -x "$1/$2" ]; then echo 100755; else echo 100644; fi
}

# 0 when a path can be carried losslessly in the tab/newline-framed evidence records
_rc_path_ok() { case "$1" in *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac; return 0; }

# <rel path> <"mode:blob"> -> 0 when the working file's RAW bytes equal what checking that
# blob out at this path produces. A clean filter or text normalisation can map different bytes
# (e.g. CRLF) to the same blob id; only a byte-identical checkout counts as recovered.
_rc_raw_matches() {
  local raw want
  raw="$(git -C "$RC_ABS" hash-object --no-filters -- "./$1" 2>/dev/null)" || return 1
  want="$(git -C "$RC_ABS" cat-file --filters --path="$1" "${2#*:}" 2>/dev/null | git hash-object --no-filters --stdin)" || return 1
  [ "$raw" = "$want" ]
}

# Junction links as worktree-relative paths ("/"-separated, lower-cased on Windows), one per line.
_rc_junction_rels() {
  local base j
  base="$(cygpath -w "$RC_ABS" 2>/dev/null || printf '%s' "$RC_ABS")"; base="${base%[/\\]}"
  while IFS= read -r j; do
    [ -n "$j" ] || continue
    if _la_is_windows; then
      j="$(printf '%s' "$j" | tr 'A-Z' 'a-z')"; base="$(printf '%s' "$base" | tr 'A-Z' 'a-z')"
    fi
    case "$j" in "$base"[/\\]*) j="${j#"$base"?}"; printf '%s\n' "${j//\\//}" ;; esac
  done <<<"$RC_JUNC"
}

# <rel path> -> 0 when it is a junction link or lies beneath one (a target is never followed)
_rc_under_junction() {
  local p="${1%/}" r
  [ -n "$RC_JUNC_RELS" ] || return 1
  _la_is_windows && p="$(printf '%s' "$p" | tr 'A-Z' 'a-z')"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$p" in "$r"|"$r"/*) return 0 ;; esac
  done <<<"$RC_JUNC_RELS"
  return 1
}

_rc_unknown() { printf '%s\t%s\n' "$1" "$(_wi_clean "$2")" >>"$_RC_TMP/unknown.tsv"; }

# Account for ONE local version: <kind worktree|index> <path> <blob|deleted> <src-file or ->
_rc_version() {
  local kind="$1" p="$2" v="$3" src="$4" t r h disp sub="" add=- del=- ws=false base bfile
  t="$(_rc_blob_at "$RC_TARGET_SHA" "$p")" || { _rc_unknown target-lookup-failed "$p"; return; }
  r=absent; [ "$RC_REC_STATE" = verified ] && { r="$(_rc_blob_at "$RC_REC_SHA" "$p")" || { _rc_unknown recovery-lookup-failed "$p"; return; }; }
  local raw=no; case "$kind" in worktree|untracked) [ "$v" = deleted ] || raw=yes ;; esac
  if [ "$v" = "$t" ] || { [ "$v" = deleted ] && [ "$t" = absent ]; }; then disp=in-target
    if [ "$raw" = yes ] && ! _rc_raw_matches "$p" "$t"; then disp=not-recovered; sub=line-endings-or-filter-differ; fi
  elif [ "$RC_REC_STATE" = verified ] && { [ "$v" = "$r" ] || { [ "$v" = deleted ] && [ "$r" = absent ]; }; }; then disp=in-recovery
    if [ "$raw" = yes ] && ! _rc_raw_matches "$p" "$r"; then disp=not-recovered; sub=line-endings-or-filter-differ; fi
  else disp=not-recovered; fi
  if [ "$disp" = not-recovered ] && [ -z "$sub" ]; then
    h="$(_rc_blob_at HEAD "$p")" || h=unknown
    if [ "$RC_REC_STATE" != verified ]; then sub=not-in-target
    elif [ "$r" != "$h" ]; then sub=corrected-in-recovery
    else sub=missing-from-recovery; fi
  fi
  if [ "$disp" = not-recovered ]; then
    # Size of the difference only (never content): local version vs recovery (else target).
    base="$t"; [ "$RC_REC_STATE" = verified ] && base="$r"
    bfile=/dev/null
    if [ "$base" != absent ]; then bfile="$_RC_TMP/base"; git -C "$RC_ABS" cat-file blob "${base#*:}" >"$bfile" 2>/dev/null || bfile=/dev/null; fi
    [ "$v" != deleted ] || src=/dev/null
    if [ -n "$src" ] && [ "$src" != - ]; then
      read -r add del _ < <(git diff --no-index --no-ext-diff --no-textconv --numstat -- "$bfile" "$src" 2>/dev/null; echo "0 0")
      git diff --no-index --no-ext-diff --no-textconv --quiet -w --ignore-blank-lines -- "$bfile" "$src" >/dev/null 2>&1 && ws=true
    fi
  fi
  # Raw bytes of every working-file version: a filter can map different bytes (LF/CRLF) to one
  # blob, so the approval digest and the removal fingerprint must also bind the raw hash.
  local rawh=-
  if [ "$raw" = yes ]; then rawh="$(git -C "$RC_ABS" hash-object --no-filters -- "./$p" 2>/dev/null)" || rawh=unreadable; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$p" "$v" "$disp" "${sub:--}" "${add:--}" "${del:--}" "$ws" "$rawh" >>"$_RC_TMP/versions.tsv"
}

# Collect every piece of evidence for <abs worktree>. Sets RC_* globals and files in $_RC_TMP.
_rc_collect() { # <abs> <recovery-or-empty> <target-or-empty> <here-toplevel>
  RC_ABS="$1"; local rec="$2" target="$3" here="$4" line wt="" br="" lr="" lk=0 first=1 idx=0 main=""
  : >"$_RC_TMP/unknown.tsv"; : >"$_RC_TMP/versions.tsv"; : >"$_RC_TMP/ignored.txt"; : >"$_RC_TMP/blockers.txt"
  RC_BRANCH=""; RC_LOCKED=0; RC_LOCKREASON=""; RC_LINKED=0
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt="${line#worktree }"; br="(detached)"; lr=""; lk=0 ;;
      "branch "*) br="${line#branch refs/heads/}" ;;
      locked) lk=1 ;;
      "locked "*) lk=1; lr="${line#locked }" ;;
      "") if [ -n "$wt" ]; then
            [ "$first" -eq 1 ] && main="$(_wl_abs "$wt" 2>/dev/null)"
            if [ "$first" -eq 0 ] && [ "$(_wl_abs "$wt" 2>/dev/null)" = "$RC_ABS" ]; then
              RC_LINKED=1; RC_BRANCH="$br"; RC_LOCKED="$lk"; RC_LOCKREASON="$lr"
            fi
            first=0
          fi; wt="" ;;
    esac
  done < <(git -C "$RC_ABS" worktree list --porcelain 2>/dev/null; echo)
  RC_MAIN="$main"
  RC_HEAD="$(git -C "$RC_ABS" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || RC_HEAD=unknown

  local def; def="$(git -C "$RC_ABS" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"; [ -n "$def" ] || def=main
  RC_DEFAULT="$def"; [ -n "$target" ] || target="origin/$def"
  RC_TARGET="$target"
  RC_TARGET_SHA="$(git -C "$RC_ABS" rev-parse -q --verify "${target}^{commit}" 2>/dev/null)" || RC_TARGET_SHA=""
  RC_REC_SHA=""; RC_REC_STATE=none
  if [ -n "$rec" ]; then
    RC_REC_STATE=unresolved
    if RC_REC_SHA="$(git -C "$RC_ABS" rev-parse -q --verify "${rec}^{commit}" 2>/dev/null)"; then
      # Independent of any host claim: the recovery commit (merge or squash) must be on the target.
      if [ -n "$RC_TARGET_SHA" ] && git -C "$RC_ABS" merge-base --is-ancestor "$RC_REC_SHA" "$RC_TARGET_SHA" 2>/dev/null; then
        RC_REC_STATE=verified
      else RC_REC_STATE=not-on-target; fi
    else RC_REC_SHA=""; fi
  fi

  RC_JPROBE=ok; RC_JUNC="$(_la_junctions "$RC_ABS")" || RC_JPROBE=failed
  RC_JUNC="$(printf '%s\n' "$RC_JUNC" | tr -d '\r' | grep .)"
  RC_JUNC_RELS="$(_rc_junction_rels)"

  # ---- content inventory (staged, unstaged, untracked, ignored, unknown) ----
  local st="$_RC_TMP/status.nul" rec2 xy X Y p ls mode isha v newest=0 m
  RC_STATUS_OK=1; RC_DIRTY=0
  if ! git -C "$RC_ABS" -c core.fsmonitor=false -c core.quotepath=off status --porcelain=v1 -z --no-renames \
        --untracked-files=all --ignored=no >"$st" 2>"$_RC_TMP/status.err"; then
    RC_STATUS_OK=0; _rc_unknown status-failed "(worktree could not be enumerated)"; : >"$st"
  fi
  [ ! -s "$_RC_TMP/status.err" ] || _rc_unknown enumeration-warning "(some paths could not be read)"
  while IFS= read -r -d '' rec2; do
    xy="${rec2:0:2}"; p="${rec2:3}"; X="${xy:0:1}"; Y="${xy:1:1}"
    RC_DIRTY=1
    [ "$p" = "$RG_CLAIM_FILE" ] && continue # lease metadata: judged by the claim check
    _rc_path_ok "$p" || { _rc_unknown unrepresentable-path "$p"; continue; }
    if _rc_under_junction "$p"; then continue; fi # a link, listed under junctions; target never followed
    if [ -e "$RC_ABS/$p" ]; then m="$(_la_mtime "$RC_ABS/$p")"; case "$m" in ''|*[!0-9]*) ;; *) [ "$m" -gt "$newest" ] && newest="$m" ;; esac; fi
    [ -n "$RC_TARGET_SHA" ] || { _rc_unknown target-unresolved "$p"; continue; }
    if [ "$xy" = '??' ]; then
      case "$p" in */) _rc_unknown nested-repository "$p"; continue ;; esac
      if [ -L "$RC_ABS/$p" ] || [ ! -f "$RC_ABS/$p" ]; then _rc_unknown special-file "$p"; continue; fi
      [ -r "$RC_ABS/$p" ] || { _rc_unknown unreadable "$p"; continue; }
      v="$(git -C "$RC_ABS" hash-object -- "./$p" 2>/dev/null)" || { _rc_unknown unreadable "$p"; continue; }
      _rc_version untracked "$p" "$(_rc_wt_mode "$RC_ABS" "$p" 100644):$v" "$RC_ABS/$p"; continue
    fi
    if [ "$X" = U ] || [ "$Y" = U ] || [ "$xy" = AA ] || [ "$xy" = DD ]; then _rc_unknown unmerged "$p"; continue; fi
    ls="$(git -C "$RC_ABS" ls-files -s -z -- ":(literal)$p" 2>/dev/null | tr '\0' '\n' | head -n 1)"
    mode="${ls%% *}"; isha="${ls#* }"; isha="${isha%% *}"
    [ "$mode" != 160000 ] || { _rc_unknown submodule "$p"; continue; }
    [ "$mode" != 120000 ] || { _rc_unknown special-file "$p"; continue; } # staged symlink
    # worktree version
    if [ "$Y" = ' ' ] && [ "$X" = D ]; then
      # a staged deletion is index state: record it as an index row. The working path gets its
      # own row only when it is really absent (a same-named untracked file is listed as "??").
      _rc_version index "$p" deleted /dev/null
      if [ ! -e "$RC_ABS/$p" ] && [ ! -L "$RC_ABS/$p" ]; then _rc_version worktree "$p" deleted /dev/null; fi
    elif [ "$Y" = ' ' ]; then
      # staged only: the working file must still be a readable regular file
      if [ -L "$RC_ABS/$p" ] || [ ! -f "$RC_ABS/$p" ]; then _rc_unknown special-file "$p"; continue; fi
      [ -r "$RC_ABS/$p" ] || { _rc_unknown unreadable "$p"; continue; }
      _rc_version worktree "$p" "$mode:$isha" "$RC_ABS/$p"
      # the staged entry is verified on its own: a restore must stage it, not just write the file
      git -C "$RC_ABS" cat-file blob "$isha" >"$_RC_TMP/idx" 2>/dev/null || { _rc_unknown unreadable "$p"; continue; }
      _rc_version index "$p" "$mode:$isha" "$_RC_TMP/idx"
    else
      if [ "$Y" = D ] || { [ ! -e "$RC_ABS/$p" ] && [ ! -L "$RC_ABS/$p" ]; }; then v=deleted
      elif [ -L "$RC_ABS/$p" ] || [ ! -f "$RC_ABS/$p" ]; then _rc_unknown special-file "$p"; continue
      elif [ ! -r "$RC_ABS/$p" ]; then _rc_unknown unreadable "$p"; continue
      else v="$(git -C "$RC_ABS" hash-object -- "./$p" 2>/dev/null)" || { _rc_unknown unreadable "$p"; continue; }
           v="$(_rc_wt_mode "$RC_ABS" "$p" "${mode:-100644}"):$v"; fi
      _rc_version worktree "$p" "$v" "$RC_ABS/$p"
      # a staged entry is separate work in its own right, verified against the restored index
      if [ "$X" != ' ' ]; then
        if [ "$X" = D ]; then isha=deleted; else isha="$mode:$isha"; fi
        if [ "$isha" = deleted ]; then _rc_version index "$p" deleted /dev/null
        else git -C "$RC_ABS" cat-file blob "${isha#*:}" >"$_RC_TMP/idx" 2>/dev/null || { _rc_unknown unreadable "$p"; continue; }
             _rc_version index "$p" "$isha" "$_RC_TMP/idx"; fi
      fi
    fi
  done <"$st"
  # committed work on the branch that the target does not contain (a remote-tracking ref can be
  # stale, so "pushed" is not treated as preserved): every path the branch changed since the
  # merge base is compared like any other version.
  if [ -n "$RC_TARGET_SHA" ] && [ "$RC_HEAD" != unknown ] && ! git -C "$RC_ABS" merge-base --is-ancestor HEAD "$RC_TARGET_SHA" 2>/dev/null; then
    local mb; mb="$(git -C "$RC_ABS" merge-base HEAD "$RC_TARGET_SHA" 2>/dev/null)"
    if [ -z "$mb" ]; then _rc_unknown merge-base-unresolved "(branch history)"
    else
      # every producer is captured and its status checked: a failed scan is unknown, never empty
      if git -C "$RC_ABS" diff -z --name-only --no-renames "$mb" HEAD -- >"$_RC_TMP/committed.nul" 2>/dev/null; then
        while IFS= read -r -d '' p; do
          _rc_path_ok "$p" || { _rc_unknown unrepresentable-path "$p"; continue; }
          v="$(_rc_blob_at HEAD "$p")" || { _rc_unknown unreadable "$p"; continue; }
          if [ "$v" = absent ]; then _rc_version committed "$p" deleted /dev/null
          else git -C "$RC_ABS" cat-file blob "${v#*:}" >"$_RC_TMP/idx" 2>/dev/null || { _rc_unknown unreadable "$p"; continue; }
               _rc_version committed "$p" "$v" "$_RC_TMP/idx"; fi
        done <"$_RC_TMP/committed.nul"
      else _rc_unknown committed-scan-failed "(branch changes could not be listed)"; fi
    fi
  fi
  # assume-unchanged / skip-worktree edits are invisible to status: unknown, never preserved
  if git -C "$RC_ABS" ls-files -v -z >"$_RC_TMP/lsv.nul" 2>/dev/null; then
    while IFS= read -r -d '' line; do
      case "${line:0:1}" in [a-z]|S) _rc_unknown hidden-change "${line:2}" ;; esac
    done <"$_RC_TMP/lsv.nul"
  else _rc_unknown hidden-scan-failed "(index flags could not be read)"; fi
  RC_NEWEST="$newest"

  # EVERY ignored leaf path (not collapsed directories): a discard approval must bind to each file,
  # including one added later inside an already-listed ignored directory. A failed scan is unknown.
  : >"$_RC_TMP/ignored.txt"
  if git -C "$RC_ABS" -c core.quotepath=off ls-files -z --others --ignored --exclude-standard >"$_RC_TMP/ignored.nul" 2>/dev/null; then
    while IFS= read -r -d '' p; do
      _rc_under_junction "$p" && continue # behind a junction link: the target is not ours to discard
      _rc_path_ok "$p" || { _rc_unknown unrepresentable-path "$p"; continue; }
      printf '%s\n' "$p" >>"$_RC_TMP/ignored.txt"
    done <"$_RC_TMP/ignored.nul"
  else _rc_unknown ignored-scan-failed "(ignored files could not be listed)"; fi
  RC_IGN_COUNT="$(grep -c . "$_RC_TMP/ignored.txt")"
  RC_IGN_DIGEST="$(LC_ALL=C sort "$_RC_TMP/ignored.txt" | _rc_hash)"
  [ -n "$RC_IGN_DIGEST" ] || _rc_unknown ignored-digest-failed "(the ignored-file list could not be hashed)"
  : >"$_RC_TMP/stashes.txt"
  if git -C "$RC_ABS" stash list --format='%H%x09%gs' >"$_RC_TMP/stash.raw" 2>/dev/null; then
    awk -F'\t' -v b="$RC_BRANCH" 'index($2, "WIP on " b ":") == 1 || index($2, "On " b ":") == 1 {print $1}' "$_RC_TMP/stash.raw" >"$_RC_TMP/stashes.txt"
  else _rc_unknown stash-scan-failed "(stashes could not be listed)"; fi
  RC_UNPUB="$(git -C "$RC_ABS" rev-list --count HEAD --not --remotes 2>/dev/null)" || RC_UNPUB=unknown
  RC_CLAIM="$(roc_claim_state "$RC_ABS" 2>/dev/null)"; [ -n "$RC_CLAIM" ] || RC_CLAIM=unknown
  local recd; RC_PR=unknown
  # RC_LIGHT: the final pre-removal recheck compares content only, so it skips the (networked) PR
  # lookup to keep the check-to-removal window as short as possible.
  if [ "${RC_LIGHT:-0}" = 1 ]; then RC_PR=skipped
  elif [ "$RC_BRANCH" != "(detached)" ] && [ -n "$RC_BRANCH" ]; then
    ( cd "$RC_ABS" && ta_pr_load "$def" && ta_pr_record "$RC_BRANCH" ) >"$_RC_TMP/pr" 2>/dev/null && recd="$(cat "$_RC_TMP/pr")" && RC_PR="${recd%%$'\t'*}"
  fi

  # ---- blockers: protected (keep) and unknown (fail closed) ----
  local b=""
  if [ "$RC_LINKED" -ne 1 ]; then b="protected:not-a-linked-worktree"
  elif [ "$RC_ABS" = "$here" ]; then b="protected:current-session"
  elif [ "$RC_BRANCH" = "$def" ]; then b="protected:default-branch"
  elif [ "$RC_BRANCH" = "(detached)" ]; then b="protected:detached-head"
  elif [ "$RC_HEAD" = unknown ] || [ "$RC_STATUS_OK" -ne 1 ]; then b="unknown:state-unreadable"
  elif [ -z "$RC_TARGET_SHA" ]; then b="unknown:target-unresolved"
  elif [ "$RC_CLAIM" = held-fresh ] || [ "$RC_CLAIM" = mine ]; then b="protected:live-claim"
  elif [ "$RC_CLAIM" = unknown ]; then b="unknown:claim-unreadable"
  elif [ "$RC_PR" = open ]; then b="protected:active-pr"
  elif [ "$RC_PR" = unknown ]; then b="unknown:pr-lookup-failed"
  elif [ "$RC_JPROBE" != ok ]; then b="unknown:junction-probe-failed"
  elif [ "$RC_UNPUB" = unknown ]; then b="unknown:unpublished-commits-unreadable"
  elif [ -s "$_RC_TMP/unknown.tsv" ]; then b="unknown:unreadable-or-excluded-content"
  else
    m="$(_la_mtime "$RC_ABS")"; case "$m" in ''|*[!0-9]*) m=0 ;; esac
    [ "$m" -gt "$newest" ] && newest="$m"
    local guard="${SGE_WT_RECENCY_GUARD_MIN:-10}"; case "$guard" in ''|*[!0-9]*) guard=10 ;; esac
    if [ "$newest" -eq 0 ]; then b="unknown:age-unreadable"
    elif [ $(( ($(date +%s) - newest) / 60 )) -lt "$guard" ]; then b="protected:recent-writes-possible-active-writer"; fi
  fi
  RC_BLOCKER="$b"
  RC_NEEDCK=0
  awk -F'\t' '$4=="not-recovered"{f=1} END{exit !f}' "$_RC_TMP/versions.tsv" && RC_NEEDCK=1
  [ "$RC_UNPUB" = 0 ] || RC_NEEDCK=1

  # ---- evidence digest: everything an approval is bound to (no clocks) ----
  RC_DIGEST="$( {
    printf 'path\t%s\nbranch\t%s\nhead\t%s\nlocked\t%s\t%s\n' "$RC_ABS" "$RC_BRANCH" "$RC_HEAD" "$RC_LOCKED" "$RC_LOCKREASON"
    printf 'target\t%s\t%s\nrecovery\t%s\t%s\n' "$RC_TARGET" "$RC_TARGET_SHA" "$RC_REC_SHA" "$RC_REC_STATE"
    printf 'claim\t%s\npr\t%s\nunpublished\t%s\nblocker\t%s\nignored\t%s\n' "$RC_CLAIM" "$RC_PR" "$RC_UNPUB" "$RC_BLOCKER" "$RC_IGN_DIGEST"
    _rc_framed version versions.tsv; _rc_framed unknown unknown.tsv; _rc_framed stash stashes.txt
    printf '%s\n' "$RC_JUNC" | sed 's/^/junction\t/'
  } | _rc_hash)"
}

_rc_token() { printf '%s\n%s\n' "$1" "$RC_DIGEST" | _rc_hash; }
_rc_discard_token() { printf 'discard-ignored\n%s\n%s\n' "$RC_IGN_DIGEST" "$RC_DIGEST" | _rc_hash; }
_rc_record_file() { printf '%s/sge-reconcile/%s.record\n' "$(_wl_common_dir "$RC_ABS")" "$(_wl_key "$RC_ABS")"; }

# 0 when the approved reconcile decision was recorded at this exact evidence digest: either
# nothing needed capture, or its verified checkpoint (and recovery ref) is still present.
_rc_reconciled() {
  local f id; f="$(_rc_record_file)"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  [ "$(sed -n 's/^digest=//p' "$f" | head -n1)" = "$RC_DIGEST" ] || return 1
  id="$(sed -n 's/^checkpoint=//p' "$f" | head -n1)"
  [ "$id" != none ] || { [ "$RC_NEEDCK" -eq 0 ] && { RC_RECORD_CK=none; return 0; }; return 1; }
  _rc_checkpoint_present "$id" || return 1
  RC_RECORD_CK="$id"; return 0
}

# 0 when checkpoint <id> still exists in the store and its recovery ref still pins HEAD.
_rc_checkpoint_present() {
  local id="$1" listing
  grep -Eq '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$' <<<"$id" || return 1
  [ "$(git -C "$RC_ABS" rev-parse -q --verify "refs/sge/checkpoints/$id" 2>/dev/null)" = "$RC_HEAD" ] || return 1
  listing="$(bash "$_RC_CK" list "$RC_ABS" 2>/dev/null)" || return 1
  # here-string, not a pipe: under pipefail an early-exiting grep -q would SIGPIPE the lister
  grep -Eq "^checkpoint:$id status=(complete|partial) " <<<"$listing"
}

# Content-only fingerprint (no lock or junction state): what removal would discard.
_rc_content_fp() {
  { printf 'head\t%s\ntarget\t%s\n' "$RC_HEAD" "$RC_TARGET_SHA"
    _rc_framed version versions.tsv; _rc_framed unknown unknown.tsv; _rc_framed ignored ignored.txt; _rc_framed stash stashes.txt
  } | _rc_hash
}

# <label> <file in $_RC_TMP> -> every line prefixed "<label><TAB>", plus an end marker with the line
# count, so an entry that moves between inventories (or an empty one) changes the hash.
# Lines never contain a tab or newline: unrepresentable paths are blocked at collection.
_rc_framed() {
  local f="$_RC_TMP/$2"
  sed "s/^/$1\\t/" "$f"
  printf '%s-end\t%s\n' "$1" "$(grep -c '' "$f")"
}

_rc_plan_json() { # <session>
  local reconciled=false rel=false rem=false why_rel="" why_rem="" force=false
  [ "$RC_DIRTY" -eq 1 ] && force=true
  if _rc_reconciled; then reconciled=true; fi
  if [ -n "$RC_BLOCKER" ]; then why_rel="$RC_BLOCKER"; why_rem="$RC_BLOCKER"
  elif [ "$reconciled" != true ]; then why_rel=reconcile-first; why_rem=reconcile-first
  else
    rem=true; why_rem=""
    if [ "$RC_LOCKED" -eq 1 ]; then rel=true; else why_rel=not-locked; fi
  fi
  # Arrays go through files (--slurpfile), never argv: a large inventory would exceed the
  # per-argument limit and jq would not start.
  local d="$_RC_TMP"
  jq -R -s 'split("\n") | map(select(length>0) | split("\t")
      | {kind: .[0], path: .[1], local_blob: .[2], disposition: .[3], detail: (if .[4]=="-" then null else .[4] end),
         lines_added: (if .[5]=="-" then null else .[5] end), lines_removed: (if .[6]=="-" then null else .[6] end),
         whitespace_only: (.[7]=="true")})' <"$d/versions.tsv" >"$d/v.json" || return 1
  jq -R -s 'split("\n") | map(select(length>0) | split("\t") | {category: .[0], path: .[1], status: "unknown-not-preserved"})' <"$d/unknown.tsv" >"$d/u.json" || return 1
  jq -R -s 'split("\n") | map(select(length>0))' <"$d/ignored.txt" >"$d/i.json" || return 1
  jq -R -s 'split("\n") | map(select(length>0))' <"$d/stashes.txt" >"$d/s.json" || return 1
  printf '%s\n' "$RC_JUNC" | jq -R -s 'split("\n") | map(select(length>0))' >"$d/j.json" || return 1
  jq -n --arg sid "$1" --arg path "$RC_ABS" --arg branch "$RC_BRANCH" --arg head "$RC_HEAD" \
    --argjson locked "$RC_LOCKED" --arg lockreason "$RC_LOCKREASON" \
    --arg target "$RC_TARGET" --arg tsha "$RC_TARGET_SHA" --arg rsha "$RC_REC_SHA" --arg rstate "$RC_REC_STATE" \
    --arg claim "$RC_CLAIM" --arg pr "$RC_PR" --arg unpub "$RC_UNPUB" --arg blocker "$RC_BLOCKER" \
    --slurpfile versions "$d/v.json" --slurpfile unknown "$d/u.json" --slurpfile ignored "$d/i.json" --arg igndig "$RC_IGN_DIGEST" \
    --slurpfile stashes "$d/s.json" --slurpfile junctions "$d/j.json" --arg jprobe "$RC_JPROBE" --arg digest "$RC_DIGEST" \
    --argjson needck "$RC_NEEDCK" --argjson reconciled "$reconciled" --arg recck "${RC_RECORD_CK:-}" \
    --arg trec "$(_rc_token reconcile)" --arg trel "$(_rc_token release)" --arg trem "$(_rc_token remove)" --arg tdis "$(_rc_discard_token)" \
    --argjson rel "$rel" --argjson rem "$rem" --arg whyrel "$why_rel" --arg whyrem "$why_rem" --argjson force "$force" '
    def nn: if . == "" then null else . end;
    $versions[0] as $versions | $unknown[0] as $unknown | $ignored[0] as $ignored | $stashes[0] as $stashes | $junctions[0] as $junctions |
    {requesting_session: $sid, path: $path, branch: $branch, head: $head,
     lock: {locked: ($locked == 1), reason: ($lockreason | nn)},
     target: {ref: $target, sha: ($tsha | nn)},
     recovery: {sha: ($rsha | nn), state: $rstate,
                note: "verified = the recovery commit (merge or squash) is reachable from the current target; host PR metadata is not trusted for this"},
     inventory: {versions: $versions, unknown: $unknown,
                 ignored: {count: ($ignored | length), paths: $ignored, digest: $igndig,
                           note: "ignored files are NOT captured by a checkpoint or any commit; remove discards them only with the discard_ignored token"},
                 attributed_stashes: $stashes, stash_note: "stashes live in the repository and are never touched",
                 unpublished_commits: $unpub, claim: $claim, open_pr: $pr,
                 junctions: (if $jprobe == "ok" then $junctions else "probe-failed" end),
                 junction_note: "links only: targets are never followed, inventoried or deleted"},
     summary: {in_target: ([$versions[] | select(.disposition=="in-target")] | length),
               in_recovery: ([$versions[] | select(.disposition=="in-recovery")] | length),
               not_recovered: ([$versions[] | select(.disposition=="not-recovered")] | length),
               corrected_in_recovery: ([$versions[] | select(.detail=="corrected-in-recovery")] | length),
               unknown: ($unknown | length)},
     blocker: ($blocker | nn),
     evidence_digest: $digest,
     backup_note: "the head SHA preserves commits only; uncommitted work is preserved only by the target, the verified recovery, or a verified checkpoint",
     decisions: {
       reconcile: {available: ($blocker == ""), needs_checkpoint: ($needck == 1), already_reconciled: $reconciled,
                   checkpoint: ($recck | nn), approval: $trec,
                   effect: (if $needck == 1 then "capture the not-recovered work with checkpoint.sh, verify it by restore, record it; retain the worktree if capture is partial, refused or unverifiable"
                            else "record that every version is already in the target or the verified recovery" end)},
       release: {available: $rel, why_not: ($whyrel | nn), approval: $trel, effect: "git worktree unlock only"},
       remove: {available: $rem, why_not: ($whyrem | nn), approval: $trem,
                discard_ignored: (if ($ignored | length) > 0 then {required: true, approval: $tdis, paths: $ignored} else {required: false} end),
                force: $force,
                effect: ("unlock, unlink junction links only, git worktree remove" + (if $force then " --force (the tree is dirty; every version is reconciled)" else "" end)
                         + ", delete the LOCAL branch; remote branches are never touched")}}}'
}

_rc_result() { # <decision> <status> <reason> [checkpoint] [retained yes|no]
  local keep="${5:-}"
  [ -n "$keep" ] || { [ "$2" = removed ] && keep=no || keep=yes; }
  jq -n --arg path "$RC_ABS" --arg d "$1" --arg s "$2" --arg r "$3" --arg ck "${4:-}" --arg digest "$RC_DIGEST" --arg keep "$keep" \
    '{path: $path, decision: $d, status: $s, reason: (if $r == "" then null else $r end),
      checkpoint: (if $ck == "" then null else $ck end), evidence_digest: $digest,
      retain_worktree: ($keep == "yes")}'
}

# Restore checkpoint <id> privately and prove every accounted version is in it.
_rc_verify_checkpoint() { # <id> <partial yes|no>
  local dest="$_RC_TMP/restore" kind p v disp ac eol got
  local allow=(); [ "$2" = yes ] && allow=(--allow-partial)
  bash "$_RC_CK" restore "$RC_ABS" "$1" "$dest" "${allow[@]}" >/dev/null 2>&1 || return 1
  ac="$(git -C "$RC_ABS" config core.autocrlf 2>/dev/null)"; [ -n "$ac" ] || ac=false
  eol="$(git -C "$RC_ABS" config core.eol 2>/dev/null)"; [ -n "$eol" ] || eol=native
  [ "$(git -C "$dest" rev-parse HEAD 2>/dev/null)" = "$RC_HEAD" ] || return 1
  local rawh rawgot
  while IFS=$'\t' read -r kind p v disp _ _ _ _ rawh; do
    [ "$kind" != committed ] || continue # carried by the recovery ref, checked through HEAD above
    if [ "$kind" = index ]; then
      got="$(git -C "$dest" ls-files -s -- ":(literal)$p" 2>/dev/null | awk '{print $1 ":" $2; exit}')"; [ -n "$got" ] || got=deleted
    elif [ -f "$dest/$p" ] && [ ! -L "$dest/$p" ]; then
      got="$(git -C "$dest" -c core.autocrlf="$ac" -c core.eol="$eol" hash-object -- "./$p" 2>/dev/null)" || return 1
      local fb; fb="$(git -C "$dest" ls-files -s -- ":(literal)$p" 2>/dev/null | awk '{print $1; exit}')"
      got="$(_rc_wt_mode "$dest" "$p" "${fb:-100644}"):$got"
      # the restored bytes must be the approved bytes, not just the same clean blob
      rawgot="$(git -C "$dest" hash-object --no-filters -- "./$p" 2>/dev/null)" || return 1
      [ -n "$rawh" ] && [ "$rawh" != - ] && [ "$rawgot" = "$rawh" ] || return 1
    elif [ -e "$dest/$p" ] || [ -L "$dest/$p" ]; then return 1
    else got=deleted; fi
    [ "$got" = "$v" ] || return 1
  done <"$_RC_TMP/versions.tsv"
  return 0
}

_rc_apply_reconcile() { # <session>
  local out rc id cats f tmp before="$RC_DIGEST"
  if [ "$RC_NEEDCK" -eq 0 ]; then id=none
  else
    out="$(bash "$_RC_CK" checkpoint "$RC_ABS" "$1" 2>&1)"; rc=$?
    case "$rc" in
      0|10) ;;
      4) _rc_result reconcile retained "checkpoint-refused-ownership-uncertain:the original is kept"; return 4 ;;
      *) _rc_result reconcile retained "checkpoint-failed-or-interrupted(rc=$rc):the original is kept"; return 4 ;;
    esac
    id="$(printf '%s\n' "$out" | sed -n 's/^id://p' | tr -d '\r' | head -n1)"
    cats="$(printf '%s\n' "$out" | sed -n 's/^unsupported:\([a-z-]*\) .*/\1/p' | grep -vx ignored | sort -u | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$cats" ]; then _rc_result reconcile retained "checkpoint-partial:$cats:the original is kept" "$id"; return 4; fi
    _rc_verify_checkpoint "$id" "$([ "$rc" = 10 ] && echo yes || echo no)" \
      || { _rc_result reconcile retained "checkpoint-verification-failed:the original is kept" "$id"; return 4; }
    # a writer during capture changes the evidence: the capture no longer describes the worktree
    _rc_collect "$RC_ABS" "$RC_REC_ARG" "$RC_TARGET_ARG" "$RC_HERE_TOP"
    [ "$RC_DIGEST" = "$before" ] || { _rc_result reconcile retained "evidence-changed-during-checkpoint" "$id"; return 4; }
  fi
  f="$(_rc_record_file)"; mkdir -p -- "${f%/*}" || { _rc_result reconcile retained record-write-failed "$id"; return 4; }
  tmp="$f.tmp.$$"
  printf 'digest=%s\ncheckpoint=%s\nhead=%s\nrecovery=%s\n' "$RC_DIGEST" "$id" "$RC_HEAD" "${RC_REC_SHA:-none}" >"$tmp" && mv -f -- "$tmp" "$f" \
    || { rm -f -- "$tmp"; _rc_result reconcile retained record-write-failed "$id"; return 4; }
  _rc_result reconcile reconciled "" "$([ "$id" = none ] || echo "$id")"
}

_rc_apply_remove() { # <discard-token>
  local top="$RC_MAIN" j ok=1 left forced=() rf why="" unlinked=0 fp0 fp1 dtok registrations ck="${RC_RECORD_CK:-none}"
  local locked="$RC_LOCKED" reason="$RC_LOCKREASON" branch="$RC_BRANCH" junc="$RC_JUNC" tip="$RC_HEAD"
  rf="$(_rc_record_file)" # resolve while the worktree still exists
  if [ "$RC_IGN_COUNT" -gt 0 ]; then
    # fail closed: an omitted argument, or a token that could not be computed, never matches
    dtok="$(_rc_discard_token)"
    if [ -z "$1" ] || [ -z "$dtok" ] || [ "$1" != "$dtok" ]; then
      _rc_result remove stopped "ignored-files-need-their-own-discard-approval"; return 4
    fi
  fi
  [ "$RC_DIRTY" -eq 1 ] && forced=(--force)
  fp0="$(_rc_content_fp)"
  [ -n "$fp0" ] || { _rc_result remove stopped "content-fingerprint-unavailable"; return 4; }
  if [ "$locked" -eq 1 ] && ! git -C "$top" worktree unlock "$RC_ABS" >/dev/null 2>&1; then
    _rc_result remove stopped unlock-failed; return 4
  fi
  # ---- removal has started: from here every stop reports what was already changed ----
  if [ -n "$junc" ]; then
    while IFS= read -r j; do [ -n "$j" ] || continue; if _la_unlink_junction "$j"; then unlinked=$((unlinked+1)); else ok=0; fi; done <<<"$junc"
    if [ "$ok" -eq 1 ]; then left="$(_la_junctions "$RC_ABS")" && [ -z "$left" ] || ok=0; fi
    [ "$ok" -eq 1 ] || why=junction-unlink-failed
  fi
  if [ "$ok" -eq 1 ]; then
    # Last-moment revalidation, as close to the removal as a script can get: the content and the
    # checkpoint it depends on must be exactly as approved. This narrows, but cannot close, the
    # window for an unmanaged writer or a manual checkpoint prune; the operator confirms both stopped.
    RC_LIGHT=1 _rc_collect "$RC_ABS" "$RC_REC_ARG" "$RC_TARGET_ARG" "$RC_HERE_TOP"
    if [ "$RC_LINKED" -ne 1 ] || [ "$RC_BRANCH" != "$branch" ] || [ "$RC_MAIN" != "$top" ]; then
      ok=0; why=worktree-registration-changed-before-removal
    elif [ "$RC_JPROBE" != ok ] || [ -n "$RC_JUNC" ]; then ok=0; why=junction-state-changed-before-removal
    elif [ "$RC_CLAIM" != free ]; then ok=0; why=live-claim-before-removal
    elif _rc_recent_file_write; then ok=0; why=recent-file-write-before-removal
    elif ! fp1="$(_rc_content_fp)" || [ -z "$fp1" ]; then ok=0; why=content-fingerprint-unavailable-before-removal
    elif [ "$fp1" != "$fp0" ]; then ok=0; why=evidence-changed-before-removal
    elif [ "$ck" != none ] && ! _rc_checkpoint_present "$ck"; then ok=0; why=checkpoint-missing-before-removal; fi
  fi
  if [ "$ok" -eq 1 ]; then
    # `git worktree remove` drops only this worktree's registration; no repository-wide prune.
    if git -C "$top" worktree remove "${forced[@]}" "$RC_ABS" >/dev/null 2>&1; then
      rm -f -- "$rf"
      # Delete the local branch only at the approved tip (compare-and-delete), and never while
      # another worktree has it checked out. A moved or checked-out branch is kept.
      if ! registrations="$(git -C "$top" worktree list --porcelain 2>/dev/null)" || [ -z "$registrations" ]; then
        _rc_result remove removed "branch-registration-unreadable:local-branch-kept" "${ck#none}"
      elif grep -Fxq -- "branch refs/heads/$branch" <<<"$registrations"; then
        _rc_result remove removed "branch-checked-out-elsewhere:local-branch-kept" "${ck#none}"
      elif [ "$(git -C "$top" rev-parse -q --verify "refs/heads/$branch" 2>/dev/null)" != "$tip" ]; then
        _rc_result remove removed "branch-moved-since-approval:local-branch-kept" "${ck#none}"
      elif git -C "$top" update-ref -d "refs/heads/$branch" "$tip" >/dev/null 2>&1; then _rc_result remove removed "" "${ck#none}"
      else _rc_result remove removed "branch-delete-failed:local-branch-kept" "${ck#none}"; fi
      return 0
    fi
    why=worktree-remove-failed
  fi
  local relock=not-locked-before
  if [ "$locked" -eq 1 ]; then
    relock=lock-restore-failed-relock-manually
    if [ -d "$RC_ABS" ]; then
      if [ -n "$reason" ]; then git -C "$top" worktree lock --reason "$reason" "$RC_ABS" >/dev/null 2>&1 && relock=lock-restored
      else git -C "$top" worktree lock "$RC_ABS" >/dev/null 2>&1 && relock=lock-restored; fi
    fi
  fi
  # say what is left, and derive retain_worktree from it rather than from the status alone
  local dir=absent reg=absent left_wt=no
  [ -d "$RC_ABS" ] && { dir=present; left_wt=yes; }
  # the registration may outlive the directory, so match the recorded path text in both the
  # POSIX and the Git-for-Windows (C:/...) spellings rather than resolving a path that is gone
  local wl mixed
  if ! wl="$(git -C "$top" worktree list --porcelain 2>/dev/null)" || [ -z "$wl" ]; then
    reg=unknown; left_wt=yes
  else
    mixed="$(cygpath -m "$RC_ABS" 2>/dev/null || printf '%s' "$RC_ABS")"
    if grep -Fxq -- "worktree $RC_ABS" <<<"$wl" || grep -Fxiq -- "worktree $mixed" <<<"$wl"; then reg=present; left_wt=yes; fi
  fi
  _rc_result remove stopped "remove-failed:$why:$relock:junction-links-unlinked=$unlinked:worktree-dir=$dir:registration=$reg" "${ck#none}" "$left_wt"; return 4
}

# 0 when the final scan saw a changed or untracked FILE written within the recency guard. Only
# file mtimes count (RC_NEWEST): unlinking an approved junction changes the directory's mtime.
_rc_recent_file_write() {
  local guard="${SGE_WT_RECENCY_GUARD_MIN:-10}"
  case "$guard" in ''|*[!0-9]*) guard=10 ;; esac
  case "${RC_NEWEST:-0}" in ''|*[!0-9]*) return 0 ;; esac # unreadable age: fail closed
  [ "$RC_NEWEST" -gt 0 ] || return 1
  [ $(( ($(date +%s) - RC_NEWEST) / 60 )) -lt "$guard" ]
}

rc_main() {
  local cmd="${1:-}"; shift 2>/dev/null
  local sid="" decision="" approval="" discard="" rec="" target="" wt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) shift; sid="${1:-}" ;;
      --decision) shift; decision="${1:-}" ;;
      --approval) shift; approval="${1:-}" ;;
      --discard-ignored) shift; discard="${1:-}" ;;
      --recovery) shift; rec="${1:-}" ;;
      --target) shift; target="${1:-}" ;;
      -*) echo "usage: reconcile.sh plan|apply --session <id> ... <worktree>" >&2; return 2 ;;
      *) [ -z "$wt" ] || { echo "error:one-worktree-per-call" >&2; return 2; }; wt="$1" ;;
    esac
    shift
  done
  _wl_valid_session "$sid" || { echo "error:bad-or-missing-session-id" >&2; return 2; }
  [ -n "$wt" ] || { echo "error:worktree-path-required" >&2; return 2; }
  local abs; abs="$(_wl_abs "$wt" 2>/dev/null)"
  [ -n "$abs" ] && git -C "$abs" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error:not-a-git-worktree" >&2; return 3; }
  RC_HERE_TOP="$(git rev-parse --show-toplevel 2>/dev/null)"; [ -z "$RC_HERE_TOP" ] || RC_HERE_TOP="$(_wl_abs "$RC_HERE_TOP")"
  RC_REC_ARG="$rec"; RC_TARGET_ARG="$target"
  _RC_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sge-reconcile.XXXXXX")" || return 2
  trap _rc_cleanup EXIT
  _rc_collect "$abs" "$rec" "$target" "$RC_HERE_TOP"
  [ "$RC_LINKED" -eq 1 ] || { echo "error:not-a-linked-worktree" >&2; return 3; }
  case "$cmd" in
    plan) [ -n "$RC_DIGEST" ] || { echo "error:evidence-digest-unavailable" >&2; return 2; } # never publish empty tokens
          _rc_plan_json "$sid" || { echo "error:plan-render-failed" >&2; return 2; }; return 0 ;;
    apply) ;;
    *) echo "usage: reconcile.sh plan|apply ..." >&2; return 2 ;;
  esac
  case "$decision" in reconcile|release|remove) ;; *) echo "error:--decision reconcile|release|remove required" >&2; return 2 ;; esac
  # Revalidated from scratch above: a different digest means the approval is stale.
  # an empty approval, digest or token never matches (a failed hash must not approve anything)
  local want; want="$(_rc_token "$decision")"
  if [ -z "$approval" ] || [ -z "$RC_DIGEST" ] || [ -z "$want" ] || [ "$approval" != "$want" ]; then
    _rc_result "$decision" stopped "evidence-changed-since-approval"; return 4
  fi
  [ -z "$RC_BLOCKER" ] || { _rc_result "$decision" stopped "revalidation-$RC_BLOCKER"; return 4; }
  case "$decision" in
    reconcile) _rc_apply_reconcile "$sid"; return $? ;;
  esac
  _rc_reconciled || { _rc_result "$decision" stopped "not-reconciled:run-the-reconcile-decision-first"; return 4; }
  if [ "$decision" = release ]; then
    [ "$RC_LOCKED" -eq 1 ] || { _rc_result release stopped not-locked; return 4; }
    git -C "$RC_MAIN" worktree unlock "$RC_ABS" >/dev/null 2>&1 || { _rc_result release stopped unlock-failed; return 4; }
    _rc_result release released "" "${RC_RECORD_CK#none}"; return 0
  fi
  _rc_apply_remove "$discard"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then rc_main "$@"; exit $?; fi
