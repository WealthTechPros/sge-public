#!/usr/bin/env bash
# pr-claim.sh — the shared PR claim protocol for ANY agent (wtp-org#992 item 5).
#
# Orchestrator sessions, their subagents and the review daemon (PR Warden) must
# never work the same PR at once. They share ONE claim: the lane label
# (pr-reviewing / pr-fixing / agent-working) plus the sge-claim-metadata comment
# {owner, claimedAt, ttl, lane} and owner-bound sge-claim-heartbeat comments.
# This script is a thin front end over skills/pr-review/pr-labels.sh's claim
# primitives — it never implements claim logic itself.
#
# Usage:
#   pr-claim.sh check     <owner/repo#N> [--owner ID]
#       prints "free" | "mine lane=.. owner=.." | "held lane=.. owner=.. age=..s"
#       exit 0 = free (or yours), 3 = held by another owner, 1 = unreadable
#   pr-claim.sh take      <owner/repo#N> --lane review|fix|work [--owner ID] [--ttl S]
#       review -> pr-labels.sh start-review   (what /sge:pr-review itself does)
#       fix    -> pr-labels.sh claim-fix      (what /sge:pr-fix itself does)
#       work   -> pr-labels.sh claim-work     (reserve the PR for any other agent work)
#       exit 3 = refused: another owner holds a live claim — back off
#   pr-claim.sh heartbeat <owner/repo#N> [--owner ID]
#       keep a long claim alive (post at least every --ttl seconds)
#   pr-claim.sh release   <owner/repo#N> --lane review|fix|work [--owner ID]
#
# Owner id: --owner, else $SGE_AGENT_ID, else the hostname. Use one stable id per
# agent (e.g. "orchestrator-<session>/<subagent>"). The claim-comment owner, the
# heartbeat owner and the release owner must match.
#
# Handing a work claim to a subagent that then runs /sge:pr-review: start-review
# refuses any live claim it does not own, so export
# SGE_REVIEW_CLAIM_HANDOFF_OWNER=<your owner id> in that subagent's env (the same
# structural handoff the review daemon uses), or release the work claim first.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_LABELS="${SGE_PR_LABELS_SH:-$HERE/../skills/pr-review/pr-labels.sh}"

usage() {
  awk '/^# Usage:/{f=1} /^set -euo/{exit} f{sub(/^# ?/,""); print}' "$0" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
CMD="$1"; TARGET="$2"; shift 2
LANE=""; OWNER="${SGE_AGENT_ID:-}"; TTL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane)  LANE="${2:-}"; shift 2 ;;
    --owner) OWNER="${2:-}"; shift 2 ;;
    --ttl)   TTL="${2:-}"; shift 2 ;;
    *) echo "pr-claim: unknown option '$1'" >&2; usage ;;
  esac
done

if [[ ! "$TARGET" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
  echo "pr-claim: target must be owner/repo#N, got '$TARGET'" >&2
  exit 2
fi
REPO="${BASH_REMATCH[1]}"; PR="${BASH_REMATCH[2]}"
[[ -z "$TTL" || ( "$TTL" =~ ^[1-9][0-9]{0,4}$ && "$TTL" -le 14400 ) ]] || { echo "pr-claim: --ttl must be 1..14400 seconds (the 4 h claim ceiling)" >&2; exit 2; }
[[ -z "$OWNER" || "$OWNER" =~ ^[A-Za-z0-9_./:@-]+$ ]] || { echo "pr-claim: --owner may only contain [A-Za-z0-9_./:@-]" >&2; exit 2; }

export GH_REPO="$REPO"
[[ -n "$OWNER" ]] && export SGE_AGENT_ID="$OWNER"
[[ -n "$TTL" ]] && export SGE_REVIEW_CLAIM_TTL="$TTL"

lane_required() {
  case "$LANE" in
    review|fix|work) ;;
    *) echo "pr-claim: $CMD needs --lane review|fix|work" >&2; exit 2 ;;
  esac
}

case "$CMD" in
  check)
    exec bash "$PR_LABELS" claim-status "$PR"
    ;;
  take)
    lane_required
    case "$LANE" in
      review|fix)
        # start-review / claim-fix each guard their own lane; refuse ANY other
        # live claim (another lane, another owner) first.
        set +e
        ST=$(bash "$PR_LABELS" claim-status "$PR")
        RC=$?
        set -e
        if [[ "$RC" -eq 3 ]]; then
          echo "refusing: PR $TARGET has a live claim ($ST) — back off (wtp-org#992)" >&2
          exit 3
        fi
        [[ "$RC" -eq 0 ]] || exit "$RC"
        if [[ "$LANE" == "review" ]]; then exec bash "$PR_LABELS" start-review "$PR"; fi
        exec bash "$PR_LABELS" claim-fix "$PR"
        ;;
      work) exec bash "$PR_LABELS" claim-work "$PR" ;;
    esac
    ;;
  heartbeat)
    exec bash "$PR_LABELS" heartbeat "$PR"
    ;;
  release)
    lane_required
    case "$LANE" in
      review) exec bash "$PR_LABELS" release-review "$PR" ;;
      fix)    exec bash "$PR_LABELS" release-fix "$PR" ;;
      work)   exec bash "$PR_LABELS" release-work "$PR" ;;
    esac
    ;;
  *) usage ;;
esac
