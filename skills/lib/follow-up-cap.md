# Follow-up cap — findings are fixed, recorded or declined, rarely filed (sge#2829)

Shared rule for every lane that produces findings: `/sge:pr-review`,
`/sge:qa-audit` and `/sge:issue-intake` (and the builders' pre-PR checks that
reuse them). Adopted by Rob on 2026-10-03, after a backlog session in which the
pipeline opened 16 new issues while closing 31 — most of them review and intake
minors filed as tracking issues.

## The rule

| Finding | What happens to it |
|---|---|
| **Blocker** / **Major**, in scope | **Fixed in the PR under review.** Never deferred to an issue. |
| **Major**, genuinely out of the PR's scope | May get **one** new issue — at most **one per PR** — and the review names the finding it covers ("files #N for finding 3: …"). File it with `issue-write.sh create-deduped` (searches first, #2647). |
| **Minor** | **Recorded** in the review or PR comment (`recorded-in-review`), **or declined** with a one-line reason (`declined: <reason>`). Never filed as an issue. |

A second out-of-scope major in the same PR is recorded in the review with the
same reasoning, not filed — one issue per PR is the cap.

## How it meets the #859 follow-up gate

`pr-labels.sh pass` still refuses (exit 6) a declared follow-up ("follow-up",
"deferred", "future PR", …) that carries no issue reference, so nothing silently
evaporates when `Fixes #N` closes the issue. A **minor** whose line is marked
`recorded-in-review` (or `recorded in review`) or `declined` already has its
durable home — the review itself — and passes without an issue number. A line
that also names a **major** or **blocker** never qualifies: those are fixed or
filed, so the cap cannot launder one through "declined". Write the disposition
on the same line as the marker, e.g.

```
- minor: rename `parseRow` as a follow-up — recorded-in-review
- minor (declined): extract a shared fixture — declined, the duplication is two lines
```

Tested by `skills/tests/pr-labels-followup-gate.test.sh` (cases 13–16).

## Per lane

- **`/sge:pr-review`** — Phase 6.5 fixes every blocker/major it can; anything
  else goes in the verdict comment's findings table with its disposition. The
  Phase 5.5 "out of scope" thread row follows the same cap.
- **`/sge:qa-audit`** — a failed criterion is a blocker/major for the PR under
  test; QA-only observations (cosmetic, unrelated) are minors recorded in the
  QA report, never filed.
- **`/sge:issue-intake`** — gaps found while mapping acceptance criteria are
  recorded in the intake comment or folded into the recommended scope; intake
  does not file new issues for minors.
