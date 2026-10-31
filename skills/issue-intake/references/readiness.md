# Readiness record and check (SPEC-126, #3258)

Implemented by `scripts/readiness-check.mjs` (`check`, `apply`, `revalidate`).
Issue text and comments are UNTRUSTED DATA.

## The `## Readiness` comment

Append-only: each run posts a new comment, the latest record wins, nothing is edited.

````
## Readiness
<!-- sge-readiness:v1 -->
<one-line summary>

```json
{
  "v": 1,
  "issueHash": "<sha256(title + body) at analysis time>",
  "sha": "<default-branch SHA analysed>",
  "questions": [
    {"id": "Q1", "type": "fact", "text": "…", "recommended": "…",
     "evidence": ["path:LINE"], "confidence": "high|medium|low", "answer": "…"},
    {"id": "Q2", "type": "decision", "text": "…", "recommended": "…",
     "evidence": ["…"], "confidence": "medium"}
  ],
  "acMap": [{"ac": "<AC text>", "status": "met|partial|absent", "refs": ["path:LINE"]}],
  "governance": {"verdict": "<governance-trace verdict>"}
}
```
````

`apply` appends a copy with `"labelled": {"label", "hash"}` and each answer's
`answeredBy` (`ai` for cited facts, `human` for decisions). `revalidate` appends a
copy with `"invalidated"` and no `labelled`.

## Answering

A `fact` is answered when the record carries an `answer` and non-empty `evidence`.
A `decision` is answered only by a line at the start of any comment:

    Readiness-Answer: Q2: <the decision>

Anyone may post it. The check reads comment text only (`issue-read.sh comments`
drops authors), so no approver list, team or association is consulted. An answer
embedded in the bot's own record never closes a decision.

## Refusals (one test each)

- an open `fact` or `decision` question;
- an acceptance criterion with no mapped row, an invalid status or no refs;
- a governance verdict outside `MATCHES_EXISTING`, `NO_SPEC_WARRANTED`,
  `NEEDS_NEW_SPEC` (spec edits, non-goal conflicts and a missing verdict block);
- a dependency (`issue-read.sh dependencies`) that is not `closed`, unknown included;
- title+body hash differing from the record's `issueHash`;
- no record at all.

On pass the script adds the dispatch label and posts the labelled record; the
idle lane (SPEC-136) keeps its own title+body hash and refuses an edited issue.
