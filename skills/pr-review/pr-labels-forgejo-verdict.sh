#!/usr/bin/env bash
# pr-labels-forgejo-verdict.sh — the `pass`, `fail` and `shadow-pass` terminals of
# the pr-labels.sh review gate on Forgejo/Gitea (SPEC-094 s2.2a, slice S2 #3069
# of the #3029 port). SOURCED by pr-labels-forgejo.d/verdict.sh ONLY when the
# origin classifies as `forgejo`; never executed, never loaded on GitHub or
# Azure Repos. Mirrors pr-labels-azdo.sh's shape.
#
# Model (differs from the pre-port inline path #1239 on purpose):
#   verdict   -> a commit STATUS on the reviewed head (context `sge/pr-review`,
#                success for pass / failure for fail; `sge/pr-review-shadow` for
#                shadow-pass), written by the adapter verb `pr-verdict`. A status
#                is bound to the commit it names, so it cannot describe another
#                head, and it works when the agent is also the PR author (Gitea
#                refuses a self-approval review).
#   CI gate   -> adapter `pr-ci-state`: ONLY `success` passes. `none`, `pending`,
#                `unknown` and an unreadable state refuse (the inline path let
#                `none` through).
#   threads   -> adapter `pr-threads`: the thread gate is real here (the inline
#                path skipped it on Forgejo). An unprovable state refuses.
#   claim     -> adapter `pr-claim-status <origin> <pr> reviewing` (the claim
#                slice S1 #3068): `claimed=true ... mine=true` or exit 7.
#   merge     -> `_prl_fj_merge pass <pr> --expect-head <full-sha>` (slice S4
#                #3071), called only AFTER the verdict is recorded.
#
# Exit codes are pr-labels.sh's: 2 usage, 4 advisory, 5 attestation, 6 declared
# follow-up with no issue, 7 claim not held, 8 hold, 9 shadow, 1 any other
# refusal. Every adapter or API error is non-zero, never a pass. No `gh` call.
#
# NOTE: pr-labels.sh calls this through `cmd || rc=$?`, which disables `set -e`
# for the whole body, so every command below checks its own status.

_PRL_FJ_VD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_prl_fj_vd_err() { printf 'pr-labels (forgejo): %s\n' "$*" >&2; }

# Globals the shared follow-up scanner (followups-gate.sh) reads from its caller.
_prl_fj_vd_setup() {
  _PRL_HOST=forgejo
  _PRL_SCRIPT_DIR="${_PRL_SCRIPT_DIR:-$_PRL_FJ_VD_DIR}"
  _PRL_ADAPTER="${_PRL_ADAPTER:-$_PRL_FJ_VD_DIR/../../scripts/forgejo-adapter.sh}"
  if [ -z "${_PRL_ORIGIN:-}" ]; then
    _PRL_ORIGIN="${FORGEJO_ORIGIN:-}"
    [ -n "$_PRL_ORIGIN" ] || _PRL_ORIGIN="$(git remote get-url origin 2>/dev/null)" || _PRL_ORIGIN=""
  fi
  [ -f "$_PRL_ADAPTER" ] || { _prl_fj_vd_err "refusing: forgejo-adapter.sh not found ($_PRL_ADAPTER)"; return 1; }
  [ -n "$_PRL_ORIGIN" ] || { _prl_fj_vd_err "refusing: no origin URL (set FORGEJO_ORIGIN or run inside the checkout)"; return 1; }
  command -v jq >/dev/null 2>&1 || { _prl_fj_vd_err "refusing: jq is required"; return 1; }
  # This module IS the review lane's explicit write path (the forgejo block in
  # pr-labels.sh makes the same decision, but runs after the dispatch).
  export FORGEJO_ADAPTER_ALLOW_WRITE=1
}

# _prl_fj_vd_call <verb> <args...> -> adapter <verb> <origin> <args...>
_prl_fj_vd_call() {
  local verb="$1"
  shift
  bash "$_PRL_ADAPTER" "$verb" "$_PRL_ORIGIN" "$@"
}

# _prl_fj_vd_read_pr -> sets _VD_HEAD (full lowercase sha) _VD_DRAFT _VD_STATE
# _VD_LABELS (one per line). Non-zero on anything unreadable or malformed: the
# head, the state and the label list must all be provable.
_prl_fj_vd_read_pr() {
  local pj
  pj="$(_prl_fj_vd_call get-pr "$PR" 2>/dev/null)" || return 1
  printf '%s' "$pj" | jq -e 'type=="object" and (.labels|type=="array")' >/dev/null 2>&1 || return 1
  _VD_HEAD="$(printf '%s' "$pj" | jq -r '.head.sha // empty' | tr -d '\r' | tr '[:upper:]' '[:lower:]')" || return 1
  [[ "$_VD_HEAD" =~ ^[0-9a-f]{40}$ ]] || return 1
  _VD_STATE="$(printf '%s' "$pj" | jq -r '.state // empty' | tr -d '\r')" || return 1
  _VD_DRAFT="$(printf '%s' "$pj" | jq -r 'if .draft == true then "true" else "false" end')" || return 1
  _VD_LABELS="$(printf '%s' "$pj" | jq -r '.labels[].name' | tr -d '\r')" || return 1
}

_prl_fj_vd_has_label() { printf '%s\n' "$_VD_LABELS" | grep -qxF -- "$1"; }

# _prl_fj_vd_pin_matches <pin> <full-head> -> 0 when the pin names the head.
# Same rule as the GitHub path: >= 7 hex chars, prefix match, case-insensitive.
_prl_fj_vd_pin_matches() {
  local pin norm
  norm="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ ${#norm} -ge 7 && "$norm" =~ ^[0-9a-f]+$ ]] || return 1
  [[ "$2" == "$norm"* ]]
}

# _prl_fj_vd_require_claim -> 0 this agent holds the reviewing claim; 7 it does
# not; 1 the claim state is unreadable (fail closed); 99 the claim slice has not
# landed in the adapter (the caller falls back to the transitional path).
_prl_fj_vd_require_claim() {
  local cs errf rc=0
  errf="$(mktemp "${TMPDIR:-/tmp}/sge-fj-claim.XXXXXX")" || return 1
  cs="$(_prl_fj_vd_call pr-claim-status "$PR" reviewing 2>"$errf")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Only the adapter's own unknown-verb refusal (exit 2 and its message)
    # means the claim slice is not in this adapter; any other failure refuses.
    if [ "$rc" -eq 2 ] && grep -q "unknown command 'pr-claim-status'" "$errf" 2>/dev/null; then
      rm -f "$errf"; return 99
    fi
    rm -f "$errf"
    _prl_fj_vd_err "refusing: claim state for PR #$PR is unreadable (fail closed)"
    return 1
  fi
  rm -f "$errf"
  case " $cs " in
    *" claimed=true "*" mine=true "*) return 0 ;;
  esac
  _prl_fj_vd_err "refusing: this agent does not hold PR #$PR's review claim ($cs) — run start-review first (exit 7)"
  return 7
}

_prl_fj_vd_release_claim() {
  _prl_fj_vd_call pr-release-claim "$PR" reviewing >/dev/null 2>&1 \
    || _prl_fj_vd_err "warning: the review claim could not be released (release-review --force clears it)"
}

_prl_fj_vd_status() { _prl_fj_vd_call pr-label-status "$PR"; }

_prl_fj_vd_ensure_labels() { # <name> <color> <description> ...
  local n c d
  while [ "$#" -ge 3 ]; do
    n="$1"; c="$2"; d="$3"; shift 3
    _prl_fj_vd_call pr-ensure-label "$n" "$c" "$d" >/dev/null || return 1
  done
}

# The mechanical subagent-execution gate (#883) and the @security-auditor model
# floor (#3035), ported from pr-labels.sh `pass` so taking over from the inline
# path does not drop a control. 0 ok, 5 refuse.
_prl_fj_vd_attest_gate() {
  [[ "${SGE_REVIEW_ATTEST_SKIP:-}" != "1" ]] || return 0
  local dir repo file pending=0 secm
  dir="${SGE_REVIEW_STATE_DIR:-${TMPDIR:-${TEMP:-/tmp}}}"
  repo="${GH_REPO:-local}"
  repo="${repo//[^A-Za-z0-9._-]/_}"
  file="${dir}/sge-review-attest.${repo}.${PR}"
  [[ -n "${SGE_REVIEW_ATTEST_FILE:-}" ]] && file="$SGE_REVIEW_ATTEST_FILE"
  if [[ -n "${SGE_REVIEW_ATTEST_FILE:-}" && ! -f "$file" ]]; then
    _prl_fj_vd_err "refusing: the daemon-injected attestation ledger $file is missing (issue #883 / SPEC-090) -- fail closed"
    return 5
  fi
  if [[ -f "$file" ]]; then
    if pending=$(awk -F'\t' -v inj="${SGE_REVIEW_ATTEST_FILE:+1}" -v nonce="${SGE_REVIEW_ATTEST_NONCE:-}" '
          $1=="dispatch" { pend[$2]=1 }
          $1=="attest"   { if (inj != "1" || (nonce != "" && NF == 3 && $3 == nonce)) delete pend[$2] }
          END { n=0; for (a in pend) n++; print n }
        ' "$file"); then
      [[ "$pending" =~ ^[0-9]+$ ]] || pending=1
    else
      pending=1
    fi
  fi
  if [[ "$pending" =~ ^[0-9]+$ && "$pending" -gt 0 ]]; then
    _prl_fj_vd_err "refusing: $pending dispatched reviewer(s) never cleared rl_reviewer_ran (issue #883) — their (non-)result must not be trusted as a clean pass"
    _prl_fj_vd_err "Re-run each unattested Layer 2/3 agent (or do its check inline) and clear it via rl_reviewer_attest before 'pass'. Ledger: $file"
    return 5
  fi
  if [[ -f "$file" ]] \
     && awk -F'\t' '$1=="dispatch" && $2=="@security-auditor" && NF==2 {f=1} END{exit !f}' "$file"; then
    secm=$(awk -F'\t' '$1=="model" && $2=="@security-auditor" && NF==3 {m=$3} END{print m}' "$file")
    if [[ -z "$secm" ]] || ! jq -e --arg m "$secm" '(.classes.deep // []) | index($m) != null' "$_PRL_FJ_VD_DIR/model-roles.json" >/dev/null 2>&1; then
      _prl_fj_vd_err "refusing: @security-auditor was dispatched without a recorded deep-class model (#3035; got '${secm:-none}') -- the security lane must never run below the deep class"
      return 5
    fi
  fi
  return 0
}

# _prl_fj_vd_parse <cmd> <args...> -> sets _VD_EXPECT _VD_VFILE _VD_SKIP_THREADS
# _VD_SKIP_CLAIM _VD_SKIP_FOLLOWUP _VD_AUTO_MERGE. Return 2 on a usage error.
_prl_fj_vd_parse() {
  local cmd="$1"
  shift
  _VD_EXPECT=""; _VD_VFILE=""; _VD_SKIP_THREADS=false; _VD_SKIP_CLAIM=false
  _VD_SKIP_FOLLOWUP=false; _VD_AUTO_MERGE=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expect-head)
        [ "$#" -ge 2 ] || { _prl_fj_vd_err "--expect-head needs a SHA"; return 2; }
        _VD_EXPECT="$2"; shift 2 ;;
      --verdict-file)
        # Accepted for adapter parity (azdo posts it as the verdict body) and
        # validated, but intentionally NOT used: Forgejo records the verdict as
        # a commit status bound to the head, which carries no body. The review
        # text is posted by the review lane as a comment.
        [ "$#" -ge 2 ] || { _prl_fj_vd_err "--verdict-file needs a path"; return 2; }
        _VD_VFILE="$2"; shift 2 ;;
      --skip-claim-check)
        _VD_SKIP_CLAIM=true
        _prl_fj_vd_err "warning: --skip-claim-check set — claim-check guard disabled for PR #$PR; promoting a PR that never claimed the gate (issue #981)"
        shift ;;
      --skip-thread-check)
        [ "$cmd" = pass ] || { _prl_fj_vd_err "unknown option '$1' for $cmd"; return 2; }
        _VD_SKIP_THREADS=true
        _prl_fj_vd_err "warning: --skip-thread-check set — thread-resolution gate disabled for PR #$PR"
        shift ;;
      --skip-followup-check)
        [ "$cmd" = pass ] || { _prl_fj_vd_err "unknown option '$1' for $cmd"; return 2; }
        _VD_SKIP_FOLLOWUP=true
        _prl_fj_vd_err "warning: --skip-followup-check set — follow-up preservation gate disabled for PR #$PR (issue #859)"
        shift ;;
      --auto-merge)
        [ "$cmd" = pass ] || { _prl_fj_vd_err "--auto-merge only applies to pass"; return 2; }
        _VD_AUTO_MERGE=true; shift ;;
      --thread-cache|--thread-cache-head)
        # GitHub's cached-walk shortcut. Forgejo always walks live: accepted and
        # ignored so a caller passing the pair is not refused.
        [ "$cmd" = pass ] || { _prl_fj_vd_err "unknown option '$1' for $cmd"; return 2; }
        [ "$#" -ge 2 ] || { _prl_fj_vd_err "$1 needs a value"; return 2; }
        shift 2 ;;
      *) _prl_fj_vd_err "unknown option '$1' for $cmd"; return 2 ;;
    esac
  done
  if [ -n "$_VD_VFILE" ] && [ ! -r "$_VD_VFILE" ]; then
    _prl_fj_vd_err "--verdict-file '$_VD_VFILE' not found"; return 2
  fi
  return 0
}

# _prl_fj_vd_claim_gate <cmd> -> 0 proceed, 7/1 refuse, 99 fall back (see caller)
_prl_fj_vd_claim_gate() {
  [ "$_VD_SKIP_CLAIM" = true ] && return 0
  local rc=0
  _prl_fj_vd_require_claim || rc=$?
  return "$rc"
}

# _prl_fj_vd_record <pass|fail|shadow> <full-head> -> 0 recorded; 1 refused
_prl_fj_vd_record() {
  local rc=0
  _prl_fj_vd_call pr-verdict "$PR" "$1" "$2" >/dev/null || rc=$?
  case "$rc" in
    0) return 0 ;;
    6) _prl_fj_vd_err "refusing: PR #$PR head moved while the verdict was being recorded (reviewed $2) — re-review the new head"; return 1 ;;
    *) _prl_fj_vd_err "could not record the $1 verdict on PR #$PR at ${2:0:9} (fail closed)"; return 1 ;;
  esac
}

# _prl_fj_vd_unwind <pass|shadow> <full-head> — a verdict was recorded and the
# gate then failed to open (or was retracted): the recorded SUCCESS must not
# outlive it, or a consumer of the status would still read the PR as approved.
# The status is withdrawn first (it is the signal consumers read), then the
# label. A failed withdrawal is reported loudly; it never reads as a pass.
_prl_fj_vd_unwind() {
  local kind=withdraw
  [ "$1" = shadow ] && kind=withdraw-shadow
  _prl_fj_vd_call pr-verdict "$PR" "$kind" "$2" >/dev/null 2>&1 \
    || _prl_fj_vd_err "warning: could not withdraw the recorded $1 status on ${2:0:9} of PR #$PR — post a failing sge/pr-review status by hand"
  if [ "$1" = pass ]; then
    _prl_fj_vd_call pr-remove-label "$PR" pr-reviewed >/dev/null 2>&1 \
      || _prl_fj_vd_err "warning: could not retract pr-reviewed from PR #$PR — remove it manually"
  fi
}

_prl_fj_vd_arm_merge() { # <full-head>
  local mrc=0
  if ! declare -F _prl_fj_merge >/dev/null 2>&1; then
    _prl_fj_vd_err "the pass is recorded but the merge module is missing — auto-merge NOT armed on PR #$PR (merge manually)"
    return 1
  fi
  _PRL_FJ_STUB_HIT=0
  _prl_fj_merge pass "$PR" --expect-head "$1" || mrc=$?
  if [ "$mrc" -eq 75 ] && [ "${_PRL_FJ_STUB_HIT:-0}" = 1 ]; then
    # The merge slice has not landed. The pass stands; the marker must NOT reach
    # pr-labels.sh, or it would re-run the whole inline pass after this one.
    _PRL_FJ_STUB_HIT=0
    echo "PR #$PR: auto-merge NOT armed — not available on forgejo yet (merge slice not landed); leaving the merge to be done manually"
    _prl_fj_vd_err "auto-merge was requested but NOT armed on PR #$PR (merge slice not landed)"
    return 0
  fi
  _PRL_FJ_STUB_HIT=0
  if [ "$mrc" -ne 0 ]; then
    _prl_fj_vd_err "the pass is recorded but auto-merge could not be armed on PR #$PR (exit $mrc; merge manually)"
    return 1
  fi
  return 0
}

_prl_fj_vd_pass() {
  local head rc unresolved cnt ci st
  _prl_fj_vd_parse pass "$@" || return $?
  if [[ "${SGE_REVIEW_ADVISORY:-}" == "1" ]]; then
    _prl_fj_vd_err "refusing: SGE_REVIEW_ADVISORY=1 — advisory (review-only) dispatch: 'pass' cannot move the pr-reviewed gate or arm auto-merge (issue #754)"
    return 4
  fi
  if [[ "${SGE_REVIEW_SHADOW:-}" == "1" ]]; then
    _prl_fj_vd_err "refusing: SGE_REVIEW_SHADOW=1 — shadow-mode dispatch: 'pass' must never apply pr-reviewed or arm auto-merge; use 'shadow-pass' (issue #2651, #2653)"
    return 9
  fi
  rc=0; _prl_fj_vd_attest_gate || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # The claim gate runs first: while the claim slice has not landed in the
  # adapter the whole subcommand falls through to the pre-existing inline path
  # (no side effect has happened yet), and once it has, an agent that does not
  # hold the claim is refused (7) before anything else is read.
  rc=0; _prl_fj_vd_claim_gate || rc=$?
  if [ "$rc" -eq 99 ]; then
    _prl_fj_not_implemented verdict "pass (claim-read interface of slice 'claim' not landed)"; return
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  if [ -z "$_VD_EXPECT" ]; then
    _prl_fj_vd_err "refusing: pass needs --expect-head on Forgejo (the verdict is bound to the head judged)"
    return 1
  fi
  _prl_fj_vd_read_pr || { _prl_fj_vd_err "refusing: PR #$PR could not be read from the Forgejo adapter (fail closed)"; return 1; }
  head="$_VD_HEAD"
  [ "$_VD_STATE" = open ] || { _prl_fj_vd_err "refusing: PR #$PR is not open (state '$_VD_STATE')"; return 1; }
  [ "$_VD_DRAFT" != true ] || { _prl_fj_vd_err "refusing: PR #$PR is a DRAFT — drafts never receive pr-reviewed or auto-merge"; return 1; }
  if _prl_fj_vd_has_label hold; then
    _prl_fj_vd_err "refusing: PR #$PR carries the 'hold' label — the gate cannot open while a human sign-off is pending (issue #1393)"
    return 8
  fi
  if ! _prl_fj_vd_pin_matches "$_VD_EXPECT" "$head"; then
    _prl_fj_vd_err "refusing: PR #$PR head moved since review (reviewed $_VD_EXPECT, now $head) — run a delta re-review, then pass with the new head"
    return 1
  fi
  # CI gate: only a definite green passes.
  ci="$(_prl_fj_vd_call pr-ci-state "$head" 2>/dev/null)" || ci="unreadable"
  if [ "$ci" != success ]; then
    _prl_fj_vd_err "refusing: PR #$PR CI at ${head:0:9} is '$ci' — only a definite 'success' passes (issue #885)"
    return 1
  fi
  if [ "$_VD_SKIP_THREADS" != true ]; then
    unresolved="$(_prl_fj_vd_call pr-threads "$PR" 2>/dev/null)" \
      || { _prl_fj_vd_err "refusing: the review-thread state of PR #$PR is unreadable — thread gate fails closed (issue #717)"; return 1; }
    cnt="$(printf '%s' "$unresolved" | jq -e 'if type=="array" then length else error("shape") end' 2>/dev/null | tr -d '\r')" \
      || { _prl_fj_vd_err "refusing: the review-thread state of PR #$PR is unparsable — thread gate fails closed (issue #717)"; return 1; }
    [[ "$cnt" =~ ^[0-9]+$ ]] || { _prl_fj_vd_err "refusing: the review-thread count of PR #$PR is not a number — thread gate fails closed"; return 1; }
    if [ "$cnt" -gt 0 ]; then
      _prl_fj_vd_err "refusing: PR #$PR has $cnt unresolved review thread(s)"
      printf '%s' "$unresolved" | jq -r '.[] | "  [\(.id)] \(.path) \(.author): \(.body | .[0:100] | gsub("\n";" "))"' >&2
      return 1
    fi
  fi
  if [ "$_VD_SKIP_FOLLOWUP" != true ]; then
    # shellcheck source=skills/pr-review/followups-gate.sh
    . "$_PRL_SCRIPT_DIR/followups-gate.sh" || { _prl_fj_vd_err "refusing: followups-gate.sh could not be loaded"; return 6; }
    assert_followups_preserved || return 6
  fi
  # Late re-read, once every slow gate has run: a push, a hold or a close landing
  # in that window must not ride the pass (TOCTOU, issue #1393).
  _prl_fj_vd_read_pr || { _prl_fj_vd_err "refusing: PR #$PR could not be re-read before the verdict (fail closed)"; return 1; }
  [ "$_VD_HEAD" = "$head" ] || { _prl_fj_vd_err "refusing: PR #$PR head moved during the gates (judged $head, now $_VD_HEAD) — re-review the new head"; return 1; }
  [ "$_VD_STATE" = open ] && [ "$_VD_DRAFT" != true ] \
    || { _prl_fj_vd_err "refusing: PR #$PR is no longer an open, ready PR"; return 1; }
  if _prl_fj_vd_has_label hold; then
    _prl_fj_vd_err "refusing: PR #$PR — the 'hold' label appeared during pass; the gate cannot open (issue #1393)"
    return 8
  fi
  _prl_fj_vd_ensure_labels pr-reviewing FBCA04 "PR review in progress (SGE)" \
    pr-reviewed 0E8A16 "Reviewed via SGE PR-review gate" \
    changes-requested D93F0B "Review failed — findings need addressing (SGE)" \
    || { _prl_fj_vd_err "could not ensure the gate labels on PR #$PR (fail closed)"; return 1; }
  _prl_fj_vd_record pass "$head" || return 1
  _prl_fj_vd_call pr-add-label "$PR" pr-reviewed >/dev/null \
    || { _prl_fj_vd_unwind pass "$head"; _prl_fj_vd_err "pr-reviewed could not be added to PR #$PR — the pass status was withdrawn"; return 1; }
  _prl_fj_vd_call pr-remove-label "$PR" pr-reviewing >/dev/null || _prl_fj_vd_err "warning: failed to remove pr-reviewing from PR #$PR"
  _prl_fj_vd_call pr-remove-label "$PR" changes-requested >/dev/null || _prl_fj_vd_err "warning: failed to remove changes-requested from PR #$PR"
  _prl_fj_vd_call pr-remove-label "$PR" excluded-reviewer >/dev/null 2>&1 || true
  st="$(_prl_fj_vd_status)" || { _prl_fj_vd_unwind pass "$head"; _prl_fj_vd_err "error: could not read label state for PR #$PR after the swap — the pass status was withdrawn"; return 1; }
  if [ "$st" != "reviewing=false reviewed=true" ]; then
    _prl_fj_vd_unwind pass "$head"
    _prl_fj_vd_err "error: label swap did not take on PR #$PR ($st) — the pass status was withdrawn"
    return 1
  fi
  # A push between the late re-read and the label write must not leave
  # pr-reviewed on an unreviewed head: re-read once more and retract.
  if ! _prl_fj_vd_read_pr || [ "$_VD_HEAD" != "$head" ] || [ "$_VD_STATE" != open ] \
     || [ "$_VD_DRAFT" = true ] || _prl_fj_vd_has_label hold; then
    _prl_fj_vd_unwind pass "$head"
    _prl_fj_vd_err "refusing: PR #$PR head moved (or could not be re-read) as the gate opened (judged $head), or it was closed, drafted or held — pr-reviewed retracted and the pass status withdrawn"
    return 1
  fi
  _prl_fj_vd_release_claim
  echo "PR #$PR: gate passed ($st)"
  if [ "$_VD_AUTO_MERGE" = true ]; then
    _prl_fj_vd_arm_merge "$head" || return 1
  fi
  return 0
}

_prl_fj_vd_fail() {
  local head rc st
  _prl_fj_vd_parse fail "$@" || return $?
  if [[ "${SGE_REVIEW_ADVISORY:-}" == "1" ]]; then
    _prl_fj_vd_err "refusing: SGE_REVIEW_ADVISORY=1 — advisory (review-only) dispatch: 'fail' cannot move the changes-requested gate (issue #754, #2238)"
    return 4
  fi
  rc=0; _prl_fj_vd_claim_gate || rc=$?
  if [ "$rc" -eq 99 ]; then
    _prl_fj_not_implemented verdict "fail (claim-read interface of slice 'claim' not landed)"; return
  fi
  # Close the gate FIRST and unconditionally: removing pr-reviewed is always
  # safe, and no later refusal (claim not held, head moved, unreadable PR) may
  # leave a stale pass standing. A failed removal never reads as a closed gate.
  _prl_fj_vd_call pr-remove-label "$PR" pr-reviewed >/dev/null \
    || { _prl_fj_vd_err "error: could not remove pr-reviewed from PR #$PR — the gate is still open (retry 'fail $PR')"; return 1; }
  st="$(_prl_fj_vd_status)" || { _prl_fj_vd_err "error: could not re-verify pr-reviewed removal on PR #$PR"; return 1; }
  case "$st" in
    *"reviewed=true"*) _prl_fj_vd_err "error: pr-reviewed is still present on PR #$PR after removal — gate still open"; return 1 ;;
  esac
  [ "$rc" -eq 0 ] || return "$rc"
  if [ -z "$_VD_EXPECT" ]; then
    _prl_fj_vd_err "refusing: fail needs --expect-head on Forgejo (the verdict is bound to the head judged); pr-reviewed was removed"
    return 1
  fi
  _prl_fj_vd_read_pr || { _prl_fj_vd_err "refusing: PR #$PR could not be read from the Forgejo adapter (fail closed); pr-reviewed was removed"; return 1; }
  head="$_VD_HEAD"
  if ! _prl_fj_vd_pin_matches "$_VD_EXPECT" "$head"; then
    _prl_fj_vd_err "refusing: PR #$PR head moved since review (reviewed $_VD_EXPECT, now $head) — re-review the new head; pr-reviewed was removed"
    return 1
  fi
  _prl_fj_vd_ensure_labels pr-reviewing FBCA04 "PR review in progress (SGE)" \
    changes-requested D93F0B "Review failed — findings need addressing (SGE)" \
    || { _prl_fj_vd_err "could not ensure the gate labels on PR #$PR (fail closed)"; return 1; }
  _prl_fj_vd_call pr-remove-label "$PR" pr-reviewing >/dev/null || _prl_fj_vd_err "warning: failed to remove pr-reviewing from PR #$PR"
  _prl_fj_vd_record fail "$head" || return 1
  if ! _prl_fj_vd_call pr-add-label "$PR" changes-requested >/dev/null; then
    _prl_fj_vd_err "warning: failed to add changes-requested to PR #$PR (the failing status is recorded)"
  fi
  _prl_fj_vd_release_claim
  st="$(_prl_fj_vd_status)" || st="(label_status unavailable)"
  echo "PR #$PR: gate closed — findings on the PR carry the state ($st)"
}

_prl_fj_vd_shadow_pass() {
  local head rc pre mid st
  _prl_fj_vd_parse shadow-pass "$@" || return $?
  rc=0; _prl_fj_vd_claim_gate || rc=$?
  if [ "$rc" -eq 99 ]; then
    _prl_fj_not_implemented verdict "shadow-pass (claim-read interface of slice 'claim' not landed)"; return
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  _prl_fj_vd_read_pr || { _prl_fj_vd_err "refusing: PR #$PR could not be read from the Forgejo adapter (fail closed)"; return 1; }
  head="$_VD_HEAD"
  if [ -n "$_VD_EXPECT" ] && ! _prl_fj_vd_pin_matches "$_VD_EXPECT" "$head"; then
    _prl_fj_vd_err "refusing: PR #$PR head moved since review (reviewed $_VD_EXPECT, now $head) — re-review the new head"
    return 1
  fi
  # Never touches pr-reviewed and never merges. When a real review already gated
  # this PR, agent-reviewed would be false: skip the add (#2653).
  pre="$(_prl_fj_vd_status)" || pre="unreadable"
  if [[ "$pre" == *"reviewed=true"* ]]; then
    _prl_fj_vd_call pr-remove-label "$PR" pr-reviewing >/dev/null || { _prl_fj_vd_err "could not release pr-reviewing on PR #$PR"; return 1; }
    _prl_fj_vd_call pr-remove-label "$PR" changes-requested >/dev/null || { _prl_fj_vd_err "could not clear changes-requested on PR #$PR"; return 1; }
    _prl_fj_vd_release_claim
    echo "PR #$PR: shadow-mode review passed — 'pr-reviewed' already present (a real review already gated this PR); 'agent-reviewed' NOT applied (#2653)"
    return 0
  fi
  [ "$pre" != unreadable ] || { _prl_fj_vd_err "refusing: label state of PR #$PR is unreadable (fail closed)"; return 1; }
  _prl_fj_vd_ensure_labels agent-reviewed 2EC4B6 "Reviewed by an autonomous agent (PR Warden) — unreviewed by a human yet" \
    || { _prl_fj_vd_err "could not ensure the agent-reviewed label on PR #$PR"; return 1; }
  _prl_fj_vd_record shadow "$head" || return 1
  _prl_fj_vd_call pr-remove-label "$PR" pr-reviewing >/dev/null || { _prl_fj_vd_unwind shadow "$head"; _prl_fj_vd_err "could not release pr-reviewing on PR #$PR"; return 1; }
  _prl_fj_vd_call pr-remove-label "$PR" changes-requested >/dev/null || { _prl_fj_vd_unwind shadow "$head"; _prl_fj_vd_err "could not clear changes-requested on PR #$PR"; return 1; }
  # Re-read right before the one write this guard gates (TOCTOU, #2653); an
  # unreadable state never adds the label.
  mid="$(_prl_fj_vd_status)" || mid="unreadable"
  if [[ "$mid" == *"reviewed=true"* ]]; then
    _prl_fj_vd_release_claim
    echo "PR #$PR: shadow-mode review passed — 'pr-reviewed' landed concurrently; 'agent-reviewed' NOT applied (issue #2653 TOCTOU guard)"
    return 0
  fi
  [ "$mid" != unreadable ] || { _prl_fj_vd_unwind shadow "$head"; _prl_fj_vd_err "refusing: label state of PR #$PR is unreadable (fail closed)"; return 1; }
  _prl_fj_vd_call pr-add-label "$PR" agent-reviewed >/dev/null \
    || { _prl_fj_vd_unwind shadow "$head"; _prl_fj_vd_err "could not add agent-reviewed to PR #$PR"; return 1; }
  _prl_fj_vd_release_claim
  st="$(_prl_fj_vd_status)" || st="(label_status unavailable)"
  echo "PR #$PR: shadow-mode review passed — 'agent-reviewed' applied ($st); 'pr-reviewed' NEVER applied and 'pass' was never called (issue #2651)"
}

# _prl_fj_vd_dispatch <pass|fail|shadow-pass> <pr> [args...]
_prl_fj_vd_dispatch() {
  local cmd="$1"
  PR="$2"
  REVIEWED="pr-reviewed"
  shift 2
  _prl_fj_vd_setup || return 1
  case "$cmd" in
    pass)        _prl_fj_vd_pass "$@" ;;
    fail)        _prl_fj_vd_fail "$@" ;;
    shadow-pass) _prl_fj_vd_shadow_pass "$@" ;;
    *) _prl_fj_vd_err "'$cmd' is not a verdict terminal"; return 2 ;;
  esac
}
