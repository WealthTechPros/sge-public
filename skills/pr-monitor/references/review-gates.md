# Review gates

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Review gates — auto-run `/sge:pr-review`

A lane PR that is `mergeable` but `mergeStateStatus: BLOCKED` is waiting on **review, not CI**. Reviewing is the monitor's job — **run `/sge:pr-review` straight away, without asking first.** Don't report it back as a question; do the review.

**Policy:** a clean automated `/sge:pr-review` **satisfies the review requirement** — no separate human reviewer is required. Carry it through to merge.

```bash
gh pr view "$pr" --json mergeable,mergeStateStatus,reviewDecision,statusCheckRollup
```

Follow through by gate:

- **Label gate** — a required check such as `Require pr-reviewed label` is failing / the merge-gate label is missing. Run `/sge:pr-review "$pr"` — **it owns the label state machine; the monitor never applies `pr-reviewed` itself.** Verify the swap happened:

  ```bash
  "$SGE_ROOT/skills/pr-review/pr-labels.sh" status "$pr"
  # clean pass  → reviewing=false reviewed=true hold=false changes-requested=false
  # failed gate → reviewing=false reviewed=false hold=false changes-requested=true  (findings on the PR carry the detail, the label carries the visible state — issue #2238)
  ```

  If the review passed but `status` doesn't show `reviewed=true`, re-run the review rather than patching labels by hand.
- **Approval gate** — `reviewDecision: REVIEW_REQUIRED`. Run `/sge:pr-review "$pr"`; if clean, **approve** (`gh pr review "$pr" --approve`). The only forced escalation is GitHub's **self-approval** block (you can't approve a PR you authored; `hooks/git-policy-guard.sh` (SPEC-132) also denies the attempt): post the review as a comment and run from a non-author identity or flag the single approval click for the human — the policy is satisfied, only the mechanic isn't.

- **Conversation-resolution gate** — `mergeStateStatus: BLOCKED` with all checks green and review APPROVED (`reviewDecision: APPROVED`, `pr-reviewed` present) means `required_conversation_resolution`: unresolved threads, typically the `github-advanced-security` / skillspector bot on a first-party skill's own instructions (waived at the SkillSpector gate, SPEC-059). Clear ONLY those adjudicated-benign threads:

  ```bash
  "$SGE_ROOT/skills/pr-monitor/resolve-scanner-threads.sh" --pr "$pr"
  # Resolves a thread ONLY if ALL hold: first-comment author is the code-scanning
  # bot, path matches skills/**, the rule class is in the accepted first-party set
  # (.github/skillspector-waivers.json), and an audit-rationale comment is posted
  # first. Else REFUSED. Fails CLOSED on unreadable state. Prints resolved/refused;
  # --dry-run previews.
  ```

  Complements — never weakens — the #717 fail-closed thread gate in `pr-labels.sh`, clearing only benign first-party scanner threads so an adjudicated-false-positive block can merge (issue #1067).

Running the review — and approving, where that's the mechanism — is the sanctioned way through a review gate. **Never `--admin`-merge or delete the gate to clear a lane.**

## Ensure issue-closing linkage (before merge)

Before merging a lane PR, make sure it will **auto-close the issue it implements**. Inspect title, body and branch for the issue it fixes (`fix/issue-729-…`, `feat/sge-039-…`, a number in title/body). If it implements an issue but the body has **no** closing keyword, add `Fixes #N`:

```bash
N=<issue-number>            # the issue this PR implements (from title/body/branch)
BODY=$(gh pr view "$pr" --json body --jq .body)
if ! printf '%s' "$BODY" | grep -qiE "(clos(e|es|ed)|fix(es|ed)?|resolv(e|es|ed))[[:space:]]+#$N([^0-9]|$)"; then
  gh pr edit "$pr" --body "$(printf '%s\n\nFixes #%s' "$BODY" "$N")"
fi
```

Same-repo only — cross-repo `owner/repo#N` won't auto-close (flag for manual close). Only add the keyword when the PR genuinely implements the issue.

---
