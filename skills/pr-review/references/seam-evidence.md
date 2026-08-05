# Seam-evidence gate — dual-backend surfaces must name (and ship) a parity/seam test

The actionable Phase 4 **seam-evidence convention** for `/sge:pr-review`, held here to keep the SKILL
body within its size budget — the full mechanics behind the one-line §4.4 pointer (issue #1228,
methodology spec **SPEC-102**). Nothing here is a new control the SKILL body cannot express; it is
the detail the pointer defers.

## Why (the drift this closes)

A surface with **two or more backends behind one interface** — a demo/mock/fixture store AND a
real/warehouse/live data source — drifts silently: the mock path stays green while the real path
rots, because the only tests exercise the mock. SPEC-066 names the same failure — *"green mocks, no
real seam"*. The fix is methodology, not a one-repo lint: the governing spec must **name a
parity/seam test**, and the merge gate must confirm that named test actually exists.

This generalises a co-change lint that some downstream repos already run as a one-repo convention
into the SGE methodology itself. It is stated in **backend-shape terms** (demo/mock vs
real/warehouse) that any repo maps onto its own surfaces — **no client or product repo is named**.

## When the gate fires (dual-backend detection)

Treat a surface as **dual-backend** when either signal holds:

1. **Authoritative — the spec declares it.** The governing spec (Phase 4.2 traceability) carries a
   `## Seam evidence` section (the spec-template rule, `docs/spec-template.md`). Its presence is the
   author's own classification that the surface has ≥ 2 backends. Prefer this — it is deterministic.
2. **Heuristic — the diff shows a backend pair.** The diff adds or edits two implementations of one
   interface distinguishable by a demo/mock/fixture marker versus a real/warehouse/live marker
   (e.g. a `*Demo*`/`*Mock*`/`*Fixture*` provider beside a `*Warehouse*`/`*Real*`/`*Live*` one behind
   a shared type). On a heuristic hit with **no** `## Seam evidence` section in the governing spec,
   the missing section is itself the finding.

A **single-backend** surface is out of scope — neither the section nor the check applies, and their
absence is never a finding (same posture as the `## Reconciliation` rule for non-data-bearing screens).

## What the gate checks

For a PR whose diff touches a dual-backend surface with a governing spec:

1. **The spec names a seam test.** Read the spec's test-evidence / acceptance-criteria section and
   extract the **named** parity or seam test — a **real-state E2E** that exercises the real/warehouse
   backend (not the mock), **or** a **shared-fixture parity** test that runs the same assertions
   against both backends and asserts they agree. No named test → **flag**.
2. **The named test is present in the tree.** Resolve the named path/id against the repo (`test -f`,
   or an `rg`/`grep` for the test name/tag). A spec that **names** a seam test the code never grew is
   worse than silence — it reads as covered. Named-but-absent → **flag**.

**Severity & posture** (consistent with Phase 4.2's advisory-for-non-SGE stance):

- Governing SGE spec present, surface dual-backend, seam test **unnamed or absent** →
  `{severity:"major", category:"traceability", finding:"dual-backend surface: no present parity/seam test"}`.
  A `major` does not by itself refuse a `pass`, but it is a fix-inline / comment finding the verdict
  must carry — never silently dropped.
- **No** governing spec (non-SGE repo, or a chore) → **advisory only**: emit a `minor` note, never a
  blocker — the same reason Phase 4.2 never blocks an untraceable chore.
- Named seam test **present** and resolvable → record `seam_evidence: <test-ref>` in the verdict
  notes; nothing to flag.

## Genericisation rule

The shipped skill and template text describe the rule **only** in backend-shape terms (demo/mock
store versus real/warehouse backend). It names **no** client or product repo. A downstream repo maps
the rule onto its own surfaces; the methodology stays portable.
