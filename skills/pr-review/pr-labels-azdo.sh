#!/usr/bin/env bash
# pr-labels-azdo.sh — the pr-labels.sh gate state machine on Azure Repos
# (SPEC-110 S4, issue #2985). Sourced by pr-labels.sh ONLY when the origin
# classifies as `azdo`; the GitHub/Forgejo paths never load it.
#
# Mapping:
#   labels          -> PR tags (pr-reviewing, pr-reviewed, changes-requested, hold)
#   review claim    -> azdo-adapter.sh pr-claim: a git ref created by compare-
#                      and-swap, so two racers resolve to exactly one winner
#                      (PR tags have no revision guard; the tag is display only)
#   verdict         -> azdo-adapter.sh pr-verdict: a closed thread + reviewer
#                      vote (pass 10, fail -5) bound to the --expect-head commit
#   CI gate         -> azdo-adapter.sh pr-ci: the DP5 tri-state; ONLY `green`
#                      passes (indeterminate is never green, DR3/DR8)
#
# Supported subcommands: start-review, release-review, status, pass, fail,
# claim-fix, release-fix, heartbeat, held, apply-hold, release-hold,
# shadow-pass, sync-check, stale (#2989). Every other pr-labels.sh subcommand
# REFUSES on Azure Repos (exit 2) rather than falling through to `gh` against a
# repo gh cannot see.
#
#   start-review <pr> [--force-claim]                         exit 3 = claim lost
#       SGE_REVIEW_CLAIM_HANDOFF_OWNER=<id> (set by the review daemon): a live
#       claim recorded for exactly <id> is the dispatcher's own and is taken over.
#   release-review <pr> [--force]
#   status <pr>                     "reviewing=<b> reviewed=<b>" + claim line
#   pass <pr> --expect-head <sha> [--verdict-file <f>] [--skip-thread-check] [--skip-claim-check] [--skip-followup-check]
#       refuses: advisory (4) / shadow (9) dispatch, hold tag (8), this agent
#       not holding the current claim generation (7; pass AND fail), draft,
#       head moved, CI not green, unresolved threads, a declared follow-up with
#       no issue reference (6; the same scanner as GitHub). --auto-merge (pass
#       only) arms Azure DevOps auto-complete AFTER the verdict is recorded and
#       only when the target branch has a blocking minimum-reviewers policy with
#       resetOnSourcePush, creatorVoteCounts=false and blockLastPusherVote=true (ADO does not cancel auto-complete on a push otherwise;
#       sync-check / stale also clear it). --expect-head must be the FULL 40-hex id. Arming is
#       PINNED to the head the review judged (lastMergeSourceCommit; refused and
#       cleared again when the head moved): squash, work items transitioned,
#       policies never bypassed. A failure to arm leaves the recorded pass
#       standing and exits 1.
#   fail <pr> --expect-head <sha> [--verdict-file <f>]
#   claim-fix <pr> [--force-claim]  the pr-fixing lane (a `fixing` claim ref + the
#                                   pr-fixing tag); exit 3 = a live claim by
#                                   another agent (fix or review)
#   release-fix <pr>                releases the fixing claim and the tag
#   heartbeat <pr>                  proves the review claim is alive (extends the
#                                   TTL); exit 7 = this agent does not hold it
#   held <pr>                       review passed but `hold` is present: release
#                                   pr-reviewing, never apply pr-reviewed
#   apply-hold <pr> [--reason r --head sha --categories csv --session id --order id]
#   release-hold <pr> --order <id> --head <sha>
#                                   REFUSES (exit 9): releasing a hold needs a
#                                   delegation policy this host does not wire; a
#                                   human removes the tag. Same backstops first
#                                   (usage 2 first, then advisory 4, shadow 9).
#   shadow-pass <pr> [--skip-claim-check]
#                                   shadow-mode terminal: agent-reviewed, never
#                                   pr-reviewed; exit 7 = claim not held
#   sync-check <pr> <new-head>      strip a verdict label (pr-reviewed,
#                                   changes-requested, agent-reviewed) whose
#                                   newest verdict artefact judged another head
#   stale <pr>                      new commits after a pass: drop pr-reviewed
#
# Exit codes follow pr-labels.sh's: 3 claim, 4 advisory, 6 follow-up, 7 claim-
# check, 8 hold, 9 shadow, 1 any other refusal, 2 usage / not ported.

_prl_azdo_err() { printf 'pr-labels (azdo): %s\n' "$*" >&2; }

_prl_azdo_main() {
  local cmd="$1" pr="$2"
  shift 2
  local aa origin
  aa="$_PRL_SCRIPT_DIR/../../scripts/azdo-adapter.sh"
  origin="$_PRL_ORIGIN"
  [ -f "$aa" ] || { _prl_azdo_err "azdo-adapter.sh not found"; return 1; }
  command -v jq >/dev/null 2>&1 || { _prl_azdo_err "jq is required"; return 1; }
  # This script IS the review lane's explicit write path (the forgejo block in
  # pr-labels.sh makes the same decision for FORGEJO_ADAPTER_ALLOW_WRITE).
  export AZDO_ADAPTER_ALLOW_WRITE=1
  # The shared follow-up scanner (followups-gate.sh, sourced by `pass` only)
  # reads these from its caller.
  PR="$pr"; REVIEWED="pr-reviewed"; _PRL_HOST=azdo

  _prl_azdo_release_claim() { # <kind> -- release THIS agent's claim ref, best effort
    bash "$aa" pr-release-claim "$origin" "$pr" "$1" >/dev/null 2>&1 \
      || _prl_azdo_err "warning: the $1 claim ref could not be released (release-review --force clears it)"
  }
  # 0 = this agent holds the current reviewing claim; 7 = it does not (or the
  # claim state is unreadable, which fails closed to the same refusal).
  _prl_azdo_require_claim() {
    local cs
    cs="$(bash "$aa" pr-claim-status "$origin" "$pr" reviewing)" \
      || { _prl_azdo_err "refusing: claim state for PR #$pr is unreadable (fail closed)"; return 1; }
    case " $cs " in
      *" claimed=true "*" mine=true "*) return 0 ;;
    esac
    _prl_azdo_err "refusing: this agent does not hold PR #$pr's review claim ($cs) — run start-review first (exit 7)"
    return 7
  }

  _prl_azdo_labels() { # -> one label per line, or non-zero
    bash "$aa" get-pr "$origin" "$pr" | jq -r '.labels[].name' | tr -d '\r'
  }
  _prl_azdo_has() { printf '%s\n' "$1" | grep -qxF -- "$2"; }
  _prl_azdo_status() {
    local l rv=false rd=false
    l="$(_prl_azdo_labels)" || { _prl_azdo_err "could not read labels for PR #$pr"; return 1; }
    _prl_azdo_has "$l" pr-reviewing && rv=true
    _prl_azdo_has "$l" pr-reviewed && rd=true
    printf 'reviewing=%s reviewed=%s\n' "$rv" "$rd"
  }
  _prl_azdo_body() { # <verdict-file-or-empty> <default-text> -> path of a body file
    local f
    if [ -n "$1" ]; then
      [ -f "$1" ] || { _prl_azdo_err "--verdict-file '$1' not found"; return 1; }
      printf '%s' "$1"; return 0
    fi
    f="$(mktemp "${TMPDIR:-/tmp}/sge-azdo-verdict.XXXXXX")" || return 1
    printf '%s\n' "$2" > "$f"
    printf '%s' "$f"
  }

  case "$cmd" in
    start-review)
      local force=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --force-claim) force="--force"; shift ;;
          *) _prl_azdo_err "unknown option '$1' for start-review"; return 2 ;;
        esac
      done
      # Daemon claim handoff (the twin of GitHub's #1249): the review daemon
      # pre-claims the PR it dispatches and exports its own claim-owner id as
      # SGE_REVIEW_CLAIM_HANDOFF_OWNER in the child's ENV (never in prompt text);
      # a live claim recorded for exactly that owner is taken over as the next
      # generation. Sanitised like the daemon sanitises its own agent id.
      local handoff=""
      if [ -z "$force" ] && [ -n "${SGE_REVIEW_CLAIM_HANDOFF_OWNER:-}" ]; then
        handoff="$(printf '%s' "$SGE_REVIEW_CLAIM_HANDOFF_OWNER" | tr -c 'A-Za-z0-9._:/@-' '_')"
      fi
      local rc=0
      bash "$aa" pr-claim "$origin" "$pr" reviewing $force ${handoff:+--handoff "$handoff"} >/dev/null || rc=$?
      case "$rc" in
        0) : ;;
        3) _prl_azdo_err "refusing: PR #$pr is claimed by another review (exit 3)"; return 3 ;;
        *) _prl_azdo_err "could not claim PR #$pr"; return 1 ;;
      esac
      bash "$aa" pr-add-label "$origin" "$pr" pr-reviewing || { _prl_azdo_err "claim won but the pr-reviewing tag could not be added"; return 1; }
      bash "$aa" pr-remove-label "$origin" "$pr" pr-reviewed || _prl_azdo_err "warning: could not remove pr-reviewed"
      echo "PR #$pr: review claimed ($(_prl_azdo_status 2>/dev/null || echo 'label_status unavailable'))"
      ;;
    release-review)
      local force=""
      [ "${1:-}" = "--force" ] && force="--force"
      bash "$aa" pr-release-claim "$origin" "$pr" reviewing $force || return 1
      bash "$aa" pr-remove-label "$origin" "$pr" pr-reviewing || return 1
      echo "PR #$pr: review claim released"
      ;;
    status)
      _prl_azdo_status || return 1
      bash "$aa" pr-claim-status "$origin" "$pr" reviewing || return 1
      ;;
    pass|fail)
      local expect="" vfile="" skip_threads=false skip_claim=false skip_followup=false auto_merge=false
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --skip-followup-check) skip_followup=true; _prl_azdo_err "warning: --skip-followup-check set — follow-up preservation gate disabled for PR #$pr (issue #859)"; shift ;;
          --expect-head) [ "$#" -ge 2 ] || { _prl_azdo_err "--expect-head needs a sha"; return 2; }; expect="$2"; shift 2 ;;
          --verdict-file) [ "$#" -ge 2 ] || { _prl_azdo_err "--verdict-file needs a path"; return 2; }; vfile="$2"; shift 2 ;;
          --skip-thread-check) skip_threads=true; shift ;;
          --skip-claim-check) skip_claim=true; shift ;;
          --auto-merge)
            [ "$cmd" = pass ] || { _prl_azdo_err "--auto-merge only applies to pass"; return 2; }
            auto_merge=true; shift ;;
          *) _prl_azdo_err "unknown option '$1' for $cmd"; return 2 ;;
        esac
      done
      # Same mechanical backstops as the GitHub path (#754, #2651).
      if [ "$cmd" = pass ] && [ "${SGE_REVIEW_ADVISORY:-}" = "1" ]; then
        _prl_azdo_err "refusing: SGE_REVIEW_ADVISORY=1 — advisory dispatch cannot move the gate"; return 4
      fi
      if [ "$cmd" = pass ] && [ "${SGE_REVIEW_SHADOW:-}" = "1" ]; then
        _prl_azdo_err "refusing: SGE_REVIEW_SHADOW=1 — shadow dispatch never applies pr-reviewed"; return 9
      fi
      [ -n "$expect" ] || { _prl_azdo_err "refusing: $cmd needs --expect-head on Azure DevOps (the verdict is bound to the head judged)"; return 1; }
      [[ "$expect" =~ ^[0-9a-fA-F]{40}$ ]] || { _prl_azdo_err "refusing: --expect-head must be the full 40-hex commit id on Azure DevOps (a prefix binds too few bits)"; return 1; }
      local pj head labels
      pj="$(bash "$aa" get-pr "$origin" "$pr")" || { _prl_azdo_err "could not read PR #$pr"; return 1; }
      head="$(printf '%s' "$pj" | jq -r '.headRefOid' | tr -d '\r')"
      labels="$(printf '%s' "$pj" | jq -r '.labels[].name' | tr -d '\r')"
      # A verdict needs THIS agent to hold the current claim generation, not
      # just a pr-reviewing tag (tags are display only): an agent that lost the
      # claim race must never record a verdict (PR #2986 review).
      if [ "$skip_claim" != true ]; then
        local crc=0
        _prl_azdo_require_claim || crc=$?
        [ "$crc" -eq 0 ] || return "$crc"
      fi
      if [ "$cmd" = pass ]; then
        _prl_azdo_has "$labels" hold && { _prl_azdo_err "refusing: PR #$pr carries the hold tag (exit 8)"; return 8; }
        [ "$(printf '%s' "$pj" | jq -r '.isDraft')" != "true" ] || { _prl_azdo_err "refusing: PR #$pr is a draft"; return 1; }
        local ci result
        ci="$(bash "$aa" pr-ci "$origin" "$pr")" || { _prl_azdo_err "refusing: CI state for PR #$pr is unreadable (fail closed)"; return 1; }
        result="$(printf '%s' "$ci" | jq -r '.result' | tr -d '\r')"
        if [ "$result" != green ]; then
          _prl_azdo_err "refusing: PR #$pr CI is $result — $(printf '%s' "$ci" | jq -r '.reasons | join("; ")') (DP5: only green passes)"
          return 1
        fi
        if [ "$skip_threads" != true ]; then
          local th
          th="$(bash "$aa" pr-threads "$origin" "$pr")" || { _prl_azdo_err "refusing: unresolved-thread state unreadable (fail closed)"; return 1; }
          [ "$(printf '%s' "$th" | jq 'length')" -eq 0 ] || { _prl_azdo_err "refusing: PR #$pr has unresolved threads"; return 1; }
        fi
        # A declared follow-up with no issue reference (#859): the same scanner
        # as the GitHub path, so a follow-up cannot evaporate on merge.
        if [ "$skip_followup" != true ]; then
          # shellcheck source=skills/pr-review/followups-gate.sh
          . "$_PRL_SCRIPT_DIR/followups-gate.sh"
          assert_followups_preserved || return 6
        fi
      fi
      local body rc=0 verdict=approve
      [ "$cmd" = fail ] && verdict=wait
      body="$(_prl_azdo_body "$vfile" "SGE PR review: $(printf '%s' "$cmd" | tr 'a-z' 'A-Z') at $head")" || return 1
      bash "$aa" pr-verdict "$origin" "$pr" "$verdict" "$expect" "$body" >/dev/null || rc=$?
      [ -n "$vfile" ] || rm -f "$body"
      case "$rc" in
        0) : ;;
        6) _prl_azdo_err "refusing: PR #$pr head moved since review (reviewed $expect, now $head) — re-review the new head"; return 1 ;;
        *) _prl_azdo_err "could not record the $cmd verdict on PR #$pr"; return 1 ;;
      esac
      if [ "$cmd" = pass ]; then
        bash "$aa" pr-add-label "$origin" "$pr" pr-reviewed || { _prl_azdo_err "vote recorded but pr-reviewed could not be added"; return 1; }
        bash "$aa" pr-remove-label "$origin" "$pr" changes-requested || true
      else
        bash "$aa" pr-add-label "$origin" "$pr" changes-requested || { _prl_azdo_err "vote recorded but changes-requested could not be added"; return 1; }
        bash "$aa" pr-remove-label "$origin" "$pr" pr-reviewed || true
      fi
      bash "$aa" pr-remove-label "$origin" "$pr" pr-reviewing || true
      bash "$aa" pr-release-claim "$origin" "$pr" reviewing >/dev/null 2>&1 \
        || _prl_azdo_err "warning: the review claim ref could not be released (release-review --force clears it)"
      echo "PR #$pr: $cmd recorded at ${head:0:9} ($(_prl_azdo_status 2>/dev/null || echo 'label_status unavailable'))"
      if [ "$auto_merge" = true ]; then
        # Pinned to the head the review JUDGED ($expect), never to whatever the
        # PR is now: the adapter refuses (exit 6) when the head moved, and clears
        # auto-complete again if it moves while arming.
        local arc=0
        bash "$aa" pr-auto-complete "$origin" "$pr" "$expect" >/dev/null || arc=$?
        case "$arc" in
          0) echo "PR #$pr: auto-complete armed, pinned to ${expect:0:9}" ;;
          6) _prl_azdo_err "refusing to arm auto-complete on PR #$pr (exit 6): the head moved since the review (judged $expect), or the target branch policy does not reset approvals on source push — the pass stands for that head only"; return 1 ;;
          *) _prl_azdo_err "the pass is recorded but auto-complete could not be armed on PR #$pr (merge with fpr_merge)"; return 1 ;;
        esac
      fi
      ;;
    claim-fix)
      local force="" fcs fk
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --force-claim) force="--force"; shift ;;
          *) _prl_azdo_err "unknown option '$1' for claim-fix"; return 2 ;;
        esac
      done
      # Shared claim protocol: a live review/work claim by ANOTHER agent blocks a
      # fix too (the fixing lane itself is the claim ref's own CAS below).
      if [ -z "$force" ]; then
        for fk in reviewing work; do
          fcs="$(bash "$aa" pr-claim-status "$origin" "$pr" "$fk")" \
            || { _prl_azdo_err "refusing: $fk claim state for PR #$pr is unreadable (fail closed)"; return 1; }
          if [[ " $fcs " == *" claimed=true "* && " $fcs " == *" live=live "* && " $fcs " == *" mine=false "* ]]; then
            _prl_azdo_err "refusing: PR #$pr has a live $fk claim ($fcs) — another agent is working it (exit 3)"; return 3
          fi
        done
      fi
      local rc=0
      bash "$aa" pr-claim "$origin" "$pr" fixing $force >/dev/null || rc=$?
      case "$rc" in
        0) : ;;
        3) _prl_azdo_err "refusing: PR #$pr already has a fix claim — another fix pass is in flight (exit 3; --force-claim takes over deliberately)"; return 3 ;;
        *) _prl_azdo_err "could not claim the fix lane on PR #$pr"; return 1 ;;
      esac
      bash "$aa" pr-add-label "$origin" "$pr" pr-fixing || { _prl_azdo_err "fix claim won but the pr-fixing tag could not be added"; return 1; }
      echo "PR #$pr: fix claimed ($(bash "$aa" pr-claim-status "$origin" "$pr" fixing 2>/dev/null || echo 'claim status unavailable'))"
      ;;
    release-fix)
      bash "$aa" pr-release-claim "$origin" "$pr" fixing || return 1
      bash "$aa" pr-remove-label "$origin" "$pr" pr-fixing || return 1
      echo "PR #$pr: pr-fixing released"
      ;;
    heartbeat)
      local hrc=0
      bash "$aa" pr-claim-heartbeat "$origin" "$pr" reviewing >/dev/null || hrc=$?
      case "$hrc" in
        0) echo "PR #$pr: review claim heartbeat recorded" ;;
        7) _prl_azdo_err "refusing: this agent does not hold PR #$pr's review claim — no heartbeat (exit 7)"; return 7 ;;
        # Advisory like the GitHub path: a failed post never fails the review.
        *) _prl_azdo_err "warning: could not post the claim heartbeat on PR #$pr (advisory)" ;;
      esac
      ;;
    held)
      # Human-hold termination: release the claim without applying pr-reviewed.
      bash "$aa" pr-remove-label "$origin" "$pr" pr-reviewing || return 1
      bash "$aa" pr-remove-label "$origin" "$pr" changes-requested || return 1
      _prl_azdo_release_claim reviewing
      echo "PR #$pr: review passed — held for human sign-off"
      echo "Remove the 'hold' tag once sign-off is obtained; the next review cycle will promote normally."
      ;;
    apply-hold)
      local reason="" hhead="" cats="" session="" order="" hb
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --reason) reason="${2:-}"; shift 2 ;;
          --head) hhead="${2:-}"; shift 2 ;;
          --categories) cats="${2:-}"; shift 2 ;;
          --session) session="${2:-}"; shift 2 ;;
          --order) order="${2:-}"; shift 2 ;;
          *) _prl_azdo_err "apply-hold: unknown argument '$1'"; return 2 ;;
        esac
      done
      bash "$aa" pr-add-label "$origin" "$pr" hold || { _prl_azdo_err "could not add the hold tag to PR #$pr"; return 1; }
      if [ -n "$reason" ]; then
        # shellcheck source=skills/pr-review/delegation-policy.sh
        . "$_PRL_SCRIPT_DIR/delegation-policy.sh"
        [ -n "$session" ] || session="$(dp_session_id)"
        hb="$(mktemp "${TMPDIR:-/tmp}/sge-azdo-hold.XXXXXX")" || return 1
        if dp_hold_marker_body "$reason" "$hhead" "$cats" "$session" "$order" > "$hb"; then
          bash "$aa" pr-comment "$origin" "$pr" "$hb" >/dev/null \
            || _prl_azdo_err "warning: could not post the hold marker on PR #$pr (hold tag stands; a human must release it)"
        fi
        rm -f "$hb"
      fi
      echo "PR #$pr: 'hold' tag applied — gate will not open until a human removes it"
      ;;
    release-hold)
      local ro="" rh=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --order) ro="${2:-}"; shift 2 ;;
          --head) rh="${2:-}"; shift 2 ;;
          *) _prl_azdo_err "release-hold: unknown argument '$1'"; return 2 ;;
        esac
      done
      [ -n "$ro" ] || { _prl_azdo_err "release-hold needs --order <id>"; return 2; }
      [[ "$rh" =~ ^[0-9a-f]{40}$ ]] || { _prl_azdo_err "release-hold needs --head <full 40-hex sha of the reviewed head>"; return 2; }
      [ "${SGE_REVIEW_ADVISORY:-}" != "1" ] || { _prl_azdo_err "refusing: SGE_REVIEW_ADVISORY=1 — advisory dispatch cannot release 'hold'"; return 4; }
      [ "${SGE_REVIEW_SHADOW:-}" != "1" ] || { _prl_azdo_err "refusing: SGE_REVIEW_SHADOW=1 — shadow dispatch cannot release 'hold'"; return 9; }
      # Releasing a hold is only ever done under a delegation policy's standing
      # order (re-derived from the policy and the PR, never trusted from the
      # caller). That eligibility check reads GitHub review state this host does
      # not wire, so on Azure Repos there is no policy: fail closed (exit 9).
      _prl_azdo_err "PR #$pr: refusing to release 'hold' under '$ro' — no delegation policy is wired for Azure Repos; a human removes the tag (exit 9)"
      return 9
      ;;
    shadow-pass)
      local sc=true
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --skip-claim-check) sc=false; shift ;;
          *) _prl_azdo_err "unknown option '$1' for shadow-pass"; return 2 ;;
        esac
      done
      if [ "$sc" = true ]; then
        local src=0
        _prl_azdo_require_claim || src=$?
        [ "$src" -eq 0 ] || return "$src"
      fi
      # Never touches pr-reviewed and never merges. When a real review already
      # gated this PR (pr-reviewed present, including one that lands between the
      # two reads), agent-reviewed would be false and could retrigger automation:
      # skip the add (#2653).
      local pre mid
      pre="$(_prl_azdo_status)" || pre="unreadable"
      bash "$aa" pr-remove-label "$origin" "$pr" pr-reviewing || return 1
      bash "$aa" pr-remove-label "$origin" "$pr" changes-requested || return 1
      _prl_azdo_release_claim reviewing
      # Re-read right before the one write this guard gates (TOCTOU, #2653); an
      # unreadable state never adds the label.
      mid="$(_prl_azdo_status)" || mid="unreadable"
      if [[ "$pre" != *"reviewed=false" || "$mid" != *"reviewed=false" ]]; then
        echo "PR #$pr: shadow-mode review passed — 'pr-reviewed' present (or the state unreadable); 'agent-reviewed' NOT applied (#2653)"
      else
        bash "$aa" pr-add-label "$origin" "$pr" agent-reviewed || { _prl_azdo_err "could not add agent-reviewed to PR #$pr"; return 1; }
        echo "PR #$pr: shadow-mode review passed — 'agent-reviewed' applied; 'pr-reviewed' NEVER applied and 'pass' was never called (#2651)"
      fi
      ;;
    stale)
      # New commits: any armed auto-complete judged an older head - clear it. A
      # failed clear must NOT keep the stale label on: strip first, THEN fail.
      local sclr=0
      bash "$aa" pr-auto-complete-clear "$origin" "$pr" none >/dev/null || sclr=1
      bash "$aa" pr-remove-label "$origin" "$pr" pr-reviewed || return 1
      _prl_azdo_release_claim reviewing
      echo "PR #$pr: pr-reviewed dropped (stale — new commits since last verdict)"
      if [ "$sclr" -ne 0 ]; then
        _prl_azdo_err "could not clear auto-complete on PR #$pr (fail closed; the stale label was removed)"; return 1
      fi
      ;;
    sync-check)
      local nh="${1:-}" present gl vs vsha vl nl n stripped=""
      [[ "$nh" =~ ^[0-9a-fA-F]{7,40}$ ]] || { _prl_azdo_err "sync-check requires <pr> <new-head-sha>"; return 2; }
      # A push after auto-complete was armed does not cancel it on ADO: clear it
      # whenever the PR's live head is not the head the newest verdict artefact
      # judged (no / unreadable verdict -> clear). Before any label early-return.
      local jv jh="none"
      jv="$(bash "$aa" pr-verdict-status "$origin" "$pr" 2>/dev/null)" || jv=""
      [[ "$jv" =~ ^(approve|wait|reject)\ ([0-9a-f]{40})$ ]] && jh="${BASH_REMATCH[2]}"
      # A failed clear must not leave the stale labels behind: strip them, THEN
      # report the failure (non-zero) at the end.
      local clr=0
      bash "$aa" pr-auto-complete-clear "$origin" "$pr" "$jh" >/dev/null || {
        clr=1; _prl_azdo_err "could not clear auto-complete on PR #$pr (fail closed; labels are still processed)"; }
      present="$(_prl_azdo_labels)" || { _prl_azdo_err "PR #$pr: sync-check — labels unreadable; nothing stripped"; return "$clr"; }
      local on=()
      for gl in pr-reviewed changes-requested agent-reviewed; do
        _prl_azdo_has "$present" "$gl" && on+=("$gl")
      done
      if [ "${#on[@]}" -eq 0 ]; then
        echo "PR #$pr: sync-check — no verdict gate label (pr-reviewed changes-requested agent-reviewed), nothing to strip"
        return "$clr"
      fi
      # The newest verdict ARTEFACT by this token identity (never a tag): a
      # label is stripped only when that artefact provably judged another head.
      # No / unreadable verdict retains the label (readers already treat an
      # unproven label as absent), exactly like the GitHub writer.
      vs="$(bash "$aa" pr-verdict-status "$origin" "$pr" 2>/dev/null)" \
        || { _prl_azdo_err "PR #$pr: sync-check — verdicts unreadable; labels retained (readers treat unproven labels as absent)"; return "$clr"; }
      if [ "$vs" = none ]; then
        echo "PR #$pr: sync-check — no sge-verdict found; cannot determine coverage; labels retained"
        return "$clr"
      fi
      vsha="$(printf '%s' "${vs#* }" | tr 'A-F' 'a-f')"; nl="$(printf '%s' "$nh" | tr 'A-F' 'a-f')"
      [[ "$vsha" =~ ^[0-9a-f]{40}$ ]] || { _prl_azdo_err "PR #$pr: sync-check — verdict sha '$vsha' is malformed; labels retained"; return "$clr"; }
      n=${#nl}
      if [ "${vsha:0:$n}" = "$nl" ]; then
        echo "PR #$pr: sync-check — verdict covers head (${vsha:0:12}); ${on[*]} retained"
        return "$clr"
      fi
      for gl in "${on[@]}"; do
        bash "$aa" pr-remove-label "$origin" "$pr" "$gl" || { _prl_azdo_err "could not strip $gl from PR #$pr"; return 1; }
        stripped="$stripped${stripped:+ }$gl"
      done
      _prl_azdo_release_claim reviewing
      echo "PR #$pr: $stripped stripped — verdict was pinned to ${vsha:0:12}, new head is ${nl:0:12}"
      vl="$(mktemp "${TMPDIR:-/tmp}/sge-azdo-sync.XXXXXX")" || return "$clr"
      printf '**%s stripped** (head-scoped gate labels; issue #1941)\n\nThe latest verdict was pinned to `%s`; the new head after push is `%s`. A verdict label cannot describe a superseded commit.\n\nA re-review at the new head re-applies the right label.\n' \
        "$stripped" "$vsha" "$nl" > "$vl"
      bash "$aa" pr-comment "$origin" "$pr" "$vl" >/dev/null 2>&1 \
        || _prl_azdo_err "warning: could not post the staleness comment on PR #$pr (best-effort)"
      rm -f "$vl"
      return "$clr"
      ;;
    *)
      _prl_azdo_err "'$cmd' is not ported to Azure DevOps (ports: start-review, release-review, status, pass, fail, claim-fix, release-fix, heartbeat, held, apply-hold, release-hold, shadow-pass, sync-check, stale) — refusing rather than calling gh"
      return 2
      ;;
  esac
}
