# BDD Quality Rules

Five mandatory rules for all BDD wave agents. Discovered from the 2026-07-17 retroactive wave audit.

---

## Rules

### 1. Never leave a Then vague

Name the exit code, HTTP status, exact output string, or specific field value. "Resolves correctly", "succeeds", "works as expected" are NOT assertions.

**Before (fail):**
```gherkin
Then the request resolves correctly
```

**After (pass):**
```gherkin
Then the response status is 200
And the response body contains field "jobId" with a UUID value
```

---

### 2. Define units for every threshold and SLO inline

Write "within 500 milliseconds" not "within the defined SLO". If threshold is config-driven, assert the config key and value in the Given step.

**Before (fail):**
```gherkin
Then the job completes within the defined SLO
```

**After (pass):**
```gherkin
Given the timeout config key "JOB_TIMEOUT_MS" is set to "500"
Then the job completes within 500 milliseconds
```

---

### 3. Collapse repeated-shape scenarios into Scenario Outline + Examples table

Whenever two or more scenarios differ only in one or two values, use an Outline — eliminates copy-paste drift and makes intent legible.

**Before (fail):**
```gherkin
Scenario: Missing email returns 422
  Given a registration payload without an email field
  Then the response status is 422
  And the error message is "email is required"

Scenario: Missing password returns 422
  Given a registration payload without a password field
  Then the response status is 422
  And the error message is "password is required"
```

**After (pass):**
```gherkin
Scenario Outline: Missing required field returns 422
  Given a registration payload without a <field> field
  Then the response status is 422
  And the error message is "<message>"

  Examples:
    | field    | message              |
    | email    | email is required    |
    | password | password is required |
```

---

### 4. Anchor Given to observable system state, not private bug references

"Given the scenario from issue #656" is invisible to the test runner. Restate the observable precondition the test can actually set up.

**Before (fail):**
```gherkin
Given the edge case described in issue #656
When the import runs
Then it completes without error
```

**After (pass):**
```gherkin
Given a CSV file where the header row contains duplicate column names
When the import runs
Then the response status is 400
And the error message is "duplicate column header: 'amount'"
```

---

### 5. One unhappy-path scenario per happy-path cluster

Every feature must cover at least one failure mode (missing input, unreachable dependency, schema mismatch, permission denied) with a concrete Then — not "fails gracefully" but what the user or caller actually sees.

**Before (fail):**
```gherkin
Scenario: Export succeeds
  Given a valid report configuration
  When the export is triggered
  Then the file is available at the download URL

# (no unhappy path — fails rule 5)
```

**After (pass):**
```gherkin
Scenario: Export succeeds
  Given a valid report configuration
  When the export is triggered
  Then the response status is 202
  And the response body contains field "downloadUrl"

Scenario: Export fails when storage is unreachable
  Given a valid report configuration
  And the storage service returns a 503 error
  When the export is triggered
  Then the response status is 503
  And the error message is "storage unavailable — retry after 60 seconds"
```

---

## Evidence

Audit of wave PRs #1350, #1355, #1356, #1357, #1359, #1365, #1366 (2026-07-17).

Files that required rewrite:

| File | Initial score | Score after applying rules |
|------|--------------|---------------------------|
| SPEC-057 | 5/9 | ~9/9 |
| SPEC-080 | 4/9 | ~9/9 |
| SPEC-077 | 5/9 | ~9/9 |

3 of 26 sampled files scored below 7/9 before rules were applied. All reached ~9/9 after.

---

## See also

- `docs/sgd-build/SPEC-049-*` — BDD traceability harness
- Issue #1367 — `reconcile-worklist --files` (spec ownership dedup)
- `skills/sgd-implement/SKILL.md` — BDD Quality Rules (Phase 1 gate)
- `skills/team-pipeline/references/dispatch-prompts.md` — impl-lane BDD rules
- `docs/spec-template.md` — spec authoring checklist
