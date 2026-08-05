# sge-implement — Phase 0.5 per-verdict handling (worked prompts)

Verbatim interactive AskUserQuestion prompt templates and per-verdict dispatched
(headless) handling for each governance-trace verdict. The **operational decision
table** — every verdict, its default (proceed/block), the option outcomes, and the
headless behaviour — stays in `SKILL.md` Phase 0.5; this file carries the exact
prompt wording. Every gate remains a real AskUserQuestion, never a dead-end stop.

## Size pre-score — the outermost gate (#1265, #1342)

Before *any* governance work (tier, reuse, or fork), cheaply pre-score the issue
body with the Phase 2 sizing rubric — no fork, no preflight, ≤ 500 tokens of
inline work — via the bundled scorer:

```bash
gh issue view <N> --json body --jq .body | \
  node "${CLAUDE_PLUGIN_ROOT:-.}/skills/lib/issue-prescorer.mjs"
# → { "tier": "SMALL"|"MEDIUM"|"LARGE"|"AMBIGUOUS", "score": N, "signals": {...}, "reason": "..." }
```

The scorer counts extraction signals (models, methods, routes, scenarios) against
the Phase 2 rubric; thresholds and the ±5 confidence margin live in
`skills/lib/issue-prescorer.mjs` (LARGE `score > 35`, AMBIGUOUS `25 ≤ score ≤ 35`
around the Large boundary of 30). Branch on `tier`:

| Tier | Action |
|---|---|
| **`LARGE`** | **Decompose first** via `/sge:decompose-issue`; classify the children **once** through `/sge:build-ready-audit`'s #872 fold — the parent's governance fork is **skipped, not run-then-discarded** (decomposition immediately invalidates it). |
| **`AMBIGUOUS`** | Near the Large/Medium boundary; **fall through to the full sizing + governance sequence** to avoid false early decomposition. |
| **`SMALL`** / **`MEDIUM`** | Fall through to the pre-fork tier gate below unchanged. |

Precedence: **size > tier > reuse > fork.** An empty or unparseable body scores
`AMBIGUOUS` (fail-safe: never falsely decompose), so the gate always falls back to
the full sequence rather than skipping classification.

## Pre-fork tier gate (inline classification)

Before Phase 0.5 forks (or reuses) the full `/sge:governance-trace` — which costs
~73k tokens even to conclude "MATCHES_EXISTING, additive" on a docs-only sign-off
task — tier the issue's *predicted* touched paths and, for a **trivial** tier,
classify inline instead of forking. This reuses the **same** classifier Phase 2.5
already runs; it invents no new tier logic.

### Predict the paths, then tier them

1. **Assemble the predicted path set.** Use the issue's File-map / "Files to
   Create/Modify" if it lists one; otherwise infer the paths its title/body imply.
2. **Run the classifier** (the same one Phase 2.5 Step A uses):

   ```bash
   node "${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-context-depth.mjs" \
     --paths "<comma-separated predicted paths>" --score <Phase 2 complexity score, or 5 if not yet computed>
   ```

   It returns `tier` (`trivial` | `standard` | `critical`) plus per-path
   `classifications` for the audit trail.

3. **Branch on the tier:**
   - **`trivial`** (docs/config/test-only **and** low complexity) → **inline path**
     below. No fork.
   - **`standard`** or **`critical`** → fall through to the full governance-trace
     fork (or the reused front-loaded verdict) in SKILL.md Phase 0.5, unchanged.
     The heavier the change, the more it is worth the full trace.

### Safety — the gate can never under-classify a risky change

These are the classifier's **own** guarantees; the gate inherits them rather than
re-deciding, so it can never be looser than the classifier:

- A **CRITICAL** path (security/auth, DB migrations, multi-tenant / data-isolation)
  makes the whole change `critical` — it can **never** down-tier to inline, mirroring
  the classifier's non-goal guard.
- An **empty or unknown** path set resolves to `standard` (fork), **never** `trivial`
  — an unknown blast radius always gets the full trace, never the cheap path.

So the inline path is only ever reached for genuinely low-risk, docs/config/test-only
work; anything ambiguous or dangerous forks as it did before.

### Inline verdict contract

The inline path must be a drop-in for the fork — Phase 0.5 branches on the **same**
verdict object either way:

- **Emit the same Step-7 shape** `/sge:governance-trace` returns (`verdict`,
  `matchedSpec`, `matchConfidence`, `layers.{capability,feature,spec}`,
  `requirementChanges`, `suggestedSpecStub`, `suggestedCapabilityModelEdit`,
  `nonGoalConflict`, `rationale`, `commentPosted`). Trivial docs/config/test work is
  almost always `MATCHES_EXISTING` (additive) or `NO_SPEC_WARRANTED`.
- **Do the lightweight classification honestly, not by assumption.** Even inline,
  confirm the change is additive against the governing spec/feature (path-mapped
  surfaces resolve via the repo's skills-map, per `/sge:governance-trace` Step 2). If
  the inline check surfaces a requirement change, a non-goal conflict, or a genuine
  capability gap, emit the corresponding **blocking** verdict
  (`MATCHES_EXISTING_MODIFIED` / `NOT_SGE_SCOPE` / `NEEDS_NEW_SPEC`) and hand it to the
  same per-verdict handling below — the tier gate is a cost optimisation, never a way
  to wave work through.
- **Leave the audit trail.** Post the same govtrace comment the fork would (its Step 6
  rules still apply — `MATCHES_EXISTING_MODIFIED` and `NOT_SGE_SCOPE` always comment),
  and note `governance: inline tier-gated (trivial) — full trace not forked` in the
  Phase 3 starting map so the Phase 5 reviewer sees which path ran.
- **Then branch on `verdict` exactly as for a forked verdict** — including the
  low-confidence check below. The inline path changes only *how* the verdict was
  produced, never *what happens* with it.

## Low-confidence check (before branching on verdict)

If `matchConfidence` is `"low"`, treat it as worth a human glance regardless of which verdict came back:

- **Standalone (interactive):** AskUserQuestion — "governance-trace's match is low-confidence: <rationale>. Proceed anyway, or re-check manually?" — Option A: "Proceed" (continue to the verdict branch); Option B: "Let me check the match myself first" (show the matched capability/spec, pause for the human to confirm or correct, then continue); Option C: "Cancel".
- **Dispatched (headless):** do not silently proceed. Write the completion file with `outcome: "blocked"` and `note: "governance-trace: low-confidence match — needs human glance"`, and move to other queued work.

## `MATCHES_EXISTING`

Set `specId = matchedSpec`, continue to **Phase 1** (spec lane). No friction.

## `MATCHES_EXISTING_MODIFIED`

This issue would change an existing spec's stated requirement. `governance-trace`
has already posted the before/after (its Step 6 always comments for this
verdict). Do not proceed silently:

- **Standalone (interactive):** AskUserQuestion — "This issue changes SPEC-NNN's requirement: <clause>. Current: '<current>'. Proposed: '<proposed>'. Proceed?" — Option A: "Yes, update the spec as part of this change" (continue to Phase 1; the clause text is rewritten in Phase 8.1, not just its status); Option B: "No — re-scope the issue instead" (stop, comment asking for re-scope); Option C: "Cancel".
- **Dispatched (headless — team-pipeline, issue-swarm):** do **not** guess. Park the issue by writing the completion file with `outcome: "blocked"` and a one-line `note`, then terminate. A human picks it up from the comment govtrace posted and re-invokes `/sge:sge-implement <n>` interactively.

## `NEEDS_NEW_SPEC`

A real capability gap. `suggestedSpecStub` carries the drafted front-matter +
body; `suggestedCapabilityModelEdit` (when `layers.feature`/`layers.capability`
is `new`) carries the model row that must land alongside it — never approve the
spec stub without its accompanying model edit, or you create an orphan spec.

- **Standalone (interactive):** AskUserQuestion — "This issue needs a new spec: <stub title>. <one-line body summary>.<if suggestedCapabilityModelEdit non-null: ' This also needs a new capability-model entry: <description>.'> How do you want to proceed?" — Option A: "Approve as drafted" (write the spec file **and** the capability-model edit, when present, in the **same** commit with a `Spec: SPEC-NNN` trailer, then continue to **Phase 1** as the just-created spec); Option B: "Edit first" (show the full drafted markdown for both, take edits, then proceed as Option A); Option C: "Cancel".
- **Dispatched (headless — team-pipeline, issue-swarm):** treat as a requirement change — write the completion file with `outcome: "blocked"`; a human approves the stub + model edit later.

## `NO_SPEC_WARRANTED`

Legitimate chore/infra/docs work needing no spec. Continue directly to **0B:
No-spec lane** — the audited fast path.

## `NOT_SGE_SCOPE`

Conflicts with a Vision non-goal, or is feature-shaped work with nowhere to live
in this product's model. `governance-trace` has already posted `nonGoalConflict`.
**Blocked by default**:

- **Standalone (interactive):** AskUserQuestion — "This issue is out of SGE scope: <nonGoalConflict or rationale>. How do you want to proceed?" — Option A: "Re-scope the issue" (stop); Option B: "Override — I have a documented reason this should proceed anyway" (requires typing a reason ≥10 chars; see override mechanics); Option C: "Cancel / close the issue".
- **Dispatched (headless):** never auto-override. Write the completion file with `outcome: "blocked"` and move to other queued work.

  **Override mechanics.** An accepted override uses the trailer system loudly, not bypasses it. Continue to **0B: No-spec lane**, and pass `/sge:commit` the reason prefixed to stay greppable from an ordinary chore override: `SGE-Override: ALL; SCOPE-OVERRIDE: <the human's stated reason>`. Also post a follow-up comment recording who overrode it and why — the override is visible on the issue and in commit history, never a silent bypass.

## `NOT_ONBOARDED`

This repo has no SGE governance artefacts yet. Continue to **0B: No-spec lane**
exactly as `NO_SPEC_WARRANTED` (nothing to trace against), but mention once in
your final summary that `/sge:sge-init` would close this gap for future issues.
