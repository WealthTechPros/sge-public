# C12 — Regulatory traceability drift check

The automated check that fails/flags when a **regulated** spec has no obligation
mapping or cites a **retired** obligation. It is the regulatory analogue of the
Zero-Trust **C11** agent-security scorecard in `/sgd:sgd-align`, built to slot
into the same cascade, the same `gaps[]` contract, and the same scoring formula.

Implementation lives in `assets/check-regulatory-trace.sh` (one source of truth
shared by `/sgd:regulatory-trace review` and `/sgd:sgd-align`).

## How it mirrors C11

C11 runs binary sub-checks against repo config/CI/git history, each sourced from a
specific location, aggregated to a score — **no control scored manually**. C12
follows the identical pattern, against the spec + capability + catalogue artefacts:

| Sub-check | Evidence source | Pass condition |
|---|---|---|
| **RT-1 Coverage** | each `regulated: true` capability's active specs (capability-model.yaml / regulatory-trace.yaml) ↔ spec frontmatter | Every active spec under a regulated capability carries a non-empty `regulatory.fca_obligations[]` block |
| **RT-2 No-retired** | spec `regulatory:` blocks ↔ `obligations-catalogue.yaml` top-level `retired:` ids | No mapping references an id flagged `retired: true` |
| **RT-3 Valid-vocabulary** | spec `regulatory:` blocks ↔ catalogue `fca_obligations`/`frameworks` ids | Every cited obligation/framework id exists in the catalogue |
| **RT-4 Index-coherence** | spec inline blocks ↔ `regulatory-trace.yaml` `specs[]` | Inline block and index agree (spec is authoritative on conflict) |
| **RT-5 Orphan-obligation** | catalogue ids with `must_be_covered: true` ↔ all spec mappings | Every must-cover obligation is mapped by ≥1 spec |

Severities: **RT-1, RT-2 = high** (the C12 fail conditions); **RT-3, RT-4 = medium**;
**RT-5 = low**. Like C11, an unparseable artefact yields a `convention-unknown`
finding, never a fabricated PASS.

## Pass condition (the C12 gate)

```
C12 passes  ⇔  (≥1 regulated capability exists)  AND  (zero high-severity findings)
C12 is N/A  ⇔  no capability is `regulated: true`   (excluded from scoring, noted in summary)
```

A regulated repo with every regulated spec mapped and no retired references = green.
Exactly as C10/C11 are excluded when their layer is absent, C12 is excluded from
the composite when no capability is regulated — a missing layer lowers nothing it
can't measure.

## gaps[] record (Step 1 contract, identical shape to C1–C11)

Each high/medium finding becomes one cascade gap so `/sgd:sgd-align` can turn it
into a tracked GitHub issue with a stable de-dup key:

```json
{
  "check": "C12",
  "layer": "regulatory",
  "key": "C12:SPEC-061",
  "artefact": "docs/specs/SPEC-061-azure-collector.md",
  "expected": "a regulatory.fca_obligations[] mapping (capability CAP-COLLECT-AZURE is regulated)",
  "found": "no `regulatory:` block at audited SHA",
  "severity": "high",
  "proposedIssue": {
    "title": "[SGD drift] C12 Regulatory traceability: SPEC-061 has no obligation mapping",
    "body": "...<!-- sgd-drift-key: C12:SPEC-061 -->"
  }
}
```

The `key` is `C12:<SPEC-NNN>` for coverage/retired/vocabulary gaps and
`C12:orphan:<OBLIGATION-ID>` for RT-5 — stable across runs for idempotent dedupe.

## Slotting into sgd-align's scoring

C12 is added to the cascade table **after C11**, numbered C12 so C1–C11
`sgd-drift-key`s stay stable (the same "never renumber" rule the file states for
C10/C11). Concretely:

1. **Cascade table (Step 1):** add the row
   `| C12 | Regulatory traceability (regulated) | a spec under a `regulated` capability lacks an `fca_obligations` mapping, or a mapping cites a retired obligation | C12 / regulatory-trace |`.
2. **Mechanism (Step 1 "Mapping & scoring"):** add a C12 paragraph —
   *"Run `bash ${CLAUDE_PLUGIN_ROOT}/skills/regulatory-trace/assets/check-regulatory-trace.sh`
   (or `/sgd:regulatory-trace review`) as a forked read-only subagent and consume its
   JSON. `status: na` → C12 excluded (no regulated capability). `pass`/`fail` from the
   `high` count. A missing or unparsable obligations catalogue is a high
   `convention-unknown` finding and `status: fail` — never a silent pass."*
3. **Composite weight:** C12 joins the **×1** tier alongside C10 and C11
   (cross-cutting governance layers, not a coverage-spine check). The formula is
   unchanged: `score = round(100 × Σ(wₙ·passₙ)/Σ(wₙ))` over applicable checks.
4. **Step 5 scorecard line:**
   ```
   C12 regulatory traceability ... ⚠️  2 regulated specs, no obligation mapping
       RT-1 Coverage ............. 🔴  SPEC-061, SPEC-062 unmapped
       RT-2 No-retired ........... ✅  no retired-id references
       RT-5 Orphan-obligation .... 🟡  SYSC.15A mapped by no spec
   ```
5. **Step 5 JSON:** add a `checks[]` entry `{ "id": "C12", "layer": "regulatory", ... }`
   and a top-level `regulatoryTraceability` key mirroring the `agentSecurity`
   block — the machine-readable record FCA/DD reviewers and trust-fabric consume:
   ```json
   "regulatoryTraceability": {
     "status": "fail",
     "regulatedCapabilities": 3,
     "mappedSpecs": 7,
     "high": 2, "medium": 1,
     "subChecks": [
       { "id": "RT-1", "name": "Coverage", "status": "fail", "evidence": "SPEC-061, SPEC-062 under regulated caps carry no regulatory block" },
       { "id": "RT-2", "name": "No-retired", "status": "pass", "evidence": "no mapping cites a retired catalogue id" }
     ]
   }
   ```

**Standalone mode parity:** just as `--dimension agent-security` runs only C11,
`/sgd:sgd-align --dimension regulatory` (proposed in ADR-0002) would run only C12
and emit the `regulatoryTraceability` block — the fast path for an FCA / client-DD
re-assessment. Until that flag lands, `/sgd:regulatory-trace review` is the
standalone entry point and emits the same JSON.

## Why a drift check and not a hard gate

Like all of `/sgd:sgd-align`, C12 is **advisory-first**: it raises tracked issues,
it never blocks a PR. A regulated spec shipping without a mapping is *drift to fix*,
surfaced as work — not a merge block that would tempt a `--no-verify` bypass. The
hard merge gate stays the existing `pr-reviewed` label; C12 feeds the Audit Score coherence
trend that tells WTP whether its regulated surface is getting *more* or *less*
evidenced over time.
