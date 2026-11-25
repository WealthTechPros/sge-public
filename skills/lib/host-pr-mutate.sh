#!/usr/bin/env bash
# Source for PR writes and merge-readiness checks on the supported hosts.
set -euo pipefail

_FPM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=skills/lib/host-pr-read.sh
. "$_FPM_SCRIPT_DIR/host-pr-read.sh"

_fpm_err() { printf 'host-pr-mutate: error: %s\n' "$*" >&2; }

# fpr_rerun <pr-index> [reason]
fpr_rerun() {
  local pr="${1:-}"
  [ -n "$pr" ] || { _fpm_err "fpr_rerun: <pr-index> required"; return 1; }
  local host; host="$(hpr_host_kind)"
  case "$host" in
    github)
      local sha run_id
      command -v jq >/dev/null 2>&1 || { _fpm_err "jq is required for fpr_rerun on GitHub"; return 1; }
      # Pipe through our own jq rather than gh's built-in --jq: keeps this
      # function's parsing behaviour identical regardless of which gh-shaped
      # tool is on PATH (real gh or a test double).
      # `|| var=''`: under pipefail + set -e a failing gh would otherwise exit the
      # caller's shell here, before the error message / `return 1` below.
      sha="$(gh pr view "$pr" --json headRefOid 2>/dev/null | jq -r '.headRefOid // empty' 2>/dev/null)" || sha=''
      [ -n "$sha" ] || { _fpm_err "fpr_rerun: could not resolve head SHA for PR $pr"; return 1; }
      run_id="$(gh run list --commit "$sha" --json databaseId --limit 1 2>/dev/null \
        | jq -r '.[0].databaseId // empty' 2>/dev/null)" || run_id=''
      [ -n "$run_id" ] || { _fpm_err "fpr_rerun: could not resolve a run id for PR $pr at $sha"; return 1; }
      gh run rerun "$run_id" --failed
      ;;
    *)
      _fpm_err "unknown host kind '$host' — cannot rerun CI for PR $pr"
      return 1
      ;;
  esac
}

# fpr_merge_ready <pr-index>
# Merge-readiness check, read-only (no mutation). Prints READY / GATE_FAIL:<x>
# on stdout; exit 0 iff READY.
fpr_merge_ready() {
  local pr="${1:-}"
  [ -n "$pr" ] || { _fpm_err "fpr_merge_ready: <pr-index> required"; return 2; }
  command -v jq >/dev/null 2>&1 || { _fpm_err "jq is required for fpr_merge_ready"; return 2; }

  local pr_json body labels
  pr_json="$(hpr_view "$pr" --json body,labels 2>/dev/null)" \
    || { _fpm_err "fpr_merge_ready: could not fetch PR $pr"; return 2; }
  body="$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null)"
  labels="$(printf '%s' "$pr_json" | jq -r '.labels[].name' 2>/dev/null)"   # one name per line

  # Azure DevOps (#2985): gate 1 is the NATIVE work-item link (DR6), not body
  # text. Gate 2 always applies (no branch protection backstops it) and does
  # NOT trust the pr-reviewed tag, which anyone with tag-write (the author
  # included) can set and which survives a later push (PR #2986 review). It
  # requires the newest verdict artefact written by the SGE token identity
  # (azdo-adapter.sh pr-verdict-status) to be `approve` at the CURRENT head.
  # The tag is display only. Gate 3 below is shared.
  if [ "$(hpr_host_kind)" = azdo ]; then
    local wis vs head
    wis="$(bash "$_HPR_AZDO_ADAPTER" pr-work-items "$(_hpr_origin_url)" "$pr" 2>/dev/null)" \
      || { echo "GATE_FAIL:link_unknown"; return 1; }
    [ -n "$wis" ] || { echo "GATE_FAIL:not_linked"; return 1; }
    head="$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""' 2>/dev/null | tr -d '\r')"
    [ -n "$head" ] || head="$(hpr_view "$pr" --json headRefOid --jq .headRefOid 2>/dev/null | tr -d '\r')" || head=''
    vs="$(bash "$_HPR_AZDO_ADAPTER" pr-verdict-status "$(_hpr_origin_url)" "$pr" 2>/dev/null | tr -d '\r')" \
      || { echo "GATE_FAIL:verdict_unknown"; return 1; }
    [[ "$head" =~ ^[0-9a-f]{40}$ && "$vs" == "approve $head" ]] \
      || { echo "GATE_FAIL:not_reviewed"; return 1; }
  else
    # Gate 1 — issue linked. Host-agnostic (a body-text regex), deliberately kept
    # byte-for-byte identical to monitor-lib.sh's pr_ready_for_merge Gate 1 —
    # see that function's comment for why `part of #N` counts as a link without
    # requiring a closing keyword.
    if ! grep -iqE '(clos(e|es|ed)|fix(es|ed)?|resolv(e|es|ed)|(^|[^[:alnum:]])part[[:space:]]+of)[[:space:]]+#[0-9]+' <<<"$body"; then
      echo "GATE_FAIL:not_linked"; return 1
    fi

    # Match the GitHub review lane’s configured gate label exactly.
    if ! grep -qxF -- "${MERGE_GATE_LABEL:-pr-reviewed}" <<<"$labels"; then
      echo "GATE_FAIL:not_reviewed"; return 1
    fi
  fi

  # Gate 3 — CI green. Always required, on every host. Reuses
  # hpr_check_is_failing (host-pr-read.sh) so both hosts are judged by
  # exactly the same rule; THREE-VALUED per that function's own contract:
  # exit 2 (unresolvable) must fail closed, never read as "not failing".
  local rc=0
  hpr_check_is_failing "$pr" || rc=$?
  case "$rc" in
    0) echo "GATE_FAIL:ci_failing"; return 1 ;;
    2) echo "GATE_FAIL:ci_unknown"; return 1 ;;
  esac
  # "Not failing" is not "green": hpr_check_is_failing is also 1 for an EMPTY
  # status list and for statuses still PENDING. Require at least one status and
  # none still open, so an immediate completion cannot ship unchecked code.
  local checks n_total n_open
  checks="$(hpr_checks "$pr" 2>/dev/null)" || { echo "GATE_FAIL:ci_unknown"; return 1; }
  n_total="$(printf '%s' "$checks" | jq 'length' 2>/dev/null)" || n_total=''
  n_open="$(printf '%s' "$checks" | jq '[.[] | select(.state != "SUCCESS" and .state != "SKIPPED" and .state != "NEUTRAL")] | length' 2>/dev/null)" || n_open=''
  case "$n_total" in ''|*[!0-9]*) echo "GATE_FAIL:ci_unknown"; return 1 ;; esac
  case "$n_open" in ''|*[!0-9]*) echo "GATE_FAIL:ci_unknown"; return 1 ;; esac
  [ "$n_total" -gt 0 ] || { echo "GATE_FAIL:ci_none"; return 1; }
  [ "$n_open" -eq 0 ] || { echo "GATE_FAIL:ci_pending"; return 1; }

  echo "READY"; return 0
}

# fpr_merge <pr-index> [--skip-ready-check]
# Merge a PR (squash). Runs fpr_merge_ready first unless --skip-ready-check.
fpr_merge() {
  local pr="${1:-}"
  [ -n "$pr" ] || { _fpm_err "fpr_merge: <pr-index> required"; return 1; }
  shift || true
  local skip=0
  case "${1:-}" in --skip-ready-check) skip=1 ;; esac

  local host; host="$(hpr_host_kind)"
  local origin='' sha=''
  if [ "$host" = azdo ]; then
    command -v jq >/dev/null 2>&1 || { _fpm_err "jq is required for fpr_merge on Azure DevOps"; return 1; }
    origin="$(_hpr_origin_url)" || return 1
    sha="$(hpr_view "$pr" --json headRefOid --jq .headRefOid 2>/dev/null | tr -d '\r')" || sha=''
    [ -n "$sha" ] || { _fpm_err "fpr_merge: could not resolve head SHA for PR $pr"; return 1; }
  fi

  if [ "$skip" -ne 1 ]; then
    local ready rc=0
    ready="$(fpr_merge_ready "$pr")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      _fpm_err "fpr_merge: refusing to merge PR $pr — ${ready:-not ready (exit $rc)}"
      return 1
    fi
  fi

  case "$host" in
    github)
      gh pr merge "$pr" --squash --auto
      ;;
    azdo)
      # Squash-complete pinned to the head checked above; transitionWorkItems
      # closes the linked work items (SPEC-110 P8).
      AZDO_ADAPTER_ALLOW_WRITE=1 bash "$_HPR_AZDO_ADAPTER" pr-merge "$origin" "$pr" "$sha"
      ;;
    *)
      _fpm_err "unknown host kind '$host' — cannot merge PR $pr"
      return 1
      ;;
  esac
}

# fpr_add_label <pr-index> <label-name>
# GitHub path:  gh pr edit <N> --add-label <name>
fpr_add_label() {
  local pr="${1:-}" label="${2:-}"
  [ -n "$pr" ] && [ -n "$label" ] || { _fpm_err "fpr_add_label: <pr-index> <label-name> required"; return 1; }
  local host; host="$(hpr_host_kind)"
  case "$host" in
    github)
      gh pr edit "$pr" --add-label "$label"
      ;;
    azdo)
      # PR labels are PR tags on Azure Repos (#2985).
      AZDO_ADAPTER_ALLOW_WRITE=1 bash "$_HPR_AZDO_ADAPTER" pr-add-label "$(_hpr_origin_url)" "$pr" "$label"
      ;;
    *)
      _fpm_err "unknown host kind '$host' — cannot add label to PR $pr"
      return 1
      ;;
  esac
}

# fpr_remove_label <pr-index> <label-name>
# GitHub path:  gh pr edit <N> --remove-label <name>
fpr_remove_label() {
  local pr="${1:-}" label="${2:-}"
  [ -n "$pr" ] && [ -n "$label" ] || { _fpm_err "fpr_remove_label: <pr-index> <label-name> required"; return 1; }
  local host; host="$(hpr_host_kind)"
  case "$host" in
    github)
      gh pr edit "$pr" --remove-label "$label"
      ;;
    azdo)
      AZDO_ADAPTER_ALLOW_WRITE=1 bash "$_HPR_AZDO_ADAPTER" pr-remove-label "$(_hpr_origin_url)" "$pr" "$label"
      ;;
    *)
      _fpm_err "unknown host kind '$host' — cannot remove label from PR $pr"
      return 1
      ;;
  esac
}
