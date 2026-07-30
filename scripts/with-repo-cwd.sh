#!/usr/bin/env bash
# with-repo-cwd.sh — shared repo-context resolution for hub/control sessions.
#
# SPEC-057 (issue #817): several skills/scripts resolve `gh`/`git` against the
# AMBIENT working directory. That is correct when the session is already
# checked out in the target repo, but silently acts on the WRONG repo when a
# hub/control checkout (e.g. wtp-org) dispatches work into other repos — no
# error, just wrong data.
#
# This helper is the single place a skill resolves its repo context, once, at
# entry. Given a target repo it resolves an absolute path to a local checkout
# of that repo and hands it to the caller — or FAILS LOUDLY. It never falls
# through to "whatever cwd happens to be": a wrong-repo read/write is worse
# than a blocked skill.
#
# Usage (executed):
#   scripts/with-repo-cwd.sh resolve <target>
#       Print the absolute path of the matching checkout on stdout.
#       Callers then enter it themselves:
#         cd "$(scripts/with-repo-cwd.sh resolve owner/name)" || exit 1
#   scripts/with-repo-cwd.sh exec <target> -- <cmd> [args...]
#       Run <cmd> with cwd set to the checkout and GH_REPO exported to the
#       checkout's owner/name slug.
#   scripts/with-repo-cwd.sh host [<target-or-checkout>]
#       Classify the git host of a repo's `origin` remote and print a stable
#       host-kind token on stdout: `github` | `forgejo` | `unknown`.
#       (`forgejo` covers the Gitea-compatible family — Forgejo and Gitea share
#       one REST surface, so callers route them through the same adapter; the
#       token is `forgejo` because Forgejo is the repo we actually target.)
#       With no argument the CURRENT checkout's origin is classified; with a
#       <target> (name | owner/name | URL) the matching local checkout is
#       resolved first (same rules as `resolve`) and ITS origin classified.
#       This is the single point where a skill learns "is this GitHub?" before
#       choosing gh vs the Forgejo/Gitea REST adapter (ADR-0010, #1236). It is
#       intentionally NOT fail-loud on `unknown`: an unrecognised host is a
#       real, nameable answer downstream code must branch on — resolving the
#       checkout still fails loud if no checkout matches, exactly as before.
#   scripts/with-repo-cwd.sh alm
#       Resolve the declared issue-tracking (ALM) backend for this environment
#       and print a stable token on stdout: `github` | `jira` (SPEC-105).
#       Resolution: SGD_ALM_BACKEND env var; unset/empty means `github` — the
#       status quo, so every existing repo is untouched until it declares a
#       non-GitHub tracker. An UNRECOGNISED value FAILS LOUD naming the value
#       (SPEC-105 DR1): a silent GitHub fallback would dispatch against the
#       wrong tracker, which is strictly worse than stopping. Unlike `host`
#       (which classifies the GIT host from the origin URL), `alm` resolves the
#       ISSUE TRACKER — the two are independent: a GitHub-hosted repo may track
#       work in Jira. This is the single point where a dispatch skill learns
#       "gh issue ... or the ALM-adapter port?" before touching a tracker.
#   scripts/with-repo-cwd.sh assert-repo <owner/name> [-- <cmd> [args...]]
#       Assert-before-write guard (SPEC-057, issue #1558). Confirm that the repo
#       a bare `gh` call would act on RIGHT NOW matches <owner/name>, and print
#       that confirmed slug on stdout (exit 0). The effective repo is computed
#       the way `gh` itself resolves its base repo: `GH_REPO` when set; else
#       `gh repo view` (the gh-resolved default + remote precedence
#       upstream>github>origin), falling back to the current checkout's `origin`
#       only when gh is unavailable. On any mismatch, a bare-name (ownerless)
#       target, or when no effective repo can be determined, FAIL LOUDLY
#       (non-zero, nothing on stdout) naming both the effective and the
#       requested repo. Unlike `resolve` (which finds a checkout), this verifies
#       the AMBIENT gh target — run it immediately before a cross-repo write
#       (`gh issue comment`, `gh pr comment`, …) so a hub/control session can
#       never post an artefact onto the wrong repo when a same-numbered
#       issue/PR collides. A fully-qualified owner/name is REQUIRED (a bare name
#       would match any owner's same-named repo — fail closed).
#       With `-- <cmd>`: run <cmd> ONLY if the assert passes (exec after check),
#       fusing the guard to the write so a single tool call cannot write to the
#       wrong repo even if the check and the write were split across shells.
#   scripts/with-repo-cwd.sh issue-repo <tracking-repo> [<body-file>]
#       Parse the structured EXECUTION-REPO field from an issue body (read from
#       <body-file>, or stdin when omitted) and print the execution repo slug
#       on stdout. An issue is *tracked* in one repo but may *execute* (its
#       worktree / agent-lock / PR) in another — this command extracts and
#       validates that field (SPEC-057, issue #863). Field grammar:
#           Repo: owner/name            (short form; value must be slug/URL)
#           execution-repo: owner/name  (explicit form)
#           exec-repo: owner/name       (alias)
#       The value may be owner/name or a GitHub URL. `Repo: —` (or absent) means
#       "same as the tracking repo", so this prints <tracking-repo>. A malformed
#       explicit field, or two fields naming DIFFERENT repos, FAILS LOUDLY
#       (nothing on stdout) — never silently picks a repo. A bare `repo:` line
#       whose value is not slug/URL-shaped is treated as prose, not the field.
#
# Usage (sourced):
#   source scripts/with-repo-cwd.sh          # defines with_repo_cwd, no side effects
#   with_repo_cwd <target>                   # cd into the checkout + export GH_REPO,
#                                            # or return non-zero after a loud error
#
# <target> forms:
#   name              e.g. sgd
#   owner/name        e.g. WealthTechPros/sgd   (owner is then verified too)
#   GitHub URL        e.g. https://github.com/owner/name/issues/123
#                     (an issue/PR's repository URL works as-is)
#
# Resolution order:
#   0. If the CURRENT checkout's `origin` already matches the target, use it.
#      This keeps in-repo sessions working and covers git worktrees whose
#      directory names don't match the repo name (e.g. issue-NNN worktrees).
#   1. <root>/<name> for each root in SGD_CHECKOUT_ROOTS (';'-separated —
#      ';' not ':' so Windows drive-letter paths survive).
#   2. <root>/<name> where <root> is the parent directory of the current
#      checkout (the sibling-clone layout hub/control sessions use).
#   3. <root>/<name> where <root> is the parent directory of the checkout
#      containing this script.
# A candidate only matches if it is a git checkout whose `origin` remote
# resolves to the requested repo (owner compared when given). A directory
# with the right NAME but the wrong origin is rejected — and reported.
#
# Fail-loud convention (SPEC-057 solution items 1+3+4): when no checkout
# matches, exit non-zero with a clear, actionable error. NEVER proceed
# against the ambient working directory.
# END_USAGE
#
# NOTE for skill authors: shell state does NOT persist across agent tool
# calls. Re-enter the repo context at the top of EVERY shell call that runs
# `gh`/`git`, e.g. `cd "$(scripts/with-repo-cwd.sh resolve owner/name)"`.
# See docs/skill-authoring-repo-context.md.

_WRC_SELF="${BASH_SOURCE[0]}"
_WRC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_wrc_err() { printf 'with-repo-cwd: error: %s\n' "$*" >&2; }

_wrc_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Normalise a git remote URL to its trailing "owner/name" slug (case kept).
# Handles https://host/owner/name(.git), git@host:owner/name(.git),
# ssh://git@host/owner/name(.git), with or without a trailing slash.
# A degenerate URL with no separator at all (e.g. an origin of just 'name')
# carries no owner/name structure — return non-zero (empty slug) so callers
# treat it as unverifiable rather than matching name against itself.
_wrc_url_slug() {
  local url="$1" name owner
  url="${url%/}"
  url="${url%.git}"
  url="${url//:/\/}"        # git@host:owner/name -> git@host/owner/name
  case "$url" in
    */*) ;;
    *) return 1 ;;
  esac
  name="${url##*/}"
  url="${url%/*}"
  owner="${url##*/}"
  printf '%s/%s' "$owner" "$name"
}

# Extract the bare host (no user@, no :port) from a git remote URL.
# Handles https://host/..., ssh://git@host/..., git@host:owner/name, and a
# host:port form. Empty on a URL with no discernible host.
_wrc_url_host() {
  local url="$1" h
  case "$url" in
    http://*|https://*|ssh://*)
      h="${url#*://}"          # [user@]host[:port]/path
      h="${h#*@}"              # drop any user@
      h="${h%%/*}"             # host[:port]
      h="${h%%:*}"             # host
      ;;
    git@*)                     # scp-like: git@host:owner/name
      h="${url#*@}"            # host:owner/name
      h="${h%%:*}"             # host
      ;;
    *) h="" ;;
  esac
  printf '%s' "$h"
}

# Classify a git host into a stable adapter-routing token:
#   github  — github.com (or a *.github.com subdomain)
#   forgejo — anything we route through the Gitea-compatible REST adapter.
#             Forgejo and Gitea share one API surface; the token is `forgejo`
#             because Forgejo is the host the enabler targets (ADR-0010).
#             We recognise it by host substring (forgejo/gitea) OR by the
#             SGD_FORGEJO_HOSTS allow-list (';'-separated bare hosts) so a
#             self-hosted instance with a vanity domain (e.g. git.feaw.co.uk)
#             classifies correctly without a code change.
#   unknown — a real, nameable answer; NOT a failure. Downstream code branches
#             on it (and may itself fail loud if it has no adapter for it).
# GitHub Enterprise Server (self-hosted GHES) is intentionally NOT auto-mapped
# to `github` here — it needs its own gh/API config; declare it via
# SGD_GITHUB_HOSTS (';'-separated) if a fleet uses one.
_wrc_host_kind() { # <host>
  local host
  host="$(_wrc_lower "$1")"
  [ -n "$host" ] || { printf 'unknown'; return 0; }
  local h
  if [ -n "${SGD_GITHUB_HOSTS:-}" ]; then
    local ghs=(); IFS=';' read -r -a ghs <<< "$(_wrc_lower "$SGD_GITHUB_HOSTS")"
    for h in "${ghs[@]}"; do [ -n "$h" ] && [ "$host" = "$h" ] && { printf 'github'; return 0; }; done
  fi
  if [ -n "${SGD_FORGEJO_HOSTS:-}" ]; then
    local fjs=(); IFS=';' read -r -a fjs <<< "$(_wrc_lower "$SGD_FORGEJO_HOSTS")"
    for h in "${fjs[@]}"; do [ -n "$h" ] && [ "$host" = "$h" ] && { printf 'forgejo'; return 0; }; done
  fi
  case "$host" in
    github.com|*.github.com) printf 'github' ;;
    *forgejo*|*gitea*)       printf 'forgejo' ;;
    *)                       printf 'unknown' ;;
  esac
}

# Classify the host-kind of a repo's origin. With a <target>, resolve the
# matching checkout first (fail-loud, same as `resolve`); with none, use cwd.
_wrc_host() { # [<target>]
  local dir url
  if [ -n "${1:-}" ]; then
    dir="$(_wrc_resolve "$1")" || return $?
  else
    dir="$(git rev-parse --show-toplevel 2>/dev/null)" || dir=""
    [ -n "$dir" ] || { _wrc_err "not inside a git checkout and no <target> given"; return 1; }
  fi
  url="$(git -C "$dir" remote get-url origin 2>/dev/null)" \
    || { _wrc_err "no 'origin' remote on checkout '$dir'"; return 1; }
  _wrc_host_kind "$(_wrc_url_host "$url")"
  printf '\n'
}

# Resolve the declared issue-tracking (ALM) backend (SPEC-105). Distinct from
# _wrc_host: `host` classifies the GIT host from the origin URL; this resolves
# the ISSUE TRACKER, which a repo declares explicitly (a GitHub-hosted repo may
# track work in Jira). Unset/empty = `github` (the status quo — the port stays
# dark until a repo declares a non-GitHub tracker, SPEC-105 §3). An
# unrecognised value FAILS LOUD naming it (DR1): a silent GitHub fallback would
# dispatch against the wrong tracker.
_wrc_alm_backend() {
  local backend="${SGD_ALM_BACKEND:-}"
  case "$(_wrc_lower "$backend")" in
    ''|github) printf 'github\n' ;;
    jira)      printf 'jira\n' ;;
    *)
      _wrc_err "unrecognised ALM backend '$backend' (SGD_ALM_BACKEND) — known backends: github, jira; refusing to fall back to GitHub (SPEC-105 DR1)"
      return 1
      ;;
  esac
}

# Parse <target> into _WRC_OWNER (may be empty) and _WRC_NAME.
_wrc_parse_target() {
  local t="$1" stripped
  _WRC_OWNER=""
  _WRC_NAME=""
  case "$t" in
    http://*|https://*|ssh://*|git@*)
      case "$t" in
        git@*)                        # scp-like: git@host:owner/name[.git]
          stripped="${t#*@}"          # host:owner/name[.git]
          case "$stripped" in
            *:*) stripped="${stripped#*:}" ;;
            *)   stripped="" ;;
          esac
          ;;
        *)
          stripped="${t#*://}"        # [user@]host[:port]/owner/name[/...]
          stripped="${stripped#*@}"   # drop any user@ prefix
          case "$stripped" in         # drop host[:port] up to the first '/',
            */*) stripped="${stripped#*/}" ;;   # so a ':port' never leaks into owner
            *)   stripped="" ;;
          esac
          ;;
      esac
      case "$stripped" in
        */*)
          _WRC_OWNER="${stripped%%/*}"
          stripped="${stripped#*/}"
          _WRC_NAME="${stripped%%/*}"
          _WRC_NAME="${_WRC_NAME%.git}"
          ;;
        *)
          _wrc_err "cannot parse an owner/name path from URL '$t'"
          return 2
          ;;
      esac
      ;;
    */*)
      _WRC_OWNER="${t%%/*}"
      _WRC_NAME="${t#*/}"
      _WRC_NAME="${_WRC_NAME%.git}"
      ;;
    *)
      _WRC_NAME="$t"
      ;;
  esac
  [ -n "$_WRC_NAME" ] || { _wrc_err "cannot parse a target repo from '$t'"; return 2; }
}

# Is <dir> a git checkout whose origin matches <name> (and <owner>, if given)?
_wrc_dir_matches() { # <dir> <name> <owner-or-empty>
  local dir="$1" name owner url slug
  name="$(_wrc_lower "$2")"
  owner="$(_wrc_lower "${3:-}")"
  url="$(git -C "$dir" remote get-url origin 2>/dev/null)" || return 1
  slug="$(_wrc_lower "$(_wrc_url_slug "$url")")"
  [ "${slug##*/}" = "$name" ] || return 1
  if [ -n "$owner" ]; then
    [ "${slug%%/*}" = "$owner" ] || return 1
  fi
  return 0
}

# Resolve <target> to an absolute checkout path on stdout, or fail loudly.
_wrc_resolve() {
  local target="$1" name owner
  _wrc_parse_target "$target" || return 2
  name="$_WRC_NAME"
  owner="$_WRC_OWNER"

  # 0. Current checkout already matches (worktrees keep arbitrary dir names).
  local cur_top=""
  cur_top="$(git rev-parse --show-toplevel 2>/dev/null)" || cur_top=""
  if [ -n "$cur_top" ] && _wrc_dir_matches "$cur_top" "$name" "$owner"; then
    printf '%s\n' "$cur_top"
    return 0
  fi

  # Build the ordered root list.
  local roots=() r
  if [ -n "${SGD_CHECKOUT_ROOTS:-}" ]; then
    local _wrc_env_roots=()
    IFS=';' read -r -a _wrc_env_roots <<< "$SGD_CHECKOUT_ROOTS"
    for r in "${_wrc_env_roots[@]}"; do
      [ -n "$r" ] && roots+=("$r")
    done
  fi
  [ -n "$cur_top" ] && roots+=("$(dirname "$cur_top")")
  local script_top=""
  script_top="$(git -C "$_WRC_SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || script_top=""
  [ -n "$script_top" ] && roots+=("$(dirname "$script_top")")

  # Scan (deduped, in order). First verified match wins.
  local searched=() mismatches=() seen="" cand
  for r in "${roots[@]}"; do
    case ";$seen;" in *";$r;"*) continue ;; esac
    seen="$seen;$r"
    searched+=("$r")
    cand="$r/$name"
    [ -d "$cand" ] || continue
    if _wrc_dir_matches "$cand" "$name" "$owner"; then
      # Only report success when the canonical path was actually emitted — a
      # candidate that races away between the origin check and the cd must
      # fall through to the loud failure, never succeed with empty stdout.
      (cd "$cand" && pwd) && return 0
    fi
    mismatches+=("$cand")
  done

  # Fail loudly — never fall back to the ambient cwd.
  local want="${owner:+$owner/}$name"
  _wrc_err "no checkout of '$want' found"
  {
    printf '  searched roots (as <root>/%s):\n' "$name"
    for r in "${searched[@]}"; do printf '    - %s\n' "$r"; done
    if [ "${#mismatches[@]}" -gt 0 ]; then
      printf "  rejected (directory exists but its git 'origin' is not %s):\n" "$want"
      for cand in "${mismatches[@]}"; do printf '    - %s\n' "$cand"; done
    fi
    printf '  Fix: clone %s under one of those roots, or point SGD_CHECKOUT_ROOTS\n' "$want"
    printf "  (';'-separated) at the directory that contains your checkouts.\n"
    printf '  Refusing to fall back to the ambient working directory (SPEC-057 fail-loud convention).\n'
  } >&2
  return 1
}

# --- Assert-before-write guard (SPEC-057, issue #1558) ------------------------
# The repo a bare `gh` call acts on is GH_REPO when set, else the current
# checkout's origin. This is the single place a skill re-confirms that ambient
# target matches what it MEANT to write to, before a cross-repo comment/label.

# Reduce a raw repo string to a lowercased "owner/name": strip a trailing '/'
# and '.git', then keep the LAST TWO path segments so gh's accepted
# host/owner/name form and a plain owner/name both land on owner/name. A value
# with no '/' yields an empty owner (name only). Nothing on stdout on empty in.
_wrc_norm_slug() { # <raw> -> owner/name (owner may be empty)
  local v name rest owner
  v="$(_wrc_lower "$1")"
  v="${v%/}"; v="${v%.git}"
  [ -n "$v" ] || return 1
  name="${v##*/}"
  if [ "$name" = "$v" ]; then
    owner=""                       # no slash at all
  else
    rest="${v%/*}"
    owner="${rest##*/}"            # segment immediately before the name
  fi
  printf '%s/%s' "$owner" "$name"
}

# Print the effective repo slug (owner/name) a bare `gh` call would target now,
# or fail (non-zero, nothing on stdout) when it cannot be determined.
#
# gh resolves its base repo as: GH_REPO -> a `gh repo set-default` marker
# (gh-resolved git config) -> remotes by precedence (upstream > github > origin)
# — which is NOT always `origin`. To measure what a bare `gh issue comment`
# would ACTUALLY target we mirror that:
#   * GH_REPO set  -> it wins for every gh command; use it verbatim.
#   * GH_REPO unset -> `gh repo view --json nameWithOwner` resolves exactly the
#     gh-resolved default + remote precedence (it deliberately ignores GH_REPO,
#     which is why we only call it in this branch). Fall back to the `origin`
#     slug only when gh is unavailable/unauthenticated so the guard still works
#     offline (best-effort; a divergent non-origin default can't be seen then).
_wrc_effective_repo() {
  if [ -n "${GH_REPO:-}" ]; then
    printf '%s' "$GH_REPO"
    return 0
  fi
  local slug top url
  if slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
     && [ -n "$slug" ]; then
    printf '%s' "$slug"
    return 0
  fi
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  # `origin` is a safe proxy for gh's target ONLY when no higher-precedence
  # remote exists (gh order: upstream > github > origin). If gh could not
  # answer (offline/erroring) AND such a remote is present, gh would resolve a
  # DIFFERENT repo than origin — trusting origin would fail open. Refuse
  # instead (issue #1558 re-review): a wrong-repo write is worse than a block.
  local hp
  for hp in upstream github; do
    if git -C "$top" remote get-url "$hp" >/dev/null 2>&1; then
      _wrc_err "cannot resolve gh's base repo (gh unavailable) and a higher-precedence '$hp' remote is present, so 'origin' is not a safe proxy for gh's target — refusing (fail closed)."
      return 1
    fi
  done
  url="$(git -C "$top" remote get-url origin 2>/dev/null)" || return 1
  slug="$(_wrc_url_slug "$url")" || return 1
  printf '%s' "$slug"
}

# Assert the effective repo matches <target>; echo the confirmed slug or fail loud.
# A write guard demands a fully-qualified owner/name target — a bare name would
# match any owner's same-named repo, so it is refused (fail closed).
_wrc_assert_repo() { # <target>
  local target="$1" eff want_owner want_name eff_slug eff_owner eff_name
  _wrc_parse_target "$target" || return 2   # sets _WRC_OWNER (maybe empty), _WRC_NAME
  want_owner="$(_wrc_lower "$_WRC_OWNER")"
  want_name="$(_wrc_lower "$_WRC_NAME")"
  if [ -z "$want_owner" ]; then
    _wrc_err "assert-repo: target '$target' has no owner — a write guard requires a fully-qualified owner/name slug (bare '$want_name' would match any owner's same-named repo)."
    return 2
  fi

  if ! eff="$(_wrc_effective_repo)" || [ -z "$eff" ]; then
    _wrc_err "assert-repo: cannot determine the repo the next gh call would act on — no GH_REPO set and not inside a git checkout with an 'origin'. Refusing to write against an unknown repo (SPEC-057 assert-before-write)."
    return 1
  fi

  eff_slug="$(_wrc_norm_slug "$eff")" || {
    _wrc_err "assert-repo: could not normalise the effective repo '$eff' to owner/name — refusing to proceed."
    return 1
  }
  eff_owner="${eff_slug%%/*}"
  eff_name="${eff_slug##*/}"

  if [ -z "$eff_owner" ] || [ "$eff_name" != "$want_name" ] || [ "$eff_owner" != "$want_owner" ]; then
    _wrc_err "assert-repo: effective repo is '$eff' but the requested target is '$want_owner/$want_name' — refusing to act on the wrong repo (SPEC-057 assert-before-write, issue #1558)."
    return 1
  fi
  printf '%s\n' "$eff_slug"
  return 0
}

# --- Execution-repo issue-body field (SPEC-057, issue #863) -------------------
# An issue is TRACKED in one repo but may EXECUTE in another. The field says so.

# Normalise a raw field value to an owner/name slug on stdout.
# Return 0 = slug printed; 3 = "none" (—/-/none/empty, means "same as tracking");
# 1 = malformed (not owner/name and not a parseable URL).
_wrc_value_to_slug() {
  local v="$1" slug
  # trim surrounding whitespace (incl. a trailing CR from CRLF bodies)
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  v="${v%$'\r'}"
  v="${v%/}"
  v="${v%.git}"
  case "$v" in
    ''|'—'|'-'|'–'|[Nn][Oo][Nn][Ee]) return 3 ;;
  esac
  case "$v" in
    http://*|https://*|ssh://*|git@*)
      # A GitHub issue/PR URL carries owner/name as its first two path segments;
      # _wrc_parse_target extracts them correctly (unlike the trailing-two-segment
      # _wrc_url_slug, which would read ".../issues/9" as "issues/9").
      _wrc_parse_target "$v" 2>/dev/null || return 1
      [ -n "$_WRC_OWNER" ] && [ -n "$_WRC_NAME" ] || return 1
      printf '%s/%s' "$_WRC_OWNER" "$_WRC_NAME"
      return 0
      ;;
  esac
  # owner/name: exactly one slash, both segments from the GitHub-legal set.
  case "$v" in
    */*/*) return 1 ;;                              # more than one slash
    */*)
      case "${v%%/*}" in *[!A-Za-z0-9._-]*) return 1 ;; esac
      case "${v#*/}"  in *[!A-Za-z0-9._-]*) return 1 ;; esac
      [ -n "${v%%/*}" ] && [ -n "${v#*/}" ] || return 1
      printf '%s' "$v"
      return 0
      ;;
  esac
  return 1                                          # bare name / junk
}

# Parse the execution-repo field from an issue body on stdin.
# Prints the resolved execution slug (or the tracking slug when the field is
# absent / "none") and returns 0, or fails loudly (non-zero, nothing on stdout).
_wrc_issue_repo() {
  local tracking="$1" chosen="" line kw val slug rc had_conflict=0
  # Normalise the tracking repo to owner/name (or bare name) for the default.
  local track_slug
  _wrc_parse_target "$tracking" || return 2
  track_slug="${_WRC_OWNER:+$_WRC_OWNER/}$_WRC_NAME"

  local saved_nocasematch
  saved_nocasematch="$(shopt -p nocasematch || true)"   # returns non-zero when off
  shopt -s nocasematch
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    kw=""; val=""
    if [[ "$line" =~ ^[[:space:]]*(execution[-_\ ]?repo|exec[-_\ ]?repo)[[:space:]]*:[[:space:]]*(.+)$ ]]; then
      kw="explicit"; val="${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^[[:space:]]*repo[[:space:]]*:[[:space:]]*(.+)$ ]]; then
      kw="short"; val="${BASH_REMATCH[1]}"
    else
      continue
    fi
    rc=0; slug="$(_wrc_value_to_slug "$val")" || rc=$?   # guarded: set -e safe
    if [ "$rc" -eq 3 ]; then
      continue                                      # explicit "none" -> tracking
    fi
    if [ "$rc" -ne 0 ]; then
      if [ "$kw" = "explicit" ]; then
        eval "$saved_nocasematch"
        _wrc_err "malformed execution-repo field value '$val' — expected owner/name or a GitHub URL"
        return 2
      fi
      continue                                      # short 'repo:' + prose value -> ignore
    fi
    if [ -z "$chosen" ]; then
      chosen="$slug"
    elif [ "$(_wrc_lower "$slug")" != "$(_wrc_lower "$chosen")" ]; then
      had_conflict=1
    fi
  done
  eval "$saved_nocasematch"

  if [ "$had_conflict" -ne 0 ]; then
    _wrc_err "conflicting execution-repo fields in the issue body — refuse to guess which repo to execute in"
    return 2
  fi
  printf '%s\n' "${chosen:-$track_slug}"
  return 0
}

# Sourced entry point: cd into the target checkout + export GH_REPO.
with_repo_cwd() {
  local path
  if [ -z "${1:-}" ]; then
    _wrc_err 'usage: with_repo_cwd <name | owner/name | github-url>'
    return 2
  fi
  path="$(_wrc_resolve "$1")" || return $?
  [ -n "$path" ] || { _wrc_err "resolver returned an empty path for '$1'"; return 1; }
  cd "$path" || { _wrc_err "resolved '$path' but could not cd into it"; return 1; }
  GH_REPO="$(_wrc_url_slug "$(git -C "$path" remote get-url origin)")"
  export GH_REPO
  printf 'with-repo-cwd: repo context = %s (%s)\n' "$GH_REPO" "$path" >&2
  return 0
}

_wrc_usage() {
  [ -n "${1:-}" ] && _wrc_err "$1"
  # awk, not sed: BSD/macOS sed rejects the `{ /re/d; p }` one-liner address
  # form ("extra characters at the end of p command"), which broke printing
  # this block exactly when a caller had the subcommand wrong (issue #1675).
  awk '/^# END_USAGE/{exit} f{sub(/^# ?/,""); print} /^# Usage \(executed\):/{f=1; sub(/^# ?/,""); print}' "$_WRC_SELF" >&2
  exit 2
}

_wrc_main() {
  local cmd="${1:-}"
  case "$cmd" in
    resolve)
      [ -n "${2:-}" ] || _wrc_usage 'resolve needs a <target>'
      _wrc_resolve "$2"
      ;;
    exec)
      [ -n "${2:-}" ] || _wrc_usage 'exec needs a <target>'
      local target="$2"
      shift 2
      [ "${1:-}" = "--" ] || _wrc_usage "exec requires '--' between <target> and the command"
      shift
      [ "$#" -gt 0 ] || _wrc_usage 'exec: no command given after --'
      local path
      path="$(_wrc_resolve "$target")" || exit $?
      [ -n "$path" ] || { _wrc_err "resolver returned an empty path for '$target'"; exit 1; }
      cd "$path" || { _wrc_err "resolved '$path' but could not cd into it"; exit 1; }
      GH_REPO="$(_wrc_url_slug "$(git -C "$path" remote get-url origin)")"
      export GH_REPO
      exec "$@"
      ;;
    host)
      # Optional <target>; no arg = current checkout.
      _wrc_host "${2:-}"
      ;;
    alm)
      [ "$#" -le 1 ] || _wrc_usage "alm takes no arguments (backend is declared via SGD_ALM_BACKEND)"
      _wrc_alm_backend
      ;;
    assert-repo)
      [ -n "${2:-}" ] || _wrc_usage 'assert-repo needs a <target>'
      local at="$2"
      shift 2
      if [ "${1:-}" = "--" ]; then
        # Fused check+write: only exec the command when the assert passes, so a
        # single tool call cannot write to the wrong repo (issue #1558).
        shift
        [ "$#" -gt 0 ] || _wrc_usage 'assert-repo: no command given after --'
        _wrc_assert_repo "$at" >/dev/null || exit $?
        exec "$@"
      elif [ "$#" -gt 0 ]; then
        _wrc_usage "assert-repo: unexpected argument '$1' (use '-- <cmd>' to fuse a command to the assert)"
      else
        _wrc_assert_repo "$at"
      fi
      ;;
    issue-repo)
      [ -n "${2:-}" ] || _wrc_usage 'issue-repo needs a <tracking-repo>'
      local tracking="$2" bodyfile="${3:-}"
      if [ -n "$bodyfile" ]; then
        [ -f "$bodyfile" ] || { _wrc_err "issue-repo: body file not found: $bodyfile"; exit 2; }
        _wrc_issue_repo "$tracking" < "$bodyfile"
      else
        _wrc_issue_repo "$tracking"
      fi
      ;;
    -h|--help|help|'')
      _wrc_usage
      ;;
    *)
      _wrc_usage "unknown command '$cmd'"
      ;;
  esac
}

# Executed (not sourced): run the CLI. Sourcing only defines functions —
# deliberately no `set -e` side effects on the sourcing shell.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  _wrc_main "$@"
fi
