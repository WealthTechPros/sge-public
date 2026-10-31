#!/usr/bin/env bash
# checkpoint.sh — secured, NON-DESTRUCTIVE checkpoint storage for a session-owned
# worktree (issue #3234, epic #3216, SPEC-139 "Preserve actual unfinished work
# without modifying the user's checkout" + "Incomplete coverage fails safe").
#
#   checkpoint.sh checkpoint <worktree> <session-id>
#   checkpoint.sh list       <path-in-repo>
#   checkpoint.sh restore    <path-in-repo> <id> <dest> [--allow-partial]
#   checkpoint.sh prune      <path-in-repo> <id> --yes       # MANUAL only
#
# What a checkpoint preserves
#   * committed objects: a durable recovery ref refs/sge/checkpoints/<id> at HEAD
#     (GC-safe; lives in the repo's common git dir, never in the checkout);
#   * staged and unstaged tracked changes as two separate binary-safe patches, so
#     the staged/unstaged distinction survives;
#   * untracked-and-not-ignored regular files (content + exec bit).
#   Contents go to a per-user store OUTSIDE the checkout and outside synchronised
#   folders: %LOCALAPPDATA%\sge\checkpoints on Windows, ${XDG_STATE_HOME:-~/.local/state}
#   /sge/checkpoints elsewhere (override: SGE_CHECKPOINT_DIR, validated identically).
#   Owner-only permissions (mode 700 / owner-only ACL), no custom crypto: disk
#   encryption (e.g. BitLocker) is the at-rest control. Nothing is ever written
#   into the checkout, the index or the branch; the script uses temp storage,
#   GIT_OPTIONAL_LOCKS=0 and read-only git commands against the worktree.
#
# Fail safe (never described as fully backed up or safe to remove)
#   Ignored files, secret-pattern / client-data files, unreadable or special
#   paths, symlinks, nested repos, submodules and unmerged paths are NOT
#   captured. The result names the unsupported coverage (categories, counts and
#   sanitised path names only; never contents), status is "partial", exit 10, and
#   the output always carries retain-worktree:yes + safe-to-remove:no. This tool
#   never authorises deletion of a worktree. Uncertain ownership (not a
#   registered linked worktree of THIS session) is refused with nothing written.
#
# Atomicity: payload and manifest are built in a private temp dir inside the
# store and renamed into place last; interrupted runs leave only a ".tmp.*" dir
# that is listed as "interrupted:" and never advertised as a checkpoint.
# Retention: recovery data is never auto-purged; `prune --yes` is manual only.
#
# All paths, branch names and ids are untrusted DATA: only ever passed as quoted
# arguments or NUL-delimited files, never interpolated into shell text.
#
# Exit codes: 0 ok/complete, 2 usage, 3 not a git worktree, 4 ownership
#   uncertain, 5 bad session id, 6 unsafe store/destination, 7 inconsistent
#   capture (active writer), 8 failure/integrity, 9 partial restore refused,
#   10 checkpoint partial (unsupported coverage).

set -uo pipefail
umask 077
export GIT_OPTIONAL_LOCKS=0
export LC_ALL=C

_CK_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_CK_HERE/../lib/worktree-lifecycle.sh"
set +e # the sourced libs enable errexit; this tool handles every status explicitly

_CK_WORK=""
_CK_ID_RE='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$'

_ck_cleanup() { [ -n "$_CK_WORK" ] && [ -d "$_CK_WORK" ] && rm -rf "$_CK_WORK"; return 0; }

_ck_err() { printf 'error:%s\n' "$1" >&2; }
_ck_san() { printf '%s' "$1" | tr -c '[:print:]' '?'; }

_ck_is_windows() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }

_ck_refuse() { # <exit> <reason>  — uniform refusal block; nothing was written
  printf 'result:refused\nreason:%s\ncoverage:none\nretain-worktree:yes\nsafe-to-remove:no\n' "$2"
  return "$1"
}

# ------------------------------------------------------------------ store
_ck_abs_path() { # absolute, symlink-resolved path even if the tail does not exist yet
  local p="$1" head tail=""
  case "$p" in /*) ;; *) return 1 ;; esac
  while [ ! -e "$p" ] && [ "$p" != "/" ]; do tail="/${p##*/}$tail"; p="${p%/*}"; [ -n "$p" ] || p="/"; done
  head="$(cd "$p" 2>/dev/null && pwd -P)" || return 1
  [ "$head" = "/" ] && head=""
  printf '%s%s\n' "$head" "$tail"
}

_ck_store_root() {
  local r="${SGE_CHECKPOINT_DIR:-}"
  if [ -z "$r" ]; then
    if _ck_is_windows; then
      [ -n "${LOCALAPPDATA:-}" ] || return 1
      r="$(cygpath -u "$LOCALAPPDATA" 2>/dev/null)/sge/checkpoints" || return 1
    else
      [ -n "${XDG_STATE_HOME:-${HOME:-}}" ] || return 1
      r="${XDG_STATE_HOME:-$HOME/.local/state}/sge/checkpoints"
    fi
  fi
  _ck_abs_path "$r"
}

# 0 when the (resolved) path is acceptable as a store/destination root.
_ck_location_ok() { # <abs path> <worktree> <common-dir>
  local p="$1" wt common main seg v
  wt="$(_wl_abs "$2")" || return 1
  common="$(_wl_abs "$3")" || return 1
  main="$(_wl_abs "$(dirname "$common")")" || return 1
  case "$p" in */../*|*/..|*/./*|*/.) return 1 ;; esac
  case "$p/" in "$wt/"*|"$main/"*|"$common/"*) return 1 ;; esac
  if _ck_is_windows; then # NTFS is case-insensitive
    local lp lwt lmain lcommon
    lp="$(printf '%s' "$p/" | tr 'A-Z' 'a-z')"; lwt="$(printf '%s' "$wt/" | tr 'A-Z' 'a-z')"
    lmain="$(printf '%s' "$main/" | tr 'A-Z' 'a-z')"; lcommon="$(printf '%s' "$common/" | tr 'A-Z' 'a-z')"
    case "$lp" in "$lwt"*|"$lmain"*|"$lcommon"*) return 1 ;; esac
  fi
  # Synchronised-folder markers by path component (case-insensitive).
  shopt -s nocasematch
  while IFS= read -r seg; do
    case "$seg" in
      onedrive*|dropbox*|"google drive"*|googledrive*|icloud*|"mobile documents"|sharepoint*|"box sync"|pcloud*|nextcloud*|owncloud*|syncthing*|"sync.com"*) shopt -u nocasematch; return 1 ;;
    esac
  done < <(printf '%s' "$p" | tr '/' '\n')
  shopt -u nocasematch
  if _ck_is_windows; then
    for v in "${OneDrive:-}" "${OneDriveCommercial:-}" "${OneDriveConsumer:-}"; do
      [ -n "$v" ] || continue
      v="$(cygpath -u "$v" 2>/dev/null)" || continue
      v="$(_ck_abs_path "$v")" || continue
      case "$p/" in "$v/"*) return 1 ;; esac
    done
  fi
  return 0
}

_ck_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

_ck_win_secure() { # owner-only ACL on a directory we created
  local d u
  d="$(cygpath -w "$1")" || return 1
  u="${USERNAME:-$(id -un 2>/dev/null)}"
  [ -n "$u" ] || return 1
  MSYS2_ARG_CONV_EXCL="*" icacls "$d" /inheritance:r /grant:r "$u:(OI)(CI)F" /Q >/dev/null 2>&1
}

_ck_win_owner_only() { # allowlist: only the current user, SYSTEM and Administrators
  local d out line princ me1 me2
  d="$(cygpath -w "$1")" || return 1
  out="$(icacls "$d" 2>/dev/null)" || return 1
  local bs='\'; me1="${USERDOMAIN:-}${bs}${USERNAME:-}"; me2="${COMPUTERNAME:-}${bs}${USERNAME:-}"
  while IFS= read -r line; do
    case "$line" in "$d "*) line="${line#"$d "}" ;; esac
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|Successfully*|Failed*) continue ;; esac
    princ="${line%%:(*}"
    [ "$princ" != "$line" ] || return 1
    shopt -s nocasematch
    case "$princ" in
      "NT AUTHORITY\SYSTEM"|"BUILTIN\Administrators"|"$me1"|"$me2"|"${USERNAME:-@@}") shopt -u nocasematch ;;
      *) shopt -u nocasematch; return 1 ;;
    esac
  done <<<"$out"
  return 0
}

# Make <dir> exist and be owner-only. Directories WE create are secured; a
# pre-existing directory is only verified (never re-permissioned): fail closed.
_ck_secure_dir() {
  local d="$1" created=0 m
  if [ ! -d "$d" ]; then
    _ck_secure_dir "${d%/*}" || return 1
    mkdir "$d" 2>/dev/null || return 1
    created=1
  elif [ -L "$d" ]; then
    return 1
  fi
  if _ck_is_windows; then
    [ "$created" = 1 ] && { _ck_win_secure "$d" || return 1; }
    _ck_win_owner_only "$d" || return 1
  else
    [ "$created" = 1 ] && chmod 700 "$d" 2>/dev/null
    [ -O "$d" ] || return 1
    m="$(_ck_mode "$d")"
    case "$m" in 700) ;; *) return 1 ;; esac
  fi
  return 0
}

# _ck_secure_dir would also secure shared ancestors (HOME, /tmp...) if they were
# missing; only the part below an existing directory is ever created.
_ck_make_store() { # <root> -> creates root + repo key dir, owner-only
  local root="$1" up="$1" missing=()
  while [ ! -d "$up" ] && [ "$up" != "/" ]; do missing+=("$up"); up="${up%/*}"; [ -n "$up" ] || up="/"; done
  local i d
  for ((i=${#missing[@]}-1; i>=0; i--)); do
    d="${missing[$i]}"
    mkdir "$d" 2>/dev/null || return 1
    if _ck_is_windows; then _ck_win_secure "$d" || return 1; else chmod 700 "$d" 2>/dev/null || return 1; fi
  done
  _ck_secure_dir "$root"
}

# ------------------------------------------------------------------ secrets
_ck_write_patterns() { # <file>
  cat >"$1" <<'PATTERNS'
-----BEGIN [A-Z0-9 -]*PRIVATE KEY-----
AKIA[0-9A-Z]{16}
(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}
github_pat_[A-Za-z0-9_]{20,}
xox[abprs]-[A-Za-z0-9-]{10,}
(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}
AIza[0-9A-Za-z_-]{30,}
eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.
[a-z][a-z0-9+.-]*://[^/[:space:]:@$<{]+:[^/[:space:]:@$<{]{4,}@
(bearer|basic)[[:space:]]+[a-z0-9._~+/=-]{20,}
(secret|token|passw(or)?d|passwd|pwd|api[_-]?key|apikey|private[_-]?key|credential|access[_-]?key|auth[_-]?key)[a-z0-9_.-]*["'`]?[[:space:]]*(:=|=>|=|:)[[:space:]]*["'`]?[a-z0-9][a-z0-9!@#%^&*_.:/+=?~-]{7,}
PATTERNS
}

# 0 when the path NAME is secret- or client-data-shaped (reuses the fleet
# client-data convention: *.xls*, downloads/, root exports/).
_ck_secret_name() {
  local p="$1" b="${1##*/}" rc=1
  shopt -s nocasematch
  case "$b" in
    .env.example|.env.sample|.env.template|.env.dist) rc=1 ;;
    .env|.env.*|*.pem|*.key|*.pfx|*.p12|*.jks|*.keystore|*.kdbx|id_rsa*|id_dsa*|id_ecdsa*|id_ed25519*|.npmrc|.netrc|.pypirc|.git-credentials|.htpasswd|credentials|credentials.json|*secret*|*.tfvars|terraform.tfstate*|service-account*.json|*.ovpn|.pgpass|*.p8|*.ppk|*.asc|*.gpg|kubeconfig) rc=0 ;;
    *.xls|*.xlsx|*.xlsm|*.xlsb) rc=0 ;;
  esac
  if [ "$rc" != 0 ]; then
    case "$p" in downloads/*|*/downloads/*|exports/*) rc=0 ;; esac
  fi
  shopt -u nocasematch
  return "$rc"
}

# ------------------------------------------------------------------ git wrappers
_ck_git() { git -C "$_CK_WT" -c core.fsmonitor=false -c core.quotepath=off "$@"; }

# Hash a worktree file by path RELATIVE to the worktree: native Windows git
# mangles absolute MSYS paths containing ';' (treated as a path-list separator).
_ck_hash_rel() { git -C "$_CK_WT" hash-object --no-filters -- "./$1" 2>/dev/null; }

_ck_hash_file() { git hash-object --no-filters -- "$1" 2>/dev/null; }

_ck_fingerprint() { # status + HEAD, hashed
  { _ck_git rev-parse -q --verify HEAD 2>/dev/null
    _ck_git status --porcelain=v1 -z --no-renames --untracked-files=all 2>/dev/null
    _ck_git diff --binary --full-index --no-ext-diff --no-textconv 2>/dev/null
    _ck_git diff --cached --binary --full-index --no-ext-diff --no-textconv 2>/dev/null
  } | git hash-object --stdin
}

_ck_unsup() { printf '%s\t%s\n' "$1" "$(_ck_san "$2")" >>"$_CK_WORK/unsupported.tsv"; }

# ------------------------------------------------------------------ checkpoint
ck_checkpoint() {
  local wt="$1" sid="${2:-}" common abs entry owner root keydir id ts rnd
  local head branch fault=""
  # Test-only fault injection (interrupted-write fixtures); inert unless both are set.
  [ "${SGE_CHECKPOINT_TEST_ALLOW:-}" = 1 ] && fault="${SGE_CHECKPOINT_TEST_FAULT:-}"
  _wl_valid_session "$sid" || { _ck_err bad-session-id; return 5; }
  case "$wt" in -*|'') _ck_err bad-path; return 3 ;; esac
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { _ck_err not-a-git-worktree; return 3; }
  common="$(_wl_common_dir "$wt")" || return 3
  abs="$(_wl_abs "$wt")" || return 3

  # Ownership: only a registered linked worktree owned by THIS session. Anything
  # else is uncertain ownership => refuse and write nothing.
  entry="$common/sge-worktrees/$(_wl_key "$abs").entry"
  if [ ! -f "$entry" ]; then _ck_refuse 4 ownership-uncertain-not-registered; return 4; fi
  owner="$(_wl_entry_field "$entry" session)"
  if [ "$owner" != "$sid" ]; then _ck_refuse 4 ownership-uncertain-other-session; return 4; fi

  root="$(_ck_store_root)" || { _ck_refuse 6 store-unresolvable; return 6; }
  _ck_location_ok "$root" "$abs" "$common" || { _ck_refuse 6 store-location-unsafe; return 6; }
  _ck_make_store "$root" || { _ck_refuse 6 store-permissions; return 6; }
  keydir="$root/$(printf '%s' "$common" | git hash-object --stdin | cut -c1-16)"
  _ck_secure_dir "$keydir" || { _ck_refuse 6 store-permissions; return 6; }

  _CK_WT="$abs"
  trap _ck_cleanup EXIT
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  rnd="$(printf '%08x' $(( (RANDOM * 32768 + RANDOM) & 0xffffffff )))"
  id="$ts-$rnd"
  [ ! -e "$keydir/$id" ] || { _ck_err id-collision; return 8; }
  _CK_WORK="$(mktemp -d "$keydir/.tmp.XXXXXX")" || { _ck_err cannot-create-temp; return 8; }
  local W="$_CK_WORK"
  mkdir "$W/untracked" || return 8
  : >"$W/unsupported.tsv"; : >"$W/tracked.pspec"; : >"$W/untracked.nul"; : >"$W/untracked.idx"
  _ck_write_patterns "$W/patterns"

  local fp0 fp1
  fp0="$(_ck_fingerprint)" || { _ck_err status-failed; return 8; }

  # Committed objects: durable recovery ref (created first so it exists even if
  # a later step is interrupted).
  head="$(_ck_git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || true)"
  branch="$(_ck_git symbolic-ref -q --short HEAD 2>/dev/null || echo '(detached)')"
  if [ -n "$head" ]; then
    git --git-dir="$common" update-ref "refs/sge/checkpoints/$id" "$head" "" || { _ck_err recovery-ref-failed; return 8; }
  fi

  # Enumerate. A status failure or any stderr warning means coverage unknown.
  local statf="$W/status.nul" staterr="$W/status.err"
  _ck_git status --porcelain=v1 -z --no-renames --untracked-files=all --ignored=traditional >"$statf" 2>"$staterr" \
    || { _ck_err status-failed; return 8; }
  [ ! -s "$staterr" ] || _ck_unsup inaccessible "(directory or path could not be enumerated)"

  local rec xy X Y p lsrec mode sha flagged grc
  while IFS= read -r -d '' rec; do
    xy="${rec:0:2}"; p="${rec:3}"
    X="${xy:0:1}"; Y="${xy:1:1}"
    case "$xy" in
      '!!') _ck_unsup ignored "$p"; continue ;;
      '??')
        case "$p" in */) _ck_unsup nested-repository "$p"; continue ;; esac
        if [ -L "$abs/$p" ]; then _ck_unsup symlink "$p"; continue; fi
        if [ ! -f "$abs/$p" ]; then _ck_unsup special-file "$p"; continue; fi
        if [ ! -r "$abs/$p" ]; then _ck_unsup inaccessible "$p"; continue; fi
        if _ck_secret_name "$p"; then _ck_unsup secret-pattern "$p"; continue; fi
        LC_ALL=C grep -aEiqf "$W/patterns" -- "$abs/$p"; grc=$?
        if [ "$grc" = 0 ]; then _ck_unsup secret-pattern "$p"; continue; fi
        if [ "$grc" != 1 ]; then _ck_unsup inaccessible "$p"; continue; fi
        printf '%s\0' "$p" >>"$W/untracked.nul"
        ;;
      *)
        if [ "$X" = U ] || [ "$Y" = U ] || [ "$xy" = AA ] || [ "$xy" = DD ]; then _ck_unsup unmerged "$p"; continue; fi
        flagged=""
        mode=""; sha=""
        lsrec="$(_ck_git ls-files -s -z -- ":(literal)$p" 2>/dev/null | tr '\0' '\n' | head -n 1)"
        if [ -n "$lsrec" ]; then mode="${lsrec%% *}"; sha="${lsrec#* }"; sha="${sha%% *}"; fi
        if [ "$mode" = 160000 ]; then _ck_unsup submodule "$p"; continue; fi
        # Worktree-side content
        if [ "$Y" != D ] && { [ -e "$abs/$p" ] || [ -L "$abs/$p" ]; } && [ ! -L "$abs/$p" ]; then
          if [ ! -f "$abs/$p" ]; then flagged=special-file
          elif [ ! -r "$abs/$p" ]; then flagged=inaccessible
          else
            if _ck_secret_name "$p"; then flagged=secret-pattern; else
              LC_ALL=C grep -aEiqf "$W/patterns" -- "$abs/$p"; grc=$?
              [ "$grc" = 0 ] && flagged=secret-pattern
              [ "$grc" -gt 1 ] && flagged=inaccessible
            fi
          fi
        fi
        # Staged-side content
        if [ -z "$flagged" ] && [ -n "$sha" ]; then
          case "$X" in A|M|T)
            if _ck_secret_name "$p"; then flagged=secret-pattern; else
              # temp file, not a pipe: under pipefail an early-exiting grep -q would
              # SIGPIPE cat-file and the scan would silently fail open.
              if _ck_git cat-file blob "$sha" >"$W/blob.tmp" 2>/dev/null; then
                LC_ALL=C grep -aEiqf "$W/patterns" -- "$W/blob.tmp"; grc=$?
                [ "$grc" = 0 ] && flagged=secret-pattern
                [ "$grc" -gt 1 ] && flagged=inaccessible
              else flagged=inaccessible; fi
              rm -f "$W/blob.tmp"
            fi ;;
          esac
        fi
        if [ -n "$flagged" ]; then _ck_unsup "$flagged" "$p"; continue; fi
        printf ':(literal)%s\0' "$p" >>"$W/tracked.pspec"
        ;;
    esac
  done <"$statf"

  # assume-unchanged / skip-worktree / sparse-excluded paths are invisible to
  # `git status`: edits there would be missed, so they are unsupported coverage.
  local lsv tag
  while IFS= read -r -d '' lsv; do
    tag="${lsv:0:1}"
    case "$tag" in [a-z]|S) _ck_unsup hidden-change "${lsv:2}" ;; esac
  done < <(_ck_git ls-files -v -z 2>/dev/null)

  # Tracked changes: staged and unstaged as separate binary-safe patches.
  local dopts=(diff --binary --full-index --no-ext-diff --no-textconv --no-color --src-prefix=a/ --dst-prefix=b/)
  if [ -s "$W/tracked.pspec" ]; then
    : >"$W/staged.patch"; : >"$W/unstaged.patch"
    xargs -0 -n 100 git -C "$abs" -c core.fsmonitor=false -c diff.noprefix=false -c diff.mnemonicPrefix=false "${dopts[@]:0:1}" --cached "${dopts[@]:1}" -- <"$W/tracked.pspec" >"$W/staged.patch" 2>/dev/null \
      || { _ck_err staged-diff-failed; return 8; }
    xargs -0 -n 100 git -C "$abs" -c core.fsmonitor=false -c diff.noprefix=false -c diff.mnemonicPrefix=false "${dopts[@]}" -- <"$W/tracked.pspec" >"$W/unstaged.patch" 2>/dev/null \
      || { _ck_err unstaged-diff-failed; return 8; }
  fi

  # Untracked files: copy + verify (hash before == hash of copy == hash after).
  local n=0 h1 h2 h3 m
  while IFS= read -r -d '' p; do
    h1="$(_ck_hash_rel "$p")" || { _ck_err hash-failed; return 8; }
    # TOCTOU: re-check the type right before copying; never follow a symlink swapped in.
    if [ -L "$abs/$p" ] || [ ! -f "$abs/$p" ]; then _ck_unsup symlink "$p"; continue; fi
    cp -- "$abs/$p" "$W/untracked/$n" 2>/dev/null || { _ck_unsup inaccessible "$p"; continue; }
    if [ -L "$W/untracked/$n" ] || [ ! -f "$W/untracked/$n" ]; then rm -f "$W/untracked/$n"; _ck_unsup symlink "$p"; continue; fi
    h2="$(_ck_hash_file "$W/untracked/$n")"; h3="$(_ck_hash_rel "$p")"
    if [ "$h1" != "$h2" ] || [ "$h1" != "$h3" ]; then _ck_err inconsistent-capture-active-writer; return 7; fi
    m="-"; [ -x "$abs/$p" ] && m="x"
    printf '%s\t%s\t%s\n' "$n" "$h1" "$m" >>"$W/untracked.idx"
    printf '%s\0' "$p" >>"$W/untracked.names"
    n=$((n+1))
  done <"$W/untracked.nul"
  [ -f "$W/untracked.names" ] || : >"$W/untracked.names"
  rm -f "$W/untracked.nul"

  # Late-secret / torn-capture guard: only content that was scanned may be stored.
  # Added lines of both patches and every untracked copy are re-scanned; a hit can
  # only mean the file changed after the scan (an active writer).
  local rf
  for rf in "$W/staged.patch" "$W/unstaged.patch"; do
    [ -f "$rf" ] || continue
    grep -a '^+' "$rf" | LC_ALL=C grep -aEiqf "$W/patterns" -
    case "${PIPESTATUS[1]}" in 0) _ck_err inconsistent-capture-late-secret; return 7 ;; 1) ;; *) _ck_err rescan-failed; return 8 ;; esac
  done
  for ((rf=0; rf<n; rf++)); do
    LC_ALL=C grep -aEiqf "$W/patterns" -- "$W/untracked/$rf"; grc=$?
    case "$grc" in 0) _ck_err inconsistent-capture-late-secret; return 7 ;; 1) ;; *) _ck_err rescan-failed; return 8 ;; esac
  done

  fp1="$(_ck_fingerprint)" || { _ck_err status-failed; return 8; }
  if [ "$fp0" != "$fp1" ]; then _ck_err inconsistent-capture-active-writer; return 7; fi

  [ "$fault" != after-payload ] || { trap - EXIT; exit 99; }

  # Manifest last, written atomically; the directory is renamed into place only
  # when everything above succeeded.
  local status=complete
  [ -s "$W/unsupported.tsv" ] && status=partial
  {
    echo "sge-checkpoint=1"
    echo "id=$id"
    echo "status=$status"
    echo "created=$ts"
    echo "session=$sid"
    echo "worktree=$(_ck_san "$abs")"
    echo "branch=$(_ck_san "$branch")"
    echo "head=${head:-none}"
    echo "ref=$([ -n "$head" ] && echo "refs/sge/checkpoints/$id" || echo none)"
    echo "staged_patch=$([ -f "$W/staged.patch" ] && _ck_hash_file "$W/staged.patch" || echo none)"
    echo "unstaged_patch=$([ -f "$W/unstaged.patch" ] && _ck_hash_file "$W/unstaged.patch" || echo none)"
    echo "untracked_count=$n"
    echo "untracked_idx=$(_ck_hash_file "$W/untracked.idx")"
    echo "untracked_names=$(_ck_hash_file "$W/untracked.names")"
    awk -F'\t' '{c[$1]++} END{for(k in c) printf "unsupported.%s=%d\n", k, c[k]}' "$W/unsupported.tsv" | sort
  } >"$W/manifest.tmp" || return 8
  mv "$W/manifest.tmp" "$W/manifest" || return 8
  [ "$fault" != before-rename ] || { trap - EXIT; exit 98; }
  mv "$W" "$keydir/$id" || { _ck_err commit-rename-failed; return 8; }
  _CK_WORK=""

  # Result block: categories, counts and sanitised names only; never contents.
  printf 'result:%s\nid:%s\nstore:%s\nrecovery-ref:%s\n' "$status" "$id" "$keydir/$id" "$([ -n "$head" ] && echo "refs/sge/checkpoints/$id" || echo none)"
  printf 'untracked-files-captured:%s\n' "$n"
  if [ "$status" = complete ]; then
    printf 'coverage:complete\nretain-worktree:yes\nsafe-to-remove:no\nnote:removal-is-a-separate-user-confirmed-step\n'
    return 0
  fi
  printf 'coverage:partial\n'
  awk -F'\t' '{c[$1]++} END{for(k in c) printf "unsupported:%s count=%d\n", k, c[k]}' "$keydir/$id/unsupported.tsv" 2>/dev/null | sort
  awk -F'\t' '{ if (++s[$1] <= 20) printf "unsupported-path:%s %s\n", $1, $2 }' "$keydir/$id/unsupported.tsv" 2>/dev/null
  printf 'retain-worktree:yes\nsafe-to-remove:no\nnote:partial-checkpoint-unsupported-coverage-listed-above\n'
  return 10
}

# ------------------------------------------------------------------ repo/store lookup
_ck_locate() { # <path-in-repo> -> sets _CK_COMMON _CK_KEYDIR (no creation)
  local root
  case "$1" in -*|'') return 3 ;; esac
  _CK_COMMON="$(_wl_common_dir "$1")" || return 3
  root="$(_ck_store_root)" || return 6
  _CK_ROOT="$root"
  _CK_KEYDIR="$root/$(printf '%s' "$_CK_COMMON" | git hash-object --stdin | cut -c1-16)"
  # Never trust a store that is not private to this user (a group/world-writable
  # store would widen same-user tampering).
  [ ! -e "$root" ] || _ck_secure_dir "$root" || return 6
  [ ! -e "$_CK_KEYDIR" ] || _ck_secure_dir "$_CK_KEYDIR" || return 6
  return 0
}

_ck_field() { sed -n "s/^$2=//p" "$1" | head -n 1; }

ck_list() {
  local rc d id f
  _ck_locate "${1:-}"; rc=$?
  [ "$rc" = 0 ] || { _ck_err store-unsafe-or-not-a-git-worktree; return "$rc"; }
  [ -d "$_CK_KEYDIR" ] || return 0
  for d in "$_CK_KEYDIR"/*/ "$_CK_KEYDIR"/.tmp.*/; do
    [ -d "$d" ] && [ ! -L "${d%/}" ] || continue
    id="$(basename "$d")"
    case "$id" in
      .tmp.*) printf 'interrupted:%s\n' "$id" ;;
      *)
        printf '%s' "$id" | grep -Eq "$_CK_ID_RE" || continue
        f="$d/manifest"
        [ -f "$f" ] || continue
        printf 'checkpoint:%s status=%s created=%s worktree=%s\n' "$id" "$(_ck_field "$f" status)" "$(_ck_san "$(_ck_field "$f" created)")" "$(_ck_san "$(_ck_field "$f" worktree)")"
        ;;
    esac
  done
}

# ------------------------------------------------------------------ restore
_ck_safe_rel() { # relative, no traversal, no .git (any case / NTFS alias), no ADS colon
  local c lc
  case "$1" in ''|/*|[A-Za-z]:*|*\*|*:*) return 1 ;; esac
  case "/$1/" in */../*|*/./*|*//*) return 1 ;; esac
  while IFS= read -r c; do
    lc="$(printf '%s' "$c" | tr 'A-Z' 'a-z')"
    while case "$lc" in *.|*" ") true ;; *) false ;; esac; do lc="${lc%?}"; done
    case "$lc" in .git|git~[0-9]*) return 1 ;; esac
  done < <(printf '%s' "$1" | tr '/' '\n')
  return 0
}

ck_restore() {
  local src="${1:-}" id="${2:-}" dest="${3:-}" allow="${4:-}"
  [ -n "$src" ] && [ -n "$id" ] && [ -n "$dest" ] || { _ck_err usage; return 2; }
  printf '%s' "$id" | grep -Eq "$_CK_ID_RE" || { _ck_err bad-id; return 2; }
  case "$dest" in -*) _ck_err bad-dest; return 6 ;; esac
  [ -z "$allow" ] || [ "$allow" = --allow-partial ] || { _ck_err usage; return 2; }
  local rc
  _ck_locate "$src"; rc=$?
  [ "$rc" = 0 ] || { _ck_err store-unsafe-or-not-a-git-worktree; return "$rc"; }
  local cdir="$_CK_KEYDIR/$id" m
  [ -d "$cdir" ] && [ ! -L "$cdir" ] && [ -f "$cdir/manifest" ] || { _ck_err checkpoint-not-found; return 8; }
  _ck_secure_dir "$cdir" || { _ck_err store-unsafe; return 6; }
  m="$cdir/manifest"
  [ "$(_ck_field "$m" sge-checkpoint)" = 1 ] && [ "$(_ck_field "$m" id)" = "$id" ] || { _ck_err manifest-invalid; return 8; }
  if [ "$(_ck_field "$m" status)" != complete ] && [ "$allow" != --allow-partial ]; then
    printf 'result:refused\nreason:checkpoint-partial-use---allow-partial\n'; return 9
  fi
  # Integrity
  local f key want
  for key in staged_patch unstaged_patch; do
    want="$(_ck_field "$m" "$key")"; f="$cdir/${key%_patch}.patch"
    if [ "$want" != none ]; then [ -f "$f" ] && [ "$(_ck_hash_file "$f")" = "$want" ] || { _ck_err "integrity-$key"; return 8; }; fi
  done
  [ "$(_ck_hash_file "$cdir/untracked.idx")" = "$(_ck_field "$m" untracked_idx)" ] || { _ck_err integrity-untracked-idx; return 8; }
  [ "$(_ck_hash_file "$cdir/untracked.names")" = "$(_ck_field "$m" untracked_names)" ] || { _ck_err integrity-untracked-names; return 8; }
  local n h x
  local cnt=0 want_cnt
  want_cnt="$(_ck_field "$m" untracked_count)"
  while IFS=$'\t' read -r n h x; do
    # Fields come from the store: strictly validate before any use as a path.
    if ! { printf '%s' "$n" | grep -Eq '^[0-9]+$' && printf '%s' "$h" | grep -Eq '^[0-9a-f]{40,64}$' && { [ "$x" = x ] || [ "$x" = - ]; }; }; then
      _ck_err integrity-untracked-index; return 8
    fi
    { [ -f "$cdir/untracked/$n" ] && [ ! -L "$cdir/untracked/$n" ] && [ "$(_ck_hash_file "$cdir/untracked/$n")" = "$h" ]; } || { _ck_err integrity-untracked; return 8; }
    cnt=$((cnt+1))
  done <"$cdir/untracked.idx"
  [ "$cnt" = "$want_cnt" ] || { _ck_err integrity-untracked-count; return 8; }

  # Destination: new or empty, outside every worktree/main checkout of the repo.
  local absdest wtp
  absdest="$(_ck_abs_path "$dest")" || { _ck_err dest-not-absolute; return 6; }
  if [ -e "$absdest" ]; then
    [ -d "$absdest" ] && [ -z "$(ls -A "$absdest" 2>/dev/null)" ] || { _ck_err dest-not-empty; return 6; }
  fi
  while IFS= read -r wtp; do
    wtp="$(_wl_abs "$wtp" 2>/dev/null)" || continue
    case "$absdest/" in "$wtp/"*) _ck_err dest-inside-existing-worktree; return 6 ;; esac
  done < <(git -C "$src" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  case "$absdest/" in "$(_wl_abs "$_CK_COMMON")/"*) _ck_err dest-inside-git-dir; return 6 ;; esac
  _ck_location_ok "$absdest" "$(dirname "$_CK_COMMON")" "$_CK_COMMON" || { _ck_err dest-location-unsafe; return 6; }

  local created_dest=0
  if [ ! -d "$absdest" ]; then
    mkdir -p -- "${absdest%/*}" || return 6
    mkdir "$absdest" || return 6; created_dest=1
    if _ck_is_windows; then _ck_win_secure "$absdest" || { rm -rf "$absdest"; return 6; }; else chmod 700 "$absdest" 2>/dev/null; fi
  fi
  _ck_restore_fail() { [ "$created_dest" = 1 ] && rm -rf "$absdest"; _ck_err "$1"; return 8; }

  git init -q --template= "$absdest" 2>/dev/null || { _ck_restore_fail init-failed; return 8; }
  git -C "$absdest" config core.autocrlf false
  git -C "$absdest" config core.safecrlf false
  local head
  head="$(_ck_field "$m" head)"
  if [ "$head" != none ]; then
    git -C "$absdest" fetch -q --no-tags -- "$_CK_COMMON" "refs/sge/checkpoints/$id" 2>/dev/null \
      || { _ck_restore_fail recovery-ref-missing; return 8; }
    git -C "$absdest" checkout -q --detach FETCH_HEAD 2>/dev/null || { _ck_restore_fail checkout-failed; return 8; }
    [ "$(git -C "$absdest" rev-parse HEAD)" = "$head" ] || { _ck_restore_fail head-mismatch; return 8; }
  fi
  if [ "$(_ck_field "$m" staged_patch)" != none ] && [ -s "$cdir/staged.patch" ]; then
    git -C "$absdest" apply --index --binary --whitespace=nowarn -- "$cdir/staged.patch" 2>/dev/null || { _ck_restore_fail staged-apply-failed; return 8; }
  fi
  if [ "$(_ck_field "$m" unstaged_patch)" != none ] && [ -s "$cdir/unstaged.patch" ]; then
    git -C "$absdest" apply --binary --whitespace=nowarn -- "$cdir/unstaged.patch" 2>/dev/null || { _ck_restore_fail unstaged-apply-failed; return 8; }
  fi
  local p parent
  exec 3<"$cdir/untracked.idx"
  while IFS= read -r -d '' p; do
    IFS=$'\t' read -r n h x <&3 || { _ck_restore_fail untracked-index-short; return 8; }
    _ck_safe_rel "$p" || { _ck_restore_fail unsafe-recorded-path; return 8; }
    mkdir -p -- "$absdest/$(dirname -- "./$p")" || { _ck_restore_fail mkdir-failed; return 8; }
    # Never write through a symlink (e.g. one materialised by the patch): the
    # resolved parent must stay inside the destination.
    parent="$(cd "$absdest/$(dirname -- "./$p")" 2>/dev/null && pwd -P)" || { _ck_restore_fail mkdir-failed; return 8; }
    case "$parent/" in "$absdest/"*) ;; *) _ck_restore_fail unsafe-recorded-path; return 8 ;; esac
    [ ! -L "$absdest/$p" ] || { _ck_restore_fail unsafe-recorded-path; return 8; }
    cp -- "$cdir/untracked/$n" "$absdest/$p" || { _ck_restore_fail copy-failed; return 8; }
    [ "$x" = x ] && chmod +x "$absdest/$p"
  done <"$cdir/untracked.names"
  exec 3<&-
  printf 'result:restored\nid:%s\ndest:%s\nstatus:%s\n' "$id" "$absdest" "$(_ck_field "$m" status)"
  return 0
}

# ------------------------------------------------------------------ prune (manual)
ck_prune() {
  local src="${1:-}" id="${2:-}" yes="${3:-}"
  [ "$yes" = --yes ] || { _ck_err "prune-requires---yes (manual deletion of recovery data)"; return 2; }
  local rc d
  _ck_locate "$src"; rc=$?
  [ "$rc" = 0 ] || { _ck_err store-unsafe-or-not-a-git-worktree; return "$rc"; }
  if printf '%s' "$id" | grep -Eq "$_CK_ID_RE"; then
    d="$_CK_KEYDIR/$id"
    [ -d "$d" ] && [ ! -L "$d" ] || { _ck_err checkpoint-not-found; return 8; }
    rm -rf -- "$d" || return 8
    git -C "$src" update-ref -d "refs/sge/checkpoints/$id" 2>/dev/null || true
  elif printf '%s' "$id" | grep -Eq '^\.tmp\.[A-Za-z0-9]{6}$'; then
    d="$_CK_KEYDIR/$id"
    [ -d "$d" ] && [ ! -L "$d" ] || { _ck_err checkpoint-not-found; return 8; }
    rm -rf -- "$d" || return 8
  else
    _ck_err bad-id; return 2
  fi
  printf 'pruned:%s\n' "$id"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    checkpoint)
      ck_checkpoint "$@"; rc=$?
      case "$rc" in 3|7|8) printf 'result:failed
coverage:none
retain-worktree:yes
safe-to-remove:no
' ;; esac
      exit "$rc" ;;
    list)       ck_list "$@"; exit $? ;;
    restore)    ck_restore "$@"; exit $? ;;
    prune)      ck_prune "$@"; exit $? ;;
    *) echo "usage: checkpoint.sh checkpoint <wt> <sid> | list <path> | restore <path> <id> <dest> [--allow-partial] | prune <path> <id> --yes" >&2; exit 2 ;;
  esac
fi
