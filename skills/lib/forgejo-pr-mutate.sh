#!/usr/bin/env bash
# forgejo-pr-mutate.sh — routing shim for MUTATING PR operations on non-GitHub
# hosts (issue #2582, the mutating slice deferred by forgejo-pr-read.sh / #1238).
#
# forgejo-pr-read.sh gave every skill a UNIFIED INTERFACE for read-only PR ops
# (fpr_list/fpr_view/fpr_diff/fpr_checks) that routes to `gh` on GitHub and to
# scripts/forgejo-adapter.sh on a Forgejo/Gitea host, while explicitly deferring
# mutating ops ("skip + log deferral"). This file is that deferred slice: rerun,
# merge (with a degrading merge-readiness check), and label add/remove.
#
# It builds entirely on primitives that already ship in forgejo-adapter.sh
# (pr-add-label / pr-remove-label / pr-merge-squash / pr-head-sha — issue
# #1239) plus plain `git push`, which already works directly against a
# Forgejo remote with no adapter involved (see skills/pr-fix/SKILL.md Loop
# step 7). This file does not add new REST verbs to the adapter; it wires the
# existing ones (and plain git, for rerun) behind the same `fpr_*` seam that
# forgejo-pr-read.sh established, so a caller never branches on host itself.
#
# GOVERNANCE NOTE (#2582): built WITHOUT live access to the validation target
# named in the issue's governance decision — git.feaw.co.uk/FEAW/homelab-infra
# (Forgejo-hosted). This lane had no `git.feaw.co.uk` credentials and no
# `mcp__forgejo__*` MCP server configured (that tooling is scoped to a
# different repo's CLAUDE.md, `getmy`). Everything below is built to the best
# specification implied by the issue's own worked example (a real getmy#16460
# CI-fix session) and validated here only against mocked curl/gh/git — NOT
# against a live Forgejo instance. See the three "NOT LIVE-VALIDATED" markers
# below for the specific unverified assumptions; a manual pass by whoever has
# `mcp__forgejo__*` access against the real target repo is a required follow-up
# before this is trusted in production pr-monitor/pr-review runs.
#
# Usage (source AFTER forgejo-pr-read.sh, or let this file source it for you):
#   source "${CLAUDE_PLUGIN_ROOT}/skills/lib/forgejo-pr-mutate.sh"
#
#   # Re-run CI for a PR.
#   #   GitHub path  → resolve the head SHA's most recent run, `gh run rerun
#   #                  --failed <run-id>` (failed-jobs-only rerun).
#   #   Forgejo path → NO NATIVE FAILED-ONLY RERUN EXISTS (checked against the
#   #                  getmy#16460 worked example — no `mcp__forgejo__*` tool
#   #                  surfaces one, and the Gitea REST surface has no
#   #                  equivalent of GitHub Actions' rerun-failed-jobs). The
#   #                  only lever is a full CI retrigger: an empty
#   #                  `ci: retrigger — <reason>` commit pushed to the PR
#   #                  branch, which reruns EVERYTHING, not just the failed
#   #                  jobs. PRECONDITION: the caller's cwd must already be a
#   #                  checkout on the PR's head branch (the standard
#   #                  pr-fix/pr-monitor worktree convention) — this function
#   #                  verifies that and refuses otherwise; it does not clone
#   #                  or check anything out itself.
#   fpr_rerun <pr-index> [reason]
#
#   # Merge-readiness check (does NOT merge). Three gates by default (linked /
#   # reviewed-label / CI-green), degrading to (linked / CI-green) — i.e.
#   # CI-green is the binding gate — when the repo has not opted into a
#   # reviewed-label convention. See fpr_merge_ready's own comment for exactly
#   # how that opt-in is detected.
#   #   Prints READY (exit 0) or GATE_FAIL:<reason> (exit 1). "CI-green" is a
#   #   POSITIVE signal: at least one status and every status green — no
#   #   statuses (ci_none) and in-flight statuses (ci_pending) both refuse, and
#   #   ci_unknown refuses when CI state can't be resolved at all (fail-closed).
#   fpr_merge_ready <pr-index>
#
#   # Merge a PR. Runs fpr_merge_ready first and refuses on any gate failure
#   # (pass --skip-ready-check to bypass — e.g. a caller that already ran its
#   # own equivalent check).
#   #   GitHub path  → gh pr merge <N> --squash --auto
#   #   Forgejo path → mcp__forgejo__merge_pull_request is the direct
#   #                  equivalent per the issue's worked example; this shim
#   #                  wraps the same operation via the adapter's
#   #                  pr-merge-squash, pinned to the head SHA resolved BEFORE
#   #                  the ready check (a push landing mid-call moves the head
#   #                  off that SHA and Gitea refuses). Unlike GitHub's
#   #                  `--auto`, this merges IMMEDIATELY — nothing waits for
#   #                  CI server-side, which is why the ready check above
#   #                  demands a positive green signal.
#   fpr_merge <pr-index> [--skip-ready-check]
#
#   # Label add/remove — direct equivalents of `gh pr edit --add-label` /
#   # `--remove-label`. On Forgejo the label must already exist in the repo
#   # (create it once with `forgejo-adapter.sh pr-ensure-label` — not wrapped
#   # here, this slice does not assume every Forgejo repo runs a label state
#   # machine at all; see fpr_merge_ready).
#   fpr_add_label    <pr-index> <label-name>
#   fpr_remove_label <pr-index> <label-name>
#
# Explicitly OUT OF SCOPE for this slice (do not assume these work):
#   - pr-review's full label STATE MACHINE (pr-labels.sh: start-review claim
#     mutex, stale-claim takeover, changes-requested, hold, sync-check,
#     heartbeats, sge-verdict tracking, etc.) is NOT ported to Forgejo. Only
#     the bare add/remove-label primitive is available here. A Forgejo repo
#     that wants the full gate needs that ported as a future slice; until
#     then, treat fpr_merge_ready's label gate as informational only, keyed
#     on whatever single label name the repo nominates via
#     SGE_FORGEJO_REVIEWED_LABEL.
#   - Cancelled-vs-failed run disambiguation on Forgejo (the GitHub-side
#     `is_cancelled_run` in monitor-lib.sh, #1665) has NO Forgejo equivalent
#     here. Gitea's CommitStatus schema (state: pending/success/error/
#     failure/warning) has no dedicated "cancelled" state distinct from
#     failure/error, per forgejo-adapter.sh's own pr-commit-status mapping —
#     but whether a Forgejo Actions run that was actually cancelled reports as
#     `error`, `failure`, or something else entirely is UNVERIFIED without a
#     live cancelled run to inspect. OPEN QUESTION, not guessed at here:
#     fpr_check_is_failing (forgejo-pr-read.sh) will currently treat any
#     failure/error state as a hard CI failure, so a cancelled Forgejo run
#     may be mis-routed to CODE FAIL/GATE_FAIL:ci_failing instead of being
#     given the CANCELLED-row treatment GitHub gets. Needs checking against a
#     real cancelled Forgejo run before this file's callers rely on the
#     distinction.
#
# Environment (in addition to forgejo-pr-read.sh's):
#   FORGEJO_ADAPTER_ALLOW_WRITE — set to 1 internally by this file's own
#     forgejo-path calls into forgejo-adapter.sh; sourcing this file at all
#     (as opposed to forgejo-pr-read.sh) is the explicit, auditable decision
#     to permit mutating ops (ADR-0010's read-vs-mutating boundary is honoured
#     at the forgejo-adapter.sh layer regardless — this file cannot bypass it,
#     it just supplies the flag on the caller's behalf for each mutating call
#     it makes).
#   SGE_FORGEJO_REVIEWED_LABEL — opt-in: the label name this repo's own
#     convention uses as its merge-gate label (mirrors $MERGE_GATE_LABEL's
#     CLAUDE.md-resolution pattern on the GitHub side, SKILL.md's "Merge
#     readiness — three gates"). Unset = this repo has no such convention;
#     fpr_merge_ready degrades to (linked, CI-green) only.
#
# NOTE: shell state does NOT persist across agent tool calls; source this file
# at the top of each tool call where it is needed. See
# docs/skill-authoring-repo-context.md.

set -euo pipefail

_FPM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reuse forgejo-pr-read.sh's host detection, origin resolution, fpr_view,
# _FPR_ADAPTER path, and fpr_check_is_failing — do NOT fork a second copy of
# any of that here. Sourcing only defines functions/vars (same contract
# forgejo-adapter.sh relies on for with-repo-cwd.sh), so this is a pure
# include with no extra side effects beyond what read.sh already has.
# shellcheck source=skills/lib/forgejo-pr-read.sh
. "$_FPM_SCRIPT_DIR/forgejo-pr-read.sh"

_fpm_err() { printf 'forgejo-pr-mutate: error: %s\n' "$*" >&2; }

# _fpm_adapter_failed <fn> <pr> <adapter-verb> <rc>
# A server-side refusal reaches us as a bare `curl: (22) ... 404/405` from the
# adapter's `curl -f` (sge#2626 live validation L4/L7/M2). Add the op + PR
# context, and decode curl's 22 (HTTP >= 400) so the operator knows why. The
# caller still returns the adapter's own non-zero rc (fail closed).
_fpm_adapter_failed() {
  local hint=''
  [ "$4" = 22 ] && hint=' — the server returned HTTP >= 400 (see the curl line above: 404 = no such PR/label, 405/409 = PR not mergeable, already merged/closed, or head moved)'
  _fpm_err "$1: PR $2: forgejo-adapter.sh $3 failed (exit $4)$hint"
}

# fpr_rerun <pr-index> [reason]
# Re-run CI for a PR. See the header comment for the GitHub-vs-Forgejo
# asymmetry (native failed-only rerun vs. full-retrigger-only).
fpr_rerun() {
  local pr="${1:-}" reason="${2:-manual retrigger}"
  [ -n "$pr" ] || { _fpm_err "fpr_rerun: <pr-index> required"; return 1; }
  local host; host="$(fpr_host_kind)"
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
    forgejo)
      # NOT LIVE-VALIDATED: this empty-commit strategy is the documented
      # getmy#16460 workaround, not something exercised against a live
      # Forgejo instance in this lane.
      command -v jq >/dev/null 2>&1 || { _fpm_err "jq is required for fpr_rerun on a Forgejo host"; return 1; }
      local origin pr_json expected_ref current_ref head_sha head_repo base_repo
      origin="$(_fpr_origin_url)" || return 1
      [ -f "$_FPR_ADAPTER" ] || { _fpm_err "forgejo-adapter.sh not found at $_FPR_ADAPTER"; return 1; }
      pr_json="$(bash "$_FPR_ADAPTER" get-pr "$origin" "$pr")" \
        || { _fpm_err "fpr_rerun: could not fetch PR $pr"; return 1; }
      expected_ref="$(printf '%s' "$pr_json" | jq -r '.head.ref // empty')"
      [ -n "$expected_ref" ] || { _fpm_err "fpr_rerun: could not resolve head ref for PR $pr"; return 1; }
      head_sha="$(printf '%s' "$pr_json" | jq -r '.head.sha // empty')"
      head_repo="$(printf '%s' "$pr_json" | jq -r '.head.repo.full_name // empty')"
      base_repo="$(printf '%s' "$pr_json" | jq -r '.base.repo.full_name // empty')"
      [ -n "$head_sha" ] && [ -n "$head_repo" ] && [ -n "$base_repo" ] \
        || { _fpm_err "fpr_rerun: PR $pr head sha/repo not resolvable — refusing"; return 1; }
      # A branch NAME match says nothing about WHICH repo's branch it is: on a fork
      # PR, `origin` is the base repo, so pushing "HEAD:<ref>" would land on the
      # base repo's branch of that name (e.g. main), not the PR.
      if [ "$head_repo" != "$base_repo" ]; then
        _fpm_err "fpr_rerun: PR $pr head is in '$head_repo' (base '$base_repo') — refusing to push a retrigger from a fork PR"
        return 1
      fi
      current_ref="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" \
        || { _fpm_err "fpr_rerun: not in a git checkout"; return 1; }
      # Safety guard: never commit onto a branch other than the PR's own head.
      # This function deliberately does NOT clone or checkout on the caller's
      # behalf (see header) — it only verifies and refuses.
      if [ "$current_ref" != "$expected_ref" ]; then
        _fpm_err "fpr_rerun: current branch '$current_ref' != PR $pr head ref '$expected_ref' — refusing to commit onto the wrong branch (checkout the PR branch first)"
        return 1
      fi
      # Local HEAD must BE the PR head: any unpushed local commit would otherwise
      # be published under a "retrigger" message by the push below.
      if [ "$(git rev-parse HEAD 2>/dev/null)" != "$head_sha" ]; then
        _fpm_err "fpr_rerun: local HEAD != PR $pr head $head_sha — refusing (unpushed or foreign commits; sync the checkout first)"
        return 1
      fi
      # `git commit --allow-empty` still commits whatever is staged — refuse
      # rather than push unreviewed index content under a "retrigger" message.
      git diff --cached --quiet \
        || { _fpm_err "fpr_rerun: staged changes present — refusing to fold them into the retrigger commit (commit or unstage first)"; return 1; }
      git commit --allow-empty -m "ci: retrigger — ${reason}" \
        || { _fpm_err "fpr_rerun: empty commit failed"; return 1; }
      git push origin "HEAD:refs/heads/${expected_ref}" \
        || { _fpm_err "fpr_rerun: push failed"; return 1; }
      ;;
    *)
      _fpm_err "unknown host kind '$host' — cannot rerun CI for PR $pr"
      return 1
      ;;
  esac
}

# fpr_merge_ready <pr-index>
# Merge-readiness check, read-only (no mutation). Prints READY / GATE_FAIL:<x>
# on stdout; exit 0 iff READY. See header comment for the degrade rule.
fpr_merge_ready() {
  local pr="${1:-}"
  [ -n "$pr" ] || { _fpm_err "fpr_merge_ready: <pr-index> required"; return 2; }
  command -v jq >/dev/null 2>&1 || { _fpm_err "jq is required for fpr_merge_ready"; return 2; }

  local pr_json body labels
  pr_json="$(fpr_view "$pr" --json body,labels 2>/dev/null)" \
    || { _fpm_err "fpr_merge_ready: could not fetch PR $pr"; return 2; }
  body="$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null)"
  labels="$(printf '%s' "$pr_json" | jq -r '.labels[].name' 2>/dev/null)"   # one name per line

  # Gate 1 — issue linked. Host-agnostic (a body-text regex), deliberately kept
  # byte-for-byte identical to monitor-lib.sh's pr_ready_for_merge Gate 1 —
  # see that function's comment for why `part of #N` counts as a link without
  # requiring a closing keyword.
  if ! printf '%s' "$body" | grep -iqE '(clos(e|es|ed)|fix(es|ed)?|resolv(e|es|ed)|(^|[^[:alnum:]])part[[:space:]]+of)[[:space:]]+#[0-9]+'; then
    echo "GATE_FAIL:not_linked"; return 1
  fi

  # Gate 2 — reviewed label, ONLY when this repo has opted into a
  # reviewed-label convention (SGE_FORGEJO_REVIEWED_LABEL set). This is the
  # documented degrade: unlike GitHub, Gitea's API gives no reliable way to
  # introspect "does this repo run a review-label state machine at all" —
  # the getmy#16460 target repo (git.feaw.co.uk/FEAW/homelab-infra) has none,
  # per its own CLAUDE.md, so CI-green becomes the sole binding gate there.
  # Absence of the env var is the explicit degrade signal, never a guess.
  if [ -n "${SGE_FORGEJO_REVIEWED_LABEL:-}" ]; then
    # Whole-line fixed-string match: a look-alike ("pr-reviewed-stale") or a
    # regex metacharacter in the configured name must not satisfy the gate.
    if ! printf '%s\n' "$labels" | grep -qxF -- "${SGE_FORGEJO_REVIEWED_LABEL}"; then
      echo "GATE_FAIL:not_reviewed"; return 1
    fi
  fi

  # Gate 3 — CI green. Always required, on every host. Reuses
  # fpr_check_is_failing (forgejo-pr-read.sh) so both hosts are judged by
  # exactly the same rule; THREE-VALUED per that function's own contract:
  # exit 2 (unresolvable) must fail closed, never read as "not failing".
  local rc=0
  fpr_check_is_failing "$pr" || rc=$?
  case "$rc" in
    0) echo "GATE_FAIL:ci_failing"; return 1 ;;
    2) echo "GATE_FAIL:ci_unknown"; return 1 ;;
  esac
  # "Not failing" is not "green": fpr_check_is_failing is also 1 for an EMPTY
  # status list and for statuses still PENDING. Require at least one status and
  # none still open, else a Forgejo merge (immediate, no server-side wait)
  # would ship code whose CI never ran or hasn't finished.
  local checks n_total n_open
  checks="$(fpr_checks "$pr" 2>/dev/null)" || { echo "GATE_FAIL:ci_unknown"; return 1; }
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

  local host; host="$(fpr_host_kind)"
  # Forgejo: resolve the head SHA ONCE, BEFORE the ready check, and pin the merge
  # to it. Re-reading it after the check would pin to whatever head exists by
  # then — including a commit pushed mid-call that the check never evaluated.
  # With the early SHA, a head that moves anywhere in the window no longer
  # matches head_commit_id and Gitea refuses (mirrors pr-merge-squash's own
  # TOCTOU contract, issue #1239: the caller passes the head it checked).
  local origin='' sha=''
  if [ "$host" = forgejo ]; then
    command -v jq >/dev/null 2>&1 || { _fpm_err "jq is required for fpr_merge on a Forgejo host"; return 1; }
    origin="$(_fpr_origin_url)" || return 1
    [ -f "$_FPR_ADAPTER" ] || { _fpm_err "forgejo-adapter.sh not found at $_FPR_ADAPTER"; return 1; }
    sha="$(bash "$_FPR_ADAPTER" pr-head-sha "$origin" "$pr")" \
      || { _fpm_err "fpr_merge: could not resolve head SHA for PR $pr"; return 1; }
    [ -n "$sha" ] || { _fpm_err "fpr_merge: empty head SHA for PR $pr"; return 1; }
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
    forgejo)
      # NOT LIVE-VALIDATED: pinned squash-merge, see the SHA note above.
      local rc=0
      FORGEJO_ADAPTER_ALLOW_WRITE=1 bash "$_FPR_ADAPTER" pr-merge-squash "$origin" "$pr" "$sha" || rc=$?
      [ "$rc" -eq 0 ] || { _fpm_adapter_failed fpr_merge "$pr" pr-merge-squash "$rc"; return "$rc"; }
      ;;
    *)
      _fpm_err "unknown host kind '$host' — cannot merge PR $pr"
      return 1
      ;;
  esac
}

# fpr_add_label <pr-index> <label-name>
# GitHub path:  gh pr edit <N> --add-label <name>
# Forgejo path: forgejo-adapter.sh pr-add-label <origin> <N> <name> — the
# label must already exist in the repo (run `forgejo-adapter.sh
# pr-ensure-label` once beforehand; not wrapped here, see header "out of
# scope" note — this slice does not assume a label-gate convention).
fpr_add_label() {
  local pr="${1:-}" label="${2:-}"
  [ -n "$pr" ] && [ -n "$label" ] || { _fpm_err "fpr_add_label: <pr-index> <label-name> required"; return 1; }
  local host; host="$(fpr_host_kind)"
  case "$host" in
    github)
      gh pr edit "$pr" --add-label "$label"
      ;;
    forgejo)
      local origin; origin="$(_fpr_origin_url)" || return 1
      [ -f "$_FPR_ADAPTER" ] || { _fpm_err "forgejo-adapter.sh not found at $_FPR_ADAPTER"; return 1; }
      local rc=0
      FORGEJO_ADAPTER_ALLOW_WRITE=1 bash "$_FPR_ADAPTER" pr-add-label "$origin" "$pr" "$label" || rc=$?
      [ "$rc" -eq 0 ] || { _fpm_adapter_failed fpr_add_label "$pr" pr-add-label "$rc"; return "$rc"; }
      ;;
    *)
      _fpm_err "unknown host kind '$host' — cannot add label to PR $pr"
      return 1
      ;;
  esac
}

# fpr_remove_label <pr-index> <label-name>
# GitHub path:  gh pr edit <N> --remove-label <name>
# Forgejo path: forgejo-adapter.sh pr-remove-label <origin> <N> <name> —
# idempotent, no error if the label is absent (matches the adapter's own
# idempotency contract).
fpr_remove_label() {
  local pr="${1:-}" label="${2:-}"
  [ -n "$pr" ] && [ -n "$label" ] || { _fpm_err "fpr_remove_label: <pr-index> <label-name> required"; return 1; }
  local host; host="$(fpr_host_kind)"
  case "$host" in
    github)
      gh pr edit "$pr" --remove-label "$label"
      ;;
    forgejo)
      local origin; origin="$(_fpr_origin_url)" || return 1
      [ -f "$_FPR_ADAPTER" ] || { _fpm_err "forgejo-adapter.sh not found at $_FPR_ADAPTER"; return 1; }
      local rc=0
      FORGEJO_ADAPTER_ALLOW_WRITE=1 bash "$_FPR_ADAPTER" pr-remove-label "$origin" "$pr" "$label" || rc=$?
      [ "$rc" -eq 0 ] || { _fpm_adapter_failed fpr_remove_label "$pr" pr-remove-label "$rc"; return "$rc"; }
      ;;
    *)
      _fpm_err "unknown host kind '$host' — cannot remove label from PR $pr"
      return 1
      ;;
  esac
}
