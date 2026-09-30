# Approval carry and update-behind (wtp-org#992 pattern 9)

No model usage: PR Warden keeps approved PRs current under strict up-to-date protection.

No merge queue: with strict up-to-date protection the daemon keeps approved PRs
current itself, at no model cost. Each cycle, before selection:

- **Approval carry** (`REVIEW_DAEMON_APPROVAL_CARRY`, on; `0` disables). A PR
  whose head is a two-parent merge gets the latest trusted PASS carried to the
  new head when the first parent is the reviewed commit, the second parent is
  on the base branch, and the PR's three-dot diff has the same patch content
  (hunk positions and blob ids aside; binary or unreadable diffs fail closed).
  The daemon posts an `approval-carried` verdict review bound to the new head
  and re-applies `pr-reviewed` (remove + add). The PR skips review selection;
  `runs.jsonl` records `decision.action: approval-carried`. A changed diff (a
  conflict resolution, any extra edit) gets the normal delta review.
- **Update-behind** (`REVIEW_DAEMON_UPDATE_BEHIND`, on; `0` disables). The
  oldest approved PR that is BEHIND (not red, not held) is updated via the
  host's update-branch, pinned to its head: at most
  `REVIEW_DAEMON_UPDATE_BEHIND_PER_REPO` (1) per repo per cycle, and none while
  another approved or daemon-updated PR in the repo is still running CI
  (`REVIEW_DAEMON_UPDATE_BEHIND_INFLIGHT_SECONDS`, 3600). Recorded as
  `decision.action: branch-updated`.
- **Merge on pass** accepts an `approval-carried` verdict when its chain reaches
  a full pass; a daemon-armed auto-merge whose head moved is kept (re-bound)
  only when the live head carries an approval directly from the armed head.
