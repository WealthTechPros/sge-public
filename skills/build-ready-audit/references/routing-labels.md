# Step 3R — application rules and label mechanics

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

### Application rules

1. **Exactly one verdict label per non-ready issue.** If the issue already
   carries a different verdict label, remove it before applying the new one —
   verdicts do not stack.
2. **READY issues get no verdict label** — their recorded state is `sge-ready`
   (which they already carry to have entered the audit). An unlabelled READY
   issue gets its label from `/sge:issue-intake`, never from this audit.
3. **TOO_LARGE issues get `needs-decomposition`** — the label already exists on
   this repo and is the recorded state for "route to `/sge:decompose-issue`".
   Leaving them bare would reopen the accumulation gap this step closes: an
   audited oversized issue would be indistinguishable from an unaudited one.
4. **Superseded verdicts must cite the superseding artefact.** When applying
   `superseded`, also post a comment: `Superseded by #<N>` (or
   `Superseded by SPEC-NNN` / `Superseded by PR #NNN`) — the label alone
   is not self-documenting.
5. **No auto-closing.** Closures remain the human owner's call. Applying
   `superseded` records the verdict; it does not close the issue.

### `needs-human` is dual-use — never reset it

`needs-human` predates this step as a **PR auto-merge hold** label, and it is
load-bearing there: `sge-auto-merge.yml`, `hold-gate.yml`,
`.github/scripts/hold-labels.txt`,
`services/review-daemon-poc/github_adapter.py`, and the SPEC-071 regulated
sign-off gate, which applies it as its hold mechanism. Those consumers all read
labels on **pull requests**; this step writes labels on **issues**, so the two
uses coexist without affecting merge behaviour. Its description must name both
uses, and its colour stays `#B60205` so a held PR still looks like a held PR.

This is why the creates below use plain `gh label create` and **never
`--force`**. `--force` turns create-if-missing into reset-to-my-values, which
would silently overwrite the SPEC-071 hold semantics on every repo this audit
ever sweeps.

### Ensure labels exist on the target repo

Before applying a verdict label, ensure it exists. These are create-if-missing:
a create against an existing label fails harmlessly and is discarded, leaving
any established description and colour intact.

```bash
gh label create "needs-human" --repo "$TARGET" --color "B60205" --description "Human hold: on a PR, blocks bot auto-merge; on an issue, triage verdict = needs hands-on human input" 2>/dev/null
gh label create "needs-decision" --repo "$TARGET" --color "FBCA04" --description "Triage verdict: unresolved decision blocks work — resolve before dispatch" 2>/dev/null
gh label create "superseded" --repo "$TARGET" --color "C2E0C6" --description "Triage verdict: superseded by another artefact — see comment for reference" 2>/dev/null
```

### Apply the label

```bash
# Remove any stale routing label, then apply the current one
for old in needs-human needs-decision superseded needs-decomposition; do
  gh issue edit "$N" --repo "$TARGET" --remove-label "$old" 2>/dev/null
done
gh issue edit "$N" --repo "$TARGET" --add-label "$VERDICT_LABEL"
```
