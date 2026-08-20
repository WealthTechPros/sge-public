# Invariants gate — a spec's declared invariants get a property test, not just Gherkin examples

The actionable Phase 3/4 **invariants convention** for `/sge:pr-review`, held here to keep the SKILL
body within its size budget — the full mechanics behind the one-line pointer (issue #2253,
methodology spec **SPEC-118**). Nothing here is a new control the SKILL body cannot express; it is
the detail the pointer defers. Mirrors `seam-evidence.md`'s shape verbatim, applied to a different
property (invariants vs. dual-backend seam tests).

## Why (the gap this closes)

A Gherkin scenario proves one **example** passes. It cannot prove anything about an input its
author never enumerated — an off-by-one at a boundary, an ordering assumption that holds for every
hand-picked example but not in general, a numeric invariant (`C1 ≤ Addressable − Exclusions`,
`total = Σ parts`) that a convenient example satisfies by construction while a generated adversarial
input breaks it. Existing quality gates (mutation testing, SPEC-085; test-fidelity, SPEC-070) prove a
line *executed* and that a test *asserts something*; neither proves the assertion holds for the
general case, not just the examples on hand. The invariants gate closes that last gap.

## When the gate fires (declared-invariant detection)

Treat a spec as declaring an invariant obligation when either signal holds:

1. **Authoritative — the spec declares it.** The governing spec (Phase 4.2 traceability) carries a
   `## Invariants` section (`docs/spec-template.md`), listing one or more `id | statement | property`
   rows. Its presence is the author's own classification that a cross-example invariant exists.
   Prefer this — it is deterministic, same as the seam-evidence gate's own preference order.
2. **Mandatory override — a financial/data-integrity path is in the diff.** A diff touching a path
   matching the existing security-sensitive glob (`rl_security_glob_regex` in
   `skills/pr-review/review-lib.sh` — `auth/`, `middleware/`, `token`, `secret`, `config/`, `crypto`,
   `migrat`, `security/`, `secrets/`) already classifies `DIFF_RISK: high` (`rl_diff_risk`'s existing
   `high` leg — no new glob invented here, reused verbatim). On such a diff, a governing spec's
   declared `## Invariants` are **mandatory** evidence, not merely optional coverage — the gate does
   not silently downgrade a financial-path finding the way it would on a low-risk path.

A spec with **no** `## Invariants` section is out of scope — neither the section nor the check
applies, and their absence is never a finding (same posture as `## Seam evidence` for a
single-backend surface).

## What the gate checks

For a PR whose diff touches a surface governed by a spec that declares `## Invariants`:

1. **Each declared invariant has a matching property test.** Read the spec's `## Invariants` table
   and, for each row, look for a corresponding property test in the tree (a `fast-check` generator-
   driven test whose name/tag/comment references the invariant's `id`, e.g. `I1`). No matching test
   → **flag**.
2. **The matching test is present, not merely named.** Resolve the reference against the repo
   (`rg`/`grep` for the test name/tag/id). A spec that **names** an invariant's property test that
   the code never grew is worse than silence — it reads as covered. Named-but-absent → **flag**.

**Severity & posture** (identical shape to `seam-evidence.md`'s):

- Governing SGE spec present, `## Invariants` declared, an invariant with **no matching property
  test** present in the tree →
  `{severity:"major", category:"traceability", finding:"spec declares ## Invariants but no matching
  property test present"}`. A `major` does not by itself refuse a `pass`, but it is a fix-inline /
  comment finding the verdict must carry — never silently dropped.
- **No** `## Invariants` section in the governing spec → nothing to check, no finding — same as a
  single-backend surface under the seam-evidence gate.
- **No** governing spec at all (non-SGE repo, or a chore) → not applicable; this gate only evaluates
  against a spec's own declared section.
- Every declared invariant has a present, matching property test → record `invariants_gate: <n>/<n>
  present` in the verdict notes; nothing to flag.
- `.sge/test-map.yml`'s repo-wide `mode:` scalar (`advisory | blocking`) gates enforcement the same
  way SPEC-070's test-fidelity gate reads it: `mode: advisory` downgrades the finding to
  advisory-only (a comment, not a Major in the blocking table); `mode: blocking` keeps it a Major.
  This gate does not add its own per-check key — it defers to the same repo-wide scalar SPEC-070
  already reads (`docs/specs/SPEC-070-test-fidelity-gate.md`).

## Genericisation rule

The shipped skill and template text describe the rule only in structural terms (a declared
invariant, a matching property test) — it names no client or product repo, and the "financial/
data-integrity path" mandatory tier reuses the existing glob rather than inventing a new,
repo-specific one. A downstream repo maps the rule onto its own specs; the methodology stays
portable.
