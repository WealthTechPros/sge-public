# Resolve blocking review comments

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Resolve blocking review comments

Once CI is green, a PR can still be blocked by unresolved review feedback. Before declaring it ready, address the actionable comments:

```bash
gh api "/repos/{owner}/{repo}/pulls/$1/comments" \
  --jq '.[] | select(.in_reply_to_id == null) | {id, path, line, body}'
```

For each comment, triage by severity — **must-fix** (bugs, security, missing validation) before merge; **should-fix** (test gaps, clarity) where cheap; **nice-to-have** deferrable. Apply the fix with the Edit tool, then commit the comment-driven fixes together (re-running the pre-push gate), push, and **reply on each thread** stating what changed and in which commit so the reviewer can verify and resolve it. Re-watch CI after the push.

Don't silence a comment by suppressing the check it points at — that's the same anti-pattern as quarantining a test. Fix what the reviewer flagged, or justify the deferral in the reply.

### Review-findings mode

For an SGE REQUEST_CHANGES verdict, see [references/review-findings-mode.md](review-findings-mode.md).

---
