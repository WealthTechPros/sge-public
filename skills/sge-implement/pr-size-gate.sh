#!/usr/bin/env bash
# PR size gate (sge#3706, #3684 C1). Run before opening a PR.
#
#   bash pr-size-gate.sh [base]   # base defaults to origin/main
#
# Counts changed lines (added + deleted, binary files ignored) from the merge
# base of <base> and HEAD:
#   <= SGE_PR_WARN_LINES (1500)  -> "ok",    exit 0
#   >  SGE_PR_WARN_LINES          -> "warn",  exit 0 (say so in the PR body)
#   >  SGE_PR_SPLIT_LINES (3000)  -> "split", exit 1 (split before opening)
# An unresolvable base or a non-integer threshold override exits 2: an
# unmeasured diff is never reported as small.
set -uo pipefail

BASE="${1:-origin/main}"
WARN="${SGE_PR_WARN_LINES:-1500}"
SPLIT="${SGE_PR_SPLIT_LINES:-3000}"
for v in "$WARN" "$SPLIT"; do
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "pr-size: threshold override must be a non-negative integer, got '$v'" >&2
    exit 2
  fi
done

if ! git rev-parse --verify -q "$BASE^{commit}" >/dev/null; then
  echo "pr-size: cannot resolve base '$BASE'" >&2
  exit 2
fi
if ! stat="$(git diff --numstat "$BASE...HEAD")"; then
  echo "pr-size: git diff against '$BASE' failed" >&2
  exit 2
fi
n="$(awk '$1 ~ /^[0-9]+$/ { s += $1 + $2 } END { print s + 0 }' <<<"$stat")"

if [ "$n" -gt "$SPLIT" ]; then
  echo "pr-size: $n changed lines: split (over $SPLIT): open smaller PRs, one issue each"
  exit 1
elif [ "$n" -gt "$WARN" ]; then
  echo "pr-size: $n changed lines: warn (over $WARN): note the size and why in the PR body"
else
  echo "pr-size: $n changed lines: ok"
fi
