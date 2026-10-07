# Step 5 — field semantics

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

- `verdict` — one of `READY` | `NOT_READY` | `TOO_LARGE` (build-readiness axis).
- `gates` — the four Step-2 results, so the caller can see *why*.
- `specRef` — the `SPEC-NNN` the issue links, or `null`.
- `executionRepo` — the repo the issue **executes** in (Step 2R), resolved from
  the structured `Repo:` / `execution-repo:` body field via
  `scripts/with-repo-cwd.sh issue-repo`. Defaults to the issue's own home
  (tracking) repo when the field is absent. `executionRepoDiffers` is `true`
  only when it is a **different** repo — the signal the dispatch layer
  (`/sge:team-pipeline`, `/sge:fleet-dispatch`) uses to target the worktree /
  `agent-lock` / PR at the execution repo while status/labels stay on the
  tracking issue. A malformed field surfaces as a `dependencies` blocker
  (unresolvable dispatch target).
- `routingVerdict` — the routing label applied to the issue (Step 3R): one of
  `"needs-human"` | `"needs-decision"` | `"superseded"` | `"needs-decomposition"`
  | `"blocked"` | `null`. `null` only for `READY` issues, whose recorded state is
  `sge-ready`. Every non-ready audited issue carries a non-null value —
  `"needs-decomposition"` for `TOO_LARGE`, `"blocked"` when the sole blocker is a
  code dependency — so no audited issue leaves the sweep unlabelled.
- `blockers[]` — the gate keys that failed (`acceptance`, `scope`,
  `openQuestions`, `dependencies`); empty for `READY`.
- `governance` — the folded Step-2G classification (governance axis), carrying
  the passthrough of `/sge:governance-trace`'s Step-7 fields: `verdict` (one of
  `MATCHES_EXISTING` | `MATCHES_EXISTING_MODIFIED` | `NEEDS_NEW_SPEC` |
  `NO_SPEC_WARRANTED` | `NOT_SGE_SCOPE` | `NOT_ONBOARDED` | **`DISPATCH_FAILED`**),
  `matchedSpec`, `matchConfidence`, `layers`, and `requirementChanges[]`.
  **`null`** when `--skip-governance` was passed. `DISPATCH_FAILED` (issue
  #2197) is a sixth, audit-only sentinel — never emitted by
  `/sge:governance-trace` itself — set when the folded dispatch didn't return a
  valid Step-7 verdict (a `NO_TARGET_ISSUE` refusal, a fork error, or a
  malformed response); it carries `matchedSpec: null`, `matchConfidence: null`,
  `layers: null`, and a `dispatchError` string instead of a real classification,
  and must be treated as hold-for-human, never as "governance: clear". This is
  the second, independent axis — a caller now gets both verdicts from one skill
  hop instead of chaining `/sge:governance-trace` separately.

## Second example result (`NOT_READY`)

Moved verbatim from `SKILL.md` Step 5 (a second `results[]` entry):

```json
    {
      "issue": 261,
      "verdict": "NOT_READY",
      "rationale": "No acceptance criteria and no SPEC link (2A)",
      "gates": { "acceptance": false, "scope": true, "openQuestions": true, "dependencies": true },
      "specRef": null,
      "executionRepo": "acme/hub",
      "executionRepoDiffers": false,
      "routingVerdict": "needs-decision",
      "blockers": ["acceptance"],
      "governance": {
        "verdict": "NO_SPEC_WARRANTED",
        "matchedSpec": null,
        "matchConfidence": "high",
        "layers": {
          "capability": { "status": "n/a", "id": null },
          "feature":    { "status": "n/a", "id": null },
          "spec":       { "status": "n/a", "id": null }
        },
        "requirementChanges": []
      }
    }
```
