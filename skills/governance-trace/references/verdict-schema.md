# Step 7 — cache-hit shape and field semantics

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

On a **Step 0.5 cache hit**, the same shape is returned from the reused comment, plus a `"cacheReused": true` marker, with `commentPosted: false` and `matchConfidence: "medium"`:

```json
{
  "issue": 4600,
  "repo": "org/repo",
  "verdict": "MATCHES_EXISTING",
  "matchedSpec": "SPEC-027",
  "matchConfidence": "medium",
  "cacheReused": true,
  "commentPosted": false,
  "rationale": "Reused the prior `## Governance trace` verdict — no governance artefact changed since it was posted (Step 0.5)."
}
```

- `issue` / `repo` — the echoed target: `issue` is the positional number this run received, `repo` is the resolved `$TARGET` (`owner/repo`) the classification ran against. Always emitted — dispatchers reject a result that omits the `issue` echo or whose `issue`/`repo` disagrees with what they dispatched (#2452 fork result contract).
- `verdict` — one of `MATCHES_EXISTING`, `MATCHES_EXISTING_MODIFIED`, `NEEDS_NEW_SPEC`, `NO_SPEC_WARRANTED`, `NOT_SGE_SCOPE`, `NOT_ONBOARDED`. This is the routing signal callers branch on — it doesn't change based on this skill's layer-awareness. (`NO_TARGET_ISSUE` is not a classification — it is the hard-stop refusal shape defined under Usage, returned without running any step.)
- `capability` / `matchedSpec` — `null` when none applies to the verdict. Kept as top-level fields (redundant with `layers.capability.id` / `layers.spec.id` when they're `existing`) for callers that only need the routing-relevant id and don't care about the full layer breakdown.
- `matchConfidence` — `high` / `medium` / `low`; dispatchers should treat `low` as worth a human glance even on an otherwise-clean `MATCHES_EXISTING`.
- `layers` — the new, always-present breakdown from Steps 2–5. Each of `capability`/`feature`/`spec` is `{ "status": "new" | "existing" | "edit" | "n/a", "id": "<existing id>" | null, "proposedId"?: "<id this would become>", "name"?: "<for a new feature/capability>" }`. `feature` is `"n/a"` throughout for a two-layer model (Step 2). This is what makes "new capability vs. new feature vs. new spec vs. edit" explicit, always — never collapsed into the flat verdict alone.
- `requirementChanges[]` — populated only for `MATCHES_EXISTING_MODIFIED`; `[]` otherwise.
- `suggestedSpecStub` — populated only for `NEEDS_NEW_SPEC`; `null` otherwise.
- `suggestedCapabilityModelEdit` — populated only when `layers.feature.status == "new"` or `layers.capability.status == "new"` (Step 5); `{ "path": "...", "description": "...", "yaml": "<block(s) to insert>" }`; `null` when the gap is spec-only.
- `nonGoalConflict` — the quoted non-goal, only for `NOT_SGE_SCOPE`; `null` otherwise.
- `commentPosted` / `commentUrl` — whether Step 6 actually posted (and where), so the caller doesn't re-post.
- `cacheReused` — present and `true` only when Step 0.5 short-circuited on a fresh prior comment; absent/`false` on a full-depth run. A caller can treat a `cacheReused` verdict exactly as a fresh one (same routing signal), and `commentPosted` is always `false` for it (the audit comment already existed — no duplicate is posted).

## requirementChanges record

Moved verbatim from `SKILL.md` Step 3.

```json
{ "spec": "SPEC-NNN", "clause": "<short id/quote of the AC being changed>", "current": "<verbatim current text>", "proposed": "<what it would become>" }
```

Quote `current` verbatim from the spec file — never paraphrase what's being replaced; the person reviewing this needs to see the actual before, not a summary of it.
