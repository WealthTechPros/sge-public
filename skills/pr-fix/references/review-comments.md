# Resolve blocking review comments

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Resolve blocking review comments

Once CI is green, a PR can still be blocked by unresolved review feedback. Before declaring it ready, address the actionable comments:

```bash
gh api "/repos/{owner}/{repo}/pulls/$1/comments" --paginate \
  --jq '.[] | select(.in_reply_to_id == null) | {id, path, line, body}'
```

For each comment, triage by severity — **must-fix** (bugs, security, missing validation) before merge; **should-fix** (test gaps, clarity) where cheap; **nice-to-have** deferrable. Apply the fix with the Edit tool, then commit the comment-driven fixes together (re-running the pre-push gate), push, and **reply on each thread** stating what changed and in which commit so the reviewer can verify and resolve it. Re-watch CI after the push.

Don't silence a comment by suppressing the check it points at — that's the same anti-pattern as quarantining a test. Fix what the reviewer flagged, or justify the deferral in the reply.

### Address, don't resolve

A review thread is resolved only after its finding is addressed: either fixed in a pushed commit (reply with the SHA and the test or line that proves it) or validly declined with a recorded reason (plus a follow-up issue where the finding is real but out of scope). Never mark a thread resolved just to clear the merge gate or a `threads clear` check, and never request re-review while findings are still open.

Per thread:

1. Read the full thread, including every reply, not just the first comment.
2. Verify the finding against the CURRENT head, not the commit the reviewer saw.
3. Classify it: **fixed**, **declined-with-reason**, or **still-open**.
4. Fix valid findings test-first (a failing test, then the fix), in a pushed commit.
5. Reply on the thread with the SHA and test/line (fixed) or the reason and any follow-up issue (declined).
6. Resolve only threads classified and evidenced in steps 3-5. Leave still-open threads open and say so.

If the user says "resolve the conversations", treat it as "address the findings" and say so in your reply. Clearing threads without a fix needs an explicit named override from the user, and each such thread's reply must flag that it was cleared under that override.

Report back one line per thread with its classification and evidence (SHA, test, reason or follow-up issue).

### Review-findings mode

For an SGE REQUEST_CHANGES verdict, see [references/review-findings-mode.md](review-findings-mode.md).

---
