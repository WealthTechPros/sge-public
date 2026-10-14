# shellcheck shell=bash
# pr-labels-forgejo-claim.sh — the claim half of the pr-labels.sh gate state
# machine on Forgejo/Gitea (SPEC-094 §2.2a, slice S1 #3068 of the #3029 port).
# Sourced by pr-labels-forgejo.d/claim.sh; never executed, never sourced on a
# GitHub or Azure Repos host.
#
# Subcommands implemented here (pr-labels.sh's exit codes, unchanged):
#   start-review <pr> [--force-claim]   exit 3 = claim lost or a live claim by
#                                       another agent. SGE_REVIEW_CLAIM_HANDOFF_OWNER
#                                       (set by the review daemon) takes over the
#                                       dispatcher's own live pre-claim.
#   release-review <pr> [--force]       exit 3 = another owner's live claim
#   claim-fix <pr> [--force-claim]      the fixing lane: a DISTINCT `fixing` claim
#                                       (own ref series, own TTL) + the pr-fixing
#                                       label; exit 3 = a live review or fix claim
#                                       held by another agent
#   release-fix <pr> [--force]          exit 3 = another owner's live fix claim
#   heartbeat <pr>                      exit 7 = this agent does not hold the
#                                       review claim; any API error is non-zero
#   status <pr>                         "reviewing=<b> reviewed=<b>" (the forgejo
#                                       contract the inline path has always had)
#
# The mutex is a compare-and-swap git ref owned by scripts/forgejo-adapter.d/
# claim.sh (verbs pr-claim / pr-release-claim / pr-claim-status /
# pr-claim-heartbeat); the labels are display only and move through
# fpr_add_label / fpr_remove_label. Fail closed: every adapter call is checked,
# an error is a non-zero exit, and no `gh` call is ever made.
#
# Other consumers (the verdict slice S2) gate on the claim with
# `_prl_fj_cl_require_claim <pr> [reviewing|fixing]`: 0 = this agent holds the
# current generation, 7 = it does not, 1 = the claim state is unreadable.
#
# NOT here (still the E1 fail-closed stubs, exit 75): claim-status, claim-work,
# release-work, reconcile-orphaned-claim. The work lane and the orphaned-claim
# reconciler need their own slice; until it lands they run the pre-existing
# inline path, which does not see a claim taken here.

_PRL_FJ_CL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_prl_fj_cl_err() { printf 'pr-labels (forgejo): %s\n' "$*" >&2; }

_prl_fj_cl_adapter() { printf '%s' "${_PRL_ADAPTER:-$_PRL_FJ_CL_DIR/../../scripts/forgejo-adapter.sh}"; }

_prl_fj_cl_origin() {
  if [ -n "${_PRL_ORIGIN:-}" ]; then printf '%s' "$_PRL_ORIGIN"; return 0; fi
  if [ -n "${FORGEJO_ORIGIN:-}" ]; then printf '%s' "$FORGEJO_ORIGIN"; return 0; fi
  git remote get-url origin 2>/dev/null
}

# _prl_fj_cl_call <adapter-args...> — one adapter call, writes permitted (this
# module IS the review lane's explicit write path, as pr-labels.sh's own forgejo
# block decides). Output on stdout, status passed through.
_prl_fj_cl_call() {
  local a o
  a="$(_prl_fj_cl_adapter)"
  [ -f "$a" ] || { _prl_fj_cl_err "forgejo-adapter.sh not found — refusing"; return 1; }
  command -v jq >/dev/null 2>&1 || { _prl_fj_cl_err "jq is required — refusing"; return 1; }
  o="$(_prl_fj_cl_origin)" && [ -n "$o" ] || { _prl_fj_cl_err "no origin to resolve the repository from — refusing"; return 1; }
  FORGEJO_ADAPTER_ALLOW_WRITE=1 bash "$a" "$1" "$o" "${@:2}"
}

# _prl_fj_cl_label <add|remove> <pr> <label> — label side effects go through the
# fpr_* seam (skills/lib/forgejo-pr-mutate.sh), in a subshell so its
# `set -euo pipefail` never leaks into pr-labels.sh. The host kind, origin and
# adapter are pinned to what the dispatcher already resolved (no second cwd
# probe, and never the GitHub branch of fpr_*).
_prl_fj_cl_label() {
  local op="$1" pr="$2" label="$3" adapter
  # A distinct name: fpr_* declares its own `local origin`, which would shadow
  # ours inside the _fpr_origin_url override below.
  _PRL_FJ_CL_PIN_ORIGIN="$(_prl_fj_cl_origin)" && [ -n "$_PRL_FJ_CL_PIN_ORIGIN" ] \
    || { _prl_fj_cl_err "no origin — refusing"; return 1; }
  adapter="$(_prl_fj_cl_adapter)"
  (
    # shellcheck disable=SC1091
    . "$_PRL_FJ_CL_DIR/../lib/forgejo-pr-mutate.sh" >/dev/null 2>&1 || exit 1
    _FPR_HOST_KIND=forgejo
    _FPR_ADAPTER="$adapter"
    _fpr_origin_url() { printf '%s\n' "$_PRL_FJ_CL_PIN_ORIGIN"; }
    case "$op" in
      add)    fpr_add_label "$pr" "$label" ;;
      remove) fpr_remove_label "$pr" "$label" ;;
      *)      exit 2 ;;
    esac
  ) >/dev/null
}

_prl_fj_cl_ensure_label() { # <name> <color> <description>
  _prl_fj_cl_call pr-ensure-label "$1" "$2" "$3" >/dev/null
}

_prl_fj_cl_ensure_review_labels() {
  _prl_fj_cl_ensure_label pr-reviewing FBCA04 "PR review in progress (SGE)" || return 1
  _prl_fj_cl_ensure_label pr-reviewed 0E8A16 "Reviewed via SGE PR-review gate" || return 1
  _prl_fj_cl_ensure_label changes-requested D93F0B "Review failed — findings need addressing (SGE)" || return 1
}

# claim TTLs (seconds): review honours SGE_REVIEW_CLAIM_TTL (the GitHub knob,
# default 900); the fixing lane honours SGE_FIX_CLAIM_TTL_MIN (default 30 min).
# Exported for the adapter, which ages the claim from the server's clock.
_prl_fj_cl_ttl() { # <kind> -> seconds
  local v
  case "$1" in
    fixing)
      v="${SGE_FIX_CLAIM_TTL_MIN:-30}"
      [[ "$v" =~ ^[1-9][0-9]*$ ]] || return 1
      printf '%s' $((v * 60)) ;;
    *)
      v="${SGE_REVIEW_CLAIM_TTL:-900}"
      [[ "$v" =~ ^[1-9][0-9]*$ ]] || return 1
      printf '%s' "$v" ;;
  esac
}

# _prl_fj_cl_adapter_claim <verb> <pr> <kind> [args...] — an adapter claim verb
# with the lane's TTL exported. A malformed TTL is a refusal, never a default.
_prl_fj_cl_adapter_claim() {
  local verb="$1" pr="$2" kind="$3" ttl
  shift 3
  ttl="$(_prl_fj_cl_ttl "$kind")" || { _prl_fj_cl_err "refusing: the claim TTL for '$kind' (SGE_REVIEW_CLAIM_TTL / SGE_FIX_CLAIM_TTL_MIN) is not a positive integer"; return 1; }
  SGE_FORGEJO_CLAIM_TTL="$ttl" _prl_fj_cl_call "$verb" "$pr" "$kind" "$@"
}

# _prl_fj_cl_state <pr> <kind> -> prints "claimed=.. gen=.. owner=.. live=.. mine=.."
_prl_fj_cl_state() { _prl_fj_cl_adapter_claim pr-claim-status "$1" "$2"; }

# _prl_fj_cl_foreign_live <state-line> -> 0 when ANOTHER agent holds it live OR
# the liveness cannot be proven stale (fail closed: unknown never reads as free).
_prl_fj_cl_foreign_live() {
  # An allow-list of what reads as free: nothing claimed, this agent's own
  # claim, or a claim PROVEN stale. Anything else, including a state line this
  # code does not recognise, is someone else's (fail closed).
  case " $1 " in
    *" claimed=false "*) return 1 ;;
    *" claimed=true "*" mine=true "*) return 1 ;;
    *" claimed=true "*" live=stale "*) return 1 ;;
  esac
  return 0
}

# _prl_fj_cl_require_claim <pr> [kind=reviewing] — 0 this agent holds the
# current generation; 7 it does not; 1 the state is unreadable.
_prl_fj_cl_require_claim() {
  local cs kind="${2:-reviewing}"
  cs="$(_prl_fj_cl_state "$1" "$kind")" \
    || { _prl_fj_cl_err "refusing: claim state for PR #$1 is unreadable (fail closed)"; return 1; }
  # Held = ours AND still live: a claim past its TTL (or the max lifetime a
  # heartbeat cannot extend) is open to takeover, so it is not a hold.
  case " $cs " in
    *" claimed=true "*" live=live "*"mine=true "*) return 0 ;;
  esac
  _prl_fj_cl_err "refusing: this agent does not hold a live $kind claim on PR #$1 ($cs) — run start-review first (exit 7)"
  return 7
}

_prl_fj_cl_label_line() { # <pr>
  _prl_fj_cl_call pr-label-status "$1" 2>/dev/null || echo "label_status unavailable"
}

# Reset the #883 attestation ledger (same contract as the inline start-review:
# a fresh review pass starts with an empty dispatched-reviewer roster; a
# daemon-injected SGE_REVIEW_ATTEST_FILE keeps the DAEMON's own dispatch lines).
_prl_fj_cl_attest_dir_trusted() {
  local d="$1" perm
  # shellcheck disable=SC2174  # the leaf is the ledger directory, as in pr-labels.sh
  mkdir -p -m 700 "$d" 2>/dev/null || true
  [[ -d "$d" && ! -L "$d" && -O "$d" ]] || return 1
  perm=$(stat -c %a "$d" 2>/dev/null || stat -f %Lp "$d" 2>/dev/null) || return 1
  [[ "$perm" =~ ^[0-7]{3,4}$ && "${perm: -2}" == "00" ]] || return 1
}

_prl_fj_cl_attest_reset() { # <pr>
  local dir repo f keep
  dir="${SGE_REVIEW_STATE_DIR:-${TMPDIR:-${TEMP:-/tmp}}}"
  repo="${GH_REPO:-local}"; repo="${repo//[^A-Za-z0-9._-]/_}"
  f="${dir}/sge-review-attest.${repo}.$1"
  if [[ -n "${SGE_REVIEW_ATTEST_FILE:-}" ]]; then
    f="$SGE_REVIEW_ATTEST_FILE"
    _prl_fj_cl_attest_dir_trusted "$(dirname "$f")" \
      || { _prl_fj_cl_err "refusing: the attestation ledger directory cannot be created or trusted ($(dirname "$f")); not starting a review whose #883 attestation would silently never engage"; return 1; }
    keep=""
    [[ -f "$f" ]] && keep=$(grep -E $'^dispatch\t[^\t]*\tdaemon$' "$f" 2>/dev/null || true)
    if [[ -n "$keep" ]]; then
      printf '%s\n' "$keep" > "$f" 2>/dev/null || { _prl_fj_cl_err "refusing: cannot rewrite the attestation ledger $f"; return 1; }
    else
      : > "$f" 2>/dev/null || { _prl_fj_cl_err "refusing: cannot reset the attestation ledger $f"; return 1; }
    fi
  else
    : > "$f" 2>/dev/null || _prl_fj_cl_err "warning: could not reset the attestation ledger $f (no ledger: the #883 backstop will not engage)"
  fi
  return 0
}

_prl_fj_cl_start_review() { # <pr> [--force-claim]
  local pr="$1" force="" handoff="" rc=0 st
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force-claim) force="--force"; shift ;;
      *) _prl_fj_cl_err "unknown option '$1' for start-review"; return 2 ;;
    esac
  done
  # Daemon claim handoff (the twin of GitHub's #1249): the review daemon exports
  # its own claim-owner id in the child's ENV (never prompt text); a live claim
  # recorded for exactly that owner is taken over. Sanitised like the daemon
  # sanitises its own agent id.
  if [ -z "$force" ] && [ -n "${SGE_REVIEW_CLAIM_HANDOFF_OWNER:-}" ]; then
    handoff="$(printf '%s' "$SGE_REVIEW_CLAIM_HANDOFF_OWNER" | tr -c 'A-Za-z0-9._:/@-' '_')"
  fi
  # Labels exist before the claim is taken, so a failure here leaves no claim.
  _prl_fj_cl_ensure_review_labels \
    || { _prl_fj_cl_err "could not ensure the review labels on PR #$pr — not claiming"; return 1; }
  _prl_fj_cl_adapter_claim pr-claim "$pr" reviewing ${force:+"$force"} ${handoff:+--handoff "$handoff"} >/dev/null || rc=$?
  case "$rc" in
    0) : ;;
    3) _prl_fj_cl_err "refusing: PR #$pr is claimed by another review (exit 3)"; return 3 ;;
    *) _prl_fj_cl_err "could not claim PR #$pr"; return 1 ;;
  esac
  # From here a failure must give the claim back, or the PR wedges until the TTL.
  _prl_fj_cl_giveback() { _prl_fj_cl_adapter_claim pr-release-claim "$pr" reviewing >/dev/null 2>&1 \
    || _prl_fj_cl_err "warning: the review claim could not be released (release-review --force clears it)"; }
  _prl_fj_cl_attest_reset "$pr" || { _prl_fj_cl_giveback; return 1; }
  _prl_fj_cl_label add "$pr" pr-reviewing \
    || { _prl_fj_cl_giveback; _prl_fj_cl_err "claim won but the pr-reviewing label could not be added — claim released"; return 1; }
  # Arm the claim: from here the pr-reviewing label's absence means the lane
  # ended (a verdict path took it down), which frees the PR for the next
  # review without waiting out the TTL. Best effort: unarmed, the TTL governs.
  _prl_fj_cl_adapter_claim pr-claim-arm "$pr" reviewing >/dev/null \
    || _prl_fj_cl_err "warning: could not arm the review claim on PR #$pr (it ages out by TTL instead)"
  # Any prior pass is void once a review restarts.
  _prl_fj_cl_label remove "$pr" pr-reviewed \
    || _prl_fj_cl_err "warning: could not remove pr-reviewed from PR #$pr"
  st="$(_prl_fj_cl_label_line "$pr")"
  echo "PR #$pr: review claimed ($st)"
}

_prl_fj_cl_release_review() { # <pr> [--force]
  local pr="$1" force="" st
  shift
  case "${1:-}" in
    '') ;;
    --force) force="--force" ;;
    *) _prl_fj_cl_err "unknown option '$1' for release-review"; return 2 ;;
  esac
  if [ -z "$force" ]; then
    st="$(_prl_fj_cl_state "$pr" reviewing)" \
      || { _prl_fj_cl_err "refusing: claim state for PR #$pr is unreadable (fail closed)"; return 1; }
    if _prl_fj_cl_foreign_live "$st"; then
      _prl_fj_cl_err "refusing: PR #$pr review claim is held by another owner ($st); pass --force to release it anyway"
      return 3
    fi
  fi
  _prl_fj_cl_adapter_claim pr-release-claim "$pr" reviewing ${force:+"$force"} >/dev/null \
    || { _prl_fj_cl_err "could not release the review claim on PR #$pr"; return 1; }
  _prl_fj_cl_label remove "$pr" pr-reviewing \
    || { _prl_fj_cl_err "claim released but the pr-reviewing label could not be removed from PR #$pr"; return 1; }
  echo "PR #$pr: pr-reviewing released"
}

_prl_fj_cl_claim_fix() { # <pr> [--force-claim]
  local pr="$1" force="" rc=0 st
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force-claim) force="--force"; shift ;;
      *) _prl_fj_cl_err "unknown option '$1' for claim-fix"; return 2 ;;
    esac
  done
  # Shared claim protocol: a live REVIEW claim by another agent blocks a fix
  # (the fixing lane is its own mutex, taken below).
  if [ -z "$force" ]; then
    st="$(_prl_fj_cl_state "$pr" reviewing)" \
      || { _prl_fj_cl_err "refusing: review claim state for PR #$pr is unreadable (fail closed)"; return 1; }
    if _prl_fj_cl_foreign_live "$st"; then
      _prl_fj_cl_err "refusing: PR #$pr has a live review claim ($st) — another agent is working it (exit 3)"
      return 3
    fi
  fi
  _prl_fj_cl_ensure_label pr-fixing FBCA04 "CI-fix in progress (SGE pr-fix)" \
    || { _prl_fj_cl_err "could not ensure the pr-fixing label on PR #$pr — not claiming"; return 1; }
  _prl_fj_cl_adapter_claim pr-claim "$pr" fixing ${force:+"$force"} >/dev/null || rc=$?
  case "$rc" in
    0) : ;;
    3) _prl_fj_cl_err "refusing: PR #$pr already has a fix claim — another fix pass is in flight (exit 3; --force-claim takes over deliberately)"; return 3 ;;
    *) _prl_fj_cl_err "could not claim the fix lane on PR #$pr"; return 1 ;;
  esac
  if ! _prl_fj_cl_label add "$pr" pr-fixing; then
    if _prl_fj_cl_adapter_claim pr-release-claim "$pr" fixing >/dev/null 2>&1; then
      _prl_fj_cl_err "fix claim won but the pr-fixing label could not be added — claim released"
    else
      _prl_fj_cl_err "fix claim won but the pr-fixing label could not be added, and the claim could not be released (release-fix --force clears it)"
    fi
    return 1
  fi
  _prl_fj_cl_adapter_claim pr-claim-arm "$pr" fixing >/dev/null \
    || _prl_fj_cl_err "warning: could not arm the fix claim on PR #$pr (it ages out by TTL instead)"
  echo "PR #$pr: fix claimed (fixing=true)"
}

_prl_fj_cl_release_fix() { # <pr> [--force]
  local pr="$1" force="" st
  shift
  case "${1:-}" in
    '') ;;
    --force) force="--force" ;;
    *) _prl_fj_cl_err "unknown option '$1' for release-fix"; return 2 ;;
  esac
  # Binding termination contract (#1174): called on every exit, including a
  # crash trap by an agent that LOST the lane. Never strip a live owner's lane.
  if [ -z "$force" ]; then
    st="$(_prl_fj_cl_state "$pr" fixing)" \
      || { _prl_fj_cl_err "refusing: fix claim state for PR #$pr is unreadable (fail closed)"; return 1; }
    if _prl_fj_cl_foreign_live "$st"; then
      _prl_fj_cl_err "refusing: PR #$pr fix claim is held by another owner ($st); pass --force to release it anyway"
      return 3
    fi
  fi
  _prl_fj_cl_adapter_claim pr-release-claim "$pr" fixing ${force:+"$force"} >/dev/null \
    || { _prl_fj_cl_err "could not release the fix claim on PR #$pr"; return 1; }
  _prl_fj_cl_label remove "$pr" pr-fixing \
    || { _prl_fj_cl_err "claim released but the pr-fixing label could not be removed from PR #$pr"; return 1; }
  echo "PR #$pr: pr-fixing released"
}

_prl_fj_cl_heartbeat() { # <pr>
  local pr="$1" rc=0
  _prl_fj_cl_adapter_claim pr-claim-heartbeat "$pr" reviewing >/dev/null || rc=$?
  case "$rc" in
    0) echo "PR #$pr: review claim heartbeat recorded" ;;
    7) _prl_fj_cl_err "refusing: this agent does not hold PR #$pr's review claim — no heartbeat (exit 7)"; return 7 ;;
    # Not advisory here: an unreadable claim or a failed post is non-zero, so a
    # review that must outlive the TTL learns its claim may lapse.
    *) _prl_fj_cl_err "could not record the claim heartbeat on PR #$pr (fail closed)"; return 1 ;;
  esac
}

_prl_fj_cl_status() { # <pr>
  local out
  out="$(_prl_fj_cl_call pr-label-status "$1")" \
    || { _prl_fj_cl_err "could not read label state for PR #$1 (fail closed)"; return 1; }
  case "$out" in
    "reviewing="*" reviewed="*) printf '%s\n' "$out" ;;
    *) _prl_fj_cl_err "unrecognised label state for PR #$1 ('$out') — refusing"; return 1 ;;
  esac
}
