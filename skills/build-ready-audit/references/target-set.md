# Step 1 target set and 2B pre-scorer rubric

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Step 1 — resolve the target set

- **Given a selector** — list the open issues it resolves to:

```bash
gh issue list --state open --milestone "<name>" --json number,title,body,labels --limit 100
gh issue list --state open --label "module:<name>" --json number,title,body,labels --limit 100
```

For each issue, fetch the full record once and reuse it across the checks below:

```bash
gh issue view <N> --json number,title,body,labels,milestone,state,url,comments
```

Skip closed issues. If the set is empty, return an empty `results[]` and say so.

When auditing more than a handful of issues, the per-issue checks are
independent — fan them out as **parallel read-only subagents** (one per issue,
or batched), each returning its compact verdict, and consolidate in Step 4. For
one or two issues, run inline.

## 2B pre-scorer rubric

The pre-scorer applies the Phase 2 weighted rubric (models×3 + methods×1 +
routes×2 + scenarios×1) to the raw issue body. It is intentionally conservative:
`AMBIGUOUS` (within ±5 of the Large threshold of 30) passes the gate here and
defers the hard call to `/sge:sge-implement` Phase 2, which scores against the
actual implementation plan rather than raw issue text. Only a **confident**
`LARGE` (score > 35) triggers early decomposition.
