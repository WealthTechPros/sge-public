# sge-implement — `/sge:sge-preflight` return shape

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

```json
{
  "specId": "SPEC-NNN",
  "dependencies": ["..."],
  "openQuestions": ["QD-NN ..."],
  "clarifications": [{"question": "...", "answer": "...", "specSection": "..."}],
  "complexityScore": 0,
  "readyToBuild": true
}
```

`clarifications[]` (preflight Step 2D, #3535): write each answer into the spec's
`## Clarifications` section (dated, one bullet per answer) as the first commit on
the branch. An unanswered clarify question arrives as a `QD-NN` in
`openQuestions[]`: record it in the repo's QD register, and in `--unattended` runs
label the issue `needs-decision` and stop.

After the Phase 2 plan or decomposition exists, and before any code, run
`/sge:sge-preflight --analyze <issue#> [<plan file> | <child issue#>...]` (#3536). A
CRITICAL finding (a Vision non-goal or ADR conflict) or an uncovered criterion stops
Phase 3 until the plan changes, or the spec changes through the change protocol.
