#!/usr/bin/env bash
# Offline unit tests for the label-attribution comment added to
# add_label/remove_label (wtp-org#774 option 3 — self-declared writes).
#
# AC coverage:
#   AC-1: add_label posts a comment naming SGE_AGENT_ID and the label added
#   AC-2: remove_label posts a comment naming SGE_AGENT_ID and the label removed
#   AC-3: SGE_AGENT_ID unset -> falls back to hostname (matches
#         post_claim_comment's existing owner-fallback pattern)
#   AC-4: the underlying gh pr edit call still happens even if the
#         attribution comment post fails (best-effort, non-blocking)
#
# Only the function definitions (everything above the CMD dispatcher) are
# sourced — the full script requires a subcommand + PR arg and ends in a
# `case` that calls `exit`, which would kill the test shell if sourced whole.
#
# `gh` is stubbed as a shell function; GH_STUB_ADD_LABEL_RC /
# GH_STUB_COMMENT_RC drive failure-path behaviour. Calls are logged to
# CALL_LOG for assertions.
#
# Run: bash skills/pr-review/pr-labels-attribution.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/pr-labels.sh"
[ -f "$SCRIPT" ] || { echo "FAIL - cannot find $SCRIPT"; exit 1; }

FAILED=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILED=1; }

# Only the functions (stop before the `case "$CMD" in` execution block —
# add_label/remove_label are defined AFTER the CMD/PR arg-parsing lines but
# BEFORE the case block, so the cut point is the case, not the arg parsing).
DISPATCH_LINE=$(grep -n '^case "\$CMD" in' "$SCRIPT" | head -1 | cut -d: -f1)
[ -n "$DISPATCH_LINE" ] || { echo "FAIL - could not find case-dispatch boundary in $SCRIPT"; exit 1; }
FUNCS_ONLY="$(mktemp)"
trap 'rm -f "$FUNCS_ONLY" "$CALL_LOG"' EXIT
head -n "$((DISPATCH_LINE - 1))" "$SCRIPT" > "$FUNCS_ONLY"

CALL_LOG="$(mktemp)"
GH_STUB_ADD_LABEL_RC="${GH_STUB_ADD_LABEL_RC:-0}"
GH_STUB_COMMENT_RC="${GH_STUB_COMMENT_RC:-0}"

gh() {
  echo "$*" >> "$CALL_LOG"
  case "$1 $2" in
    "pr edit")
      return "$GH_STUB_ADD_LABEL_RC" ;;
    "api repos/"*)
      [ "$GH_STUB_COMMENT_RC" -eq 0 ] || return "$GH_STUB_COMMENT_RC"
      echo '{"id":123}' ;;
    "repo view")
      echo "WealthTechPros/sge" ;;
  esac
  return 0
}

run_with() {
  # run_with <agent_id> <fn> <label> -- sources funcs-only, sets PR/GH_REPO,
  # calls <fn> <label>, resets CALL_LOG first.
  local _agent_id="$1" _fn="$2" _label="$3"
  : > "$CALL_LOG"
  (
    PR=1
    GH_REPO="WealthTechPros/sge"
    SGE_AGENT_ID="$_agent_id"
    set -- test 1
    # shellcheck disable=SC1090
    source "$FUNCS_ONLY"
    "$_fn" "$_label"
  )
}

# AC-1: add_label posts attribution naming SGE_AGENT_ID + label
run_with "review-lane-7" add_label "pr-reviewed"
if grep -q 'issues/1/comments' "$CALL_LOG" && grep -q -- '-f' "$CALL_LOG"; then
  pass "AC-1: add_label triggers an attribution comment call"
else
  fail "AC-1: add_label did not call the comments API — log: $(cat "$CALL_LOG")"
fi

# AC-1b: the comment body actually names the agent and the label (re-run,
# capturing the -f body= argument directly rather than just presence).
BODY_CAPTURE="$(mktemp)"
gh() {
  if [ "$1 $2" = "pr edit" ]; then return 0; fi
  if [[ "$1 $2" == "api repos/"* ]]; then
    for a in "$@"; do
      [[ "$a" == body=* ]] && echo "${a#body=}" > "$BODY_CAPTURE"
    done
    echo '{"id":123}'
    return 0
  fi
  [ "$1 $2" = "repo view" ] && { echo "WealthTechPros/sge"; return 0; }
  return 0
}
(
  PR=1; GH_REPO="WealthTechPros/sge"; SGE_AGENT_ID="review-lane-7"
  set -- test 1
  # shellcheck disable=SC1090
  source "$FUNCS_ONLY"
  add_label "pr-reviewed"
)
BODY="$(cat "$BODY_CAPTURE" 2>/dev/null || true)"
if [[ "$BODY" == *"review-lane-7"* && "$BODY" == *"pr-reviewed"* && "$BODY" == *"added"* ]]; then
  pass "AC-1b: comment body names agent 'review-lane-7', action 'added', label 'pr-reviewed'"
else
  fail "AC-1b: comment body missing expected content — got: $BODY"
fi

# AC-2: remove_label posts attribution naming SGE_AGENT_ID + label
: > "$BODY_CAPTURE"
(
  PR=1; GH_REPO="WealthTechPros/sge"; SGE_AGENT_ID="fix-lane-3"
  set -- test 1
  # shellcheck disable=SC1090
  source "$FUNCS_ONLY"
  remove_label "pr-reviewing"
)
BODY="$(cat "$BODY_CAPTURE" 2>/dev/null || true)"
if [[ "$BODY" == *"fix-lane-3"* && "$BODY" == *"pr-reviewing"* && "$BODY" == *"removed"* ]]; then
  pass "AC-2: remove_label comment names agent 'fix-lane-3', action 'removed', label 'pr-reviewing'"
else
  fail "AC-2: remove_label comment missing expected content — got: $BODY"
fi

# AC-3: SGE_AGENT_ID unset -> falls back to hostname (non-empty owner string)
: > "$BODY_CAPTURE"
(
  PR=1; GH_REPO="WealthTechPros/sge"
  unset SGE_AGENT_ID
  set -- test 1
  # shellcheck disable=SC1090
  source "$FUNCS_ONLY"
  add_label "hold"
)
BODY="$(cat "$BODY_CAPTURE" 2>/dev/null || true)"
if [[ -n "$BODY" && "$BODY" != *'`` '* ]]; then
  pass "AC-3: SGE_AGENT_ID unset still produces a non-empty owner (hostname fallback)"
else
  fail "AC-3: expected a hostname-fallback owner, got: $BODY"
fi
rm -f "$BODY_CAPTURE"

# AC-4: label action still succeeds even if the attribution comment POST fails
run_with_comment_fail() {
  : > "$CALL_LOG"
  (
    PR=1; GH_REPO="WealthTechPros/sge"; SGE_AGENT_ID="x"
    GH_STUB_COMMENT_RC=1
    gh() {
      echo "$*" >> "$CALL_LOG"
      case "$1 $2" in
        "pr edit") return 0 ;;
        "api repos/"*) return 1 ;;
        "repo view") echo "WealthTechPros/sge" ;;
      esac
      return 0
    }
    set -- test 1
    # shellcheck disable=SC1090
    source "$FUNCS_ONLY"
    add_label "pr-reviewed"
    echo "exit_code=$?" >> "$CALL_LOG"
  )
}
run_with_comment_fail
if grep -q "^exit_code=0$" "$CALL_LOG"; then
  pass "AC-4: add_label succeeds (exit 0) even when the attribution comment POST fails"
else
  fail "AC-4: add_label should not fail when only the attribution comment fails — log: $(cat "$CALL_LOG")"
fi

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "Some tests FAILED."
  exit 1
fi
