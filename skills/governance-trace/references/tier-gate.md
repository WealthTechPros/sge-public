## Step 0.6: Tier gate — lightweight heuristic for trivial issues

Before entering the expensive Steps 1–5, classify the issue's footprint using
`resolve-context-depth.mjs`. Issues whose body and linked files are exclusively
docs/test/config are handled by a fast inline verdict — no governance-artefact deep-read,
no subprocess fork. Target: ≤ 2 000 tokens, ≤ 10 s elapsed.

**Skip this step** when `--spec` (verify mode) was passed — the caller has already resolved
the spec; go straight to Step 1 / Step 3.

### 0.6a  Extract file paths from the issue body

Scan the preloaded issue body for explicit file or directory paths. Priority sources:

1. A `## File Map` (or `## Files`) section — extract every path-like token on its lines.
2. Inline backtick-quoted paths (`` `path/to/file.ts` ``).
3. Bullet lines beginning with `-` that contain a path.
4. Any token matching `\w[\w/.-]+\.\w{1,6}` (looks like a file path).

Collect the unique paths found into a list (`ISSUE_PATHS`). If none are found, treat
`ISSUE_PATHS` as empty.

### 0.6b  Classify the tier

```bash
TIER_JSON=$(node "${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-context-depth.mjs" \
  --paths "$(printf '%s' "${ISSUE_PATHS[@]}" | paste -sd, -)" 2>/dev/null || echo '{}')
TIER=$(echo "$TIER_JSON" | jq -r '.tier // "standard"')
```

If the command fails, `TIER` is empty, or `ISSUE_PATHS` is empty: set `TIER=standard` and
proceed to Step 1 (full-fork path). Log nothing — this is the safe fallback.

**Also risk-map-gated (proportional-governance proposal).** A `trivial` result from
`resolve-context-depth.mjs` alone is not enough to take the inline path — additionally run
the risk map from `resolve-governance-tier.mjs` (PII, `docs/compliance/**`, trust-fabric
evidence, regulatory-trace, plus `resolve-context-depth.mjs`'s own CRITICAL_RE) over the same
`ISSUE_PATHS`:

```bash
RISK_JSON=$(node "${CLAUDE_PLUGIN_ROOT:-.}/scripts/resolve-governance-tier.mjs" \
  --paths "$(printf '%s\n' "${ISSUE_PATHS[@]}" | paste -sd, -)" --lane no-spec 2>/dev/null || echo '{}')
RISK=$(echo "$RISK_JSON" | jq -r '.risk.level // "unknown"')
```

A `trivial` context-depth tier with `RISK` = `high` (or `unknown`) is **not** eligible for the
inline path even though `resolve-context-depth.mjs` alone would have allowed it — this closes
a real gap: a `docs/compliance/ai-policy.md` edit is `trivial` by extension alone (it is a
`.md` file under no CRITICAL_RE pattern) but is a compliance artefact, not a documentation
change a lightweight heuristic should wave through. `RISK != "low"` forces `TIER=standard` for
0.6c's purposes, overriding whatever `resolve-context-depth.mjs` returned. Rationale:
[`governance-tier.md`](../../sge-implement/references/governance-tier.md#phase-05--fork-skip-and-why-it-stays-narrower-than-t0).

### 0.6c  Branch on tier

| `TIER` value | `RISK` | Action |
|---|---|---|
| `standard` or `critical` | (any) | Proceed to Step 1 (full-fork path). No log entry needed. |
| `trivial` | `high` or `unknown` | Proceed to Step 1 (full-fork path) — risk map overrides. Log: `[tier-gate] trivial paths but risk-map hit — full-fork classification`. |
| `trivial` | `low` | Run **Step 0.6L** (lightweight inline classification) below. |

### Step 0.6L: Lightweight inline classification (trivial tier only)

Apply the following heuristic in order; the first matching rule wins.

**Rule 1 — Test-only.** All `ISSUE_PATHS` match `*.test.*`, `*.spec.*`, `tests/`,
`__tests__/`, or `specs/` patterns, AND the issue body does not describe a new
user-visible product behaviour:
- Verdict: `NO_SPEC_WARRANTED` — test changes never require a governance spec.
- Confidence: `high`.

**Rule 2 — Config-only.** All `ISSUE_PATHS` match config extensions (`*.json`,
`*.yaml`, `*.yml`, `*.toml`, `*.ini`, `*.env`, `*.properties`, `*.lock`):
- Verdict: `NO_SPEC_WARRANTED` — config chores have no user-visible behaviour.
- Confidence: `high`.

**Rule 3 — Docs-only.** All `ISSUE_PATHS` match documentation patterns (`docs/`,
`documentation/`, `*.md`, `*.mdx`, `*.rst`, `*.adoc`, `*.txt`):
- Verdict: `NO_SPEC_WARRANTED` — documentation-only change.
- Confidence: `high`.

**Rule 4 — Mixed trivial.** All `ISSUE_PATHS` are trivial (any combination of
docs/test/config) and the issue body does not describe a behavioural change:
- Verdict: `NO_SPEC_WARRANTED`.
- Confidence: `medium` (human spot-check recommended; set `matchConfidence: "medium"`).

**Rule 5 — LOW_CONFIDENCE (escalate).** `ISSUE_PATHS` are trivial-classified but the
issue body describes a real behavioural change — specifically: the body contains Gherkin
scenarios (`Given`/`When`/`Then`), numbered Acceptance Criteria, or text that clearly
proposes a new user-facing feature or changes existing behaviour:
- Signal: **LOW_CONFIDENCE**. Do **not** emit a lightweight verdict.
- Log (stdout): `[tier-gate] trivial paths but behavioural ACs detected — escalating to full-fork classification`
- Proceed to Step 1 as if the tier gate had not fired. The escalation is silent to
  callers; the Step 7 JSON will contain a standard full-depth verdict with no tier-gate
  marker.

**On a successful lightweight verdict** (Rule 1–4, confidence `high` or `medium`):

Post the Step 6 comment (obeying the same `--no-comment` / always-post rules that apply
to the full-depth path), then return the following Step 7 JSON **immediately** — do **not**
proceed to Steps 1–5:

```json
{
  "issue": <N>,
  "verdict": "NO_SPEC_WARRANTED",
  "capability": null,
  "matchedSpec": null,
  "matchConfidence": "<high|medium>",
  "layers": {
    "capability": { "status": "n/a" },
    "feature":    { "status": "n/a" },
    "spec":       { "status": "n/a" }
  },
  "requirementChanges": [],
  "suggestedSpecStub": null,
  "suggestedCapabilityModelEdit": null,
  "nonGoalConflict": null,
  "rationale": "Trivial-tier issue (<docs|test|config>-only paths). Lightweight classification applied; no governance fork needed.",
  "commentPosted": <true|false>,
  "commentUrl": <url|null>,
  "tierGate": {
    "tier": "trivial",
    "confidence": "<high|medium>",
    "escalated": false,
    "paths": [<ISSUE_PATHS>]
  }
}
```

The `tierGate` field is an additive extension to the standard Step 7 shape; callers that
do not know about it can ignore it. The verdict, layers, and all other fields are
structurally identical to a full-fork result and require no changes in callers (e.g.
`sge-implement` Phase 0.5 routes on `verdict` alone).
