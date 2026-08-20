# Step 5 — full scorecard format, JSON schema, gate coverage, and trend persistence

Full mechanism for Step 5's output shape, referenced from `SKILL.md`. Read this before
producing or consuming the Step 5 output.

## Human-readable scorecard

Print a scorecard a CTO can read in ten seconds, **followed by a machine-readable JSON block** (the platform and fleet mode consume the JSON; never emit one without the other):

```
SGE alignment — <repo> @ <audited SHA>
  C1  Vision exists ............. ✅
  C2  MVP classification ........ ✅
  C3  spec_coverage ............. ⚠️  3 orphan capabilities
  C4  built_coverage ............ ⚠️  2 built features, no Gherkin
  C5  scenario→test ............. ⚠️  5 scenarios, no test
  C6  orphan specs/routes ....... ✅
  C7  vision citations .......... ⚠️  4 specs, no success_measure_moved
  C8  stakeholder questions ..... ✅
  C9  cross-repo contracts ...... ✅
  C10 design system (L2) ........ ✅  atomic maturity L2 (Established)
  C11 agent security (Zero-Trust)  4/5 controls passing (80%)
      ZT-1 Least-Agency ......... ✅  no fullcontrol scopes found
      ZT-2 Tool-chaining/Exfil .. ✅  WTP_EMAIL_ALLOWLIST declared in CI
      ZT-3 Prompt Injection ..... ✅  UNTRUSTED DATA annotation present in all 27 skills
      ZT-4 Supply-chain/AI-BOM .. 🔴  sbom/ai-bom.cdx.json absent
      ZT-5 Agent Identity ....... ✅  94% of commits carry Agent-Id: trailer
  C12 regulatory traceability ... ⚠️  2 regulated specs, no obligation mapping
      RT-1 Coverage ............. 🔴  SPEC-061, SPEC-062 unmapped
      RT-2 No-retired ........... ✅  no retired-id references
      RT-5 Orphan-obligation .... 🟡  SYSC.15A mapped by no spec
  C13 spec↔code content drift ... ⚠️  1 spec, code no longer matches stated behaviour
  C14 TDD-evidence rate ......... ⚠️  46/50 merged PRs (92%); 4 test-free, 6 via TDD-override
  C19 per-spec test coverage .... ⚠️  1/8 mapped specs below threshold (SPEC-012 45% < 70%); 3 unmapped (N/A)
  C20 docs coverage ............. ⚠️  14/35 governed artefacts documented (40%); 21 caps/specs undocumented
  ─────────────────────────────────────────
  Composite coherence (Audit Score / AS): 78/100
  Agent Security (Zero-Trust):  4/5 (80%)
  Regulatory traceability:      C12 ⚠️ (2 regulated specs unmapped)
  TDD-evidence rate:            C14 92% (4 test-free fails · 6 TDD-overrides / 50 merged PRs)
  Coverage sub-score (SPEC-060): C19 71.4/100 (line coverage weighted by mapped-source share)
  Docs coverage:                C20 40% (7/28 capabilities · 7/7 specs current-documented)
  Gate coverage (posture):      3/3 gates installed & PR-blocking (100%)  [require-pr-reviewed-label · require-commit-trailer · ai-supply-chain]
  Drift issues:   5 opened · 1 closed · 4 unchanged
  Reconciliation: 3 proposed (2 close · 1 relabel) · 0 applied   [re-run with --apply to action]
  Agent attribution: 2 agents (agent-01JQ8Z7K… ×12, agent-01JQ9A2B… ×3) · 1 unknown
  Cortex maintenance: consolidated 1 derivative (scope network, 6 nodes) · reflect not due (last 2026-06-29)
```

## Machine-readable JSON block

```json
{
  "skill": "sge-align",
  "repo": "<org>/<repo>",
  "sha": "<audited SHA from Run context>",
  "timestamp": "<ISO-8601 UTC>",
  "checks": [
    { "id": "C1", "layer": "L0", "applicable": true, "pass": 1, "fail": 0 },
    { "id": "C3", "layer": "L1→L3", "applicable": true, "pass": 9, "fail": 3 },
    { "id": "C10", "layer": "L2", "applicable": true, "pass": 1, "fail": 0, "signal": "atomic maturity L2 (Established)" },
    { "id": "C11", "layer": "agent-security", "applicable": true, "pass": 4, "fail": 2 },
    { "id": "C12", "layer": "regulatory", "applicable": true, "pass": 5, "fail": 2 },
    { "id": "C13", "layer": "L3↔spine", "applicable": true, "pass": 6, "fail": 1 },
    { "id": "C14", "layer": "process", "applicable": true, "pass": 46, "fail": 4, "overrides": 6, "signal": "46/50 merged PRs test-evidenced (6 via SGE-Override: TDD), 4 test-free" },
    { "id": "C19", "layer": "L3→spine", "applicable": true, "pass": 7, "fail": 1, "coverageSubScore": 71.4, "signal": "7/8 mapped specs at/above threshold; SPEC-012 45% < 70%; 3 specs N/A (not mapped)" },
    { "id": "C20", "layer": "docs-coverage", "applicable": true, "pass": 14, "fail": 21, "docsCoverage": 40, "signal": "14/35 governed artefacts current-documented (7/28 capabilities, 7/7 specs)" }
  ],
  "audit_score": 78,
  "agentSecurity": {
    "score": 80,
    "passing": 4,
    "partial": 0,
    "failing": 1,
    "total": 5,
    "controls": [
      { "id": "ZT-1", "name": "Least-Agency", "status": "pass", "evidence": "no fullcontrol/allsites.manage/allfiles.write scopes in CI config or .env.example" },
      { "id": "ZT-2", "name": "Tool-chaining/Exfil", "status": "pass", "evidence": "WTP_EMAIL_ALLOWLIST declared in .github/workflows/*.yml" },
      { "id": "ZT-3", "name": "Prompt Injection", "status": "pass", "evidence": "UNTRUSTED DATA annotation present in all 27 skills/*/SKILL.md files" },
      { "id": "ZT-4", "name": "Supply-chain/AI-BOM", "status": "fail", "evidence": "sbom/ai-bom.cdx.json absent" },
      { "id": "ZT-5", "name": "Agent Identity", "status": "pass", "evidence": "94% of branch commits carry Agent-Id: trailer (17/18)" }
    ]
  },
  "regulatoryTraceability": {
    "status": "fail",
    "regulatedCapabilities": 3,
    "mappedSpecs": 7,
    "high": 2, "medium": 1,
    "subChecks": [
      { "id": "RT-1", "name": "Coverage", "status": "fail", "evidence": "SPEC-061, SPEC-062 under regulated caps carry no regulatory block" },
      { "id": "RT-2", "name": "No-retired", "status": "pass", "evidence": "no mapping cites a retired catalogue id" }
    ]
  },
  "gateCoverage": {
    "score": 100,
    "installed": 4,
    "partial": 0,
    "missing": 0,
    "totalGates": 4,
    "gates": [
      { "id": "G1", "workflow": "require-pr-reviewed-label", "status": "pass", "evidence": ".github/workflows/require-pr-reviewed-label.yml installed and pull_request-triggered" },
      { "id": "G2", "workflow": "require-commit-trailer", "status": "pass", "evidence": ".github/workflows/require-commit-trailer.yml installed and pull_request-triggered" },
      { "id": "G3", "workflow": "ai-supply-chain", "status": "pass", "evidence": ".github/workflows/ai-supply-chain.yml installed and pull_request-triggered" },
      { "id": "G4", "workflow": "check-tracking-close-keyword", "status": "pass", "evidence": ".github/workflows/check-tracking-close-keyword.yml installed and pull_request-triggered" }
    ]
  },
  "issues": { "opened": 5, "closed": 1, "unchanged": 4, "deferred": 0 },
  "reconciliation": { "proposed": 3, "applied": 0 },
  "agentAttribution": [
    { "agentId": "agent-01JQ8Z7K9X4M2N6P0R3T5V7W9B", "commits": 12, "model": "claude-sonnet-4-6", "skill": "sge-implement", "issue": 283 },  // model ID as of 2026-06-30
    { "agentId": "unknown", "commits": 1 }
  ]
}
```

One `checks[]` entry per C1–C14, C19 and C20 (`applicable: false` with a `reason` when a layer is absent, C10/C11/C12 is N/A, C13 has no spec passing its eligibility test (no surviving path), C14's gate isn't wired / no PRs merged in the window, C19 has no locatable coverage report / no `sourcePaths` in the DAG, or C20 has neither a capability model nor a front-matter-bearing spec); `pass`/`fail` are artefact counts for that check (for C14, `pass`/`fail` are merged-PR counts, not artefacts; for C19 they are mapped-spec counts at/below threshold; for C20 they are documented/undocumented capability+spec counts). The `agentSecurity` key is always present when C11 runs, and `regulatoryTraceability` whenever C12 runs (a `regulated` capability exists) — they are the machine-readable records that CISO / FCA / DORA reviewers consume and that the governance-posture record stores per repo.

## Gate coverage

The **`gateCoverage`** key is the governance-posture fleet metric (parent #740, spec SGD-048): per repo, which of the four standard enforcement workflows (`require-pr-reviewed-label` / `require-commit-trailer` / `ai-supply-chain` / `check-tracking-close-keyword`) are **installed and PR-blocking**. Its single source of truth is `bash ${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/sge-align/assets/check-gate-coverage.sh` (read-only; JSON on stdout; exit `0` = all four installed & PR-blocking, `1` = ≥1 missing/not-blocking, `2` = harness error; optional trusted repo-root as `$1`) — never scored by hand. Each gate is `pass` (workflow present **and** `pull_request`-triggered), `partial` (present but push/schedule-only — installed but incapable of blocking a merge, 0.5 credit), or `fail` (absent); `score = round(100 × (pass + 0.5 × partial) / 4)`. **Unlike C20, gate-coverage does not enter the composite Audit Score** — it is a posture metric that downstream consumers (#838 dashboard, #840 hub tab) render on the one-page fleet view but must not block on. **Honesty note:** the file-only script proves a gate is installed and *capable* of blocking; whether GitHub has it wired as a **required** status check in branch protection is a separate dimension only observable via `gh api repos/:o/:r/branches/main/protection`, owned by SGD-048's live posture scan — the script never fabricates a required-check verdict it cannot see. It runs in default, `--apply`, and fleet per-repo agents alike; in fleet mode the orchestrator aggregates each repo's `gateCoverage` into the org roll-up so gate coverage is part of the fleet one-page view (parent #740 AC).

## Trend persistence — append the scorecard to `docs/sge/drift-trend.jsonl`

**By default, every full sweep appends its Step 5 scorecard JSON as one row** to the canonical trend file **`docs/sge/drift-trend.jsonl`** in the audited repo (create `docs/sge/` if missing), then prints the Audit Score delta against the previous row. Each row is the full scorecard object above, serialized to a single line — the trend-critical fields are `repo`, `sha`, `timestamp`, `audit_score`, and `checks[]` (per-check `id`/`applicable`/`pass`/`fail`). One JSON object per line, append-only, newest last. This file is the **single durable Audit Score record** — `/sge:drift-hillclimb` diffs it (its Step 5 names this same file), and it is what turns the Audit Score from a snapshot into a trend. (The Audit Score is the plugin's per-check governance-coherence rollup, **not** SM-2; the canonical SM-2 is the platform's `coherence_score` composite — see `platform/docs/sgd-build/vision.md`.)

**Re-enter the resolved checkout first.** Shell state (including `cwd`) does
not persist across Bash tool calls, so the Target-repo `cd` from SKILL.md's
Run-context step is already gone by the time this Step 5 call runs. Skipping
this re-entry is exactly how a forked sweep appended its row to the HUB's
`docs/sge/drift-trend.jsonl` instead of the target repo's (issue #1041):
single-repo mode, re-run the same
`cd "$(${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/scripts/with-repo-cwd.sh resolve owner/repo)" || exit 1`
as the first line of this Bash call, fork or not (fleet mode is already in
the correct per-repo checkout — see SKILL.md's Target-repo note).

```bash
mkdir -p docs/sge
trend=docs/sge/drift-trend.jsonl
prev=$(tail -n 1 "$trend" 2>/dev/null | jq -r '.audit_score // .sm2_sample // empty')   # read BEFORE appending (accept the pre-#834 sm2_sample key on legacy rows)
jq -c . "$scorecard_json" >> "$trend"                                   # $scorecard_json = this run's Step 5 JSON
as=$(jq -r '.audit_score // empty' "$scorecard_json")
if [ -n "$prev" ] && [ -n "$as" ]; then printf 'Audit Score %s → %s (%+d)\n' "$prev" "$as" $((as - prev))
else printf 'Audit Score %s (first trend row — nothing to diff yet)\n' "${as:-n/a}"; fi
```

**Skipped** in the standalone `--dimension agent-security` / `--dimension regulatory` / `--dimension skill-quality` modes (mirroring Step 6): their Step 5 JSON carries only the `agentSecurity` / `regulatoryTraceability` / `skillQuality` key — no `audit_score`, no `checks[]` — and appending that partial object would corrupt the documented row shape and silently break the next full sweep's delta print. Only full-sweep scorecards are appended; `audit_score` is an **integer** (the composite is rounded), which is what keeps the shell `$((…))` delta arithmetic safe. Like Step 6, this is a **local file write, not a GitHub mutation** — it runs in default, `--apply`, and fleet per-repo agents alike (fleet agents append in the checkout they audit). The file lives under `docs/`, so it is **committed**: include it via `/sge:commit` as part of the sweep's PR, or as a direct commit where that is the repo's convention. Never leave the row uncommitted-only — an unpushed trend is no trend.
