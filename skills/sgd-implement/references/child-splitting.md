# sgd-implement — splitting an oversized issue into child issues (reference)

Detailed mechanics for the Phase 2 "score > 30 → split into child issues before
implementing" branch. The operational decision (score > 30 splits, and the
fan-out is gated on `/sgd:build-ready-audit`) stays in `SKILL.md` Phase 2; the
taxonomy, `gh issue create` templates, and per-child gating detail live here.

> **Reached two ways (#1265).** Either Phase 2 sizes an already-classified issue as Large, **or** the Phase 0.5 **size pre-score** (the outermost gate) predicts likely-Large from the issue body and routes here **before** paying for the parent's governance fork — a parent fork a decomposition would only invalidate. Both land on the same `/sgd:build-ready-audit` #872 fold below, which classifies the children once; the size pre-score never re-implements per-child classification.

## Splitting into child issues (score > 30)

**Enabler issues** (technical foundation, no user-facing output):
- Data model / migration + types
- Service/module shell + DI/registration
- Verified by: model runs/rolls back, types pass, module resolves

**Story issues** (one vertical slice of user value, TDD):
- Each story = one acceptance criterion or related group
- Each story: failing test → implementation → passing test
- Each story independently mergeable

```bash
gh issue create --title "SPEC-NNN-E1: Enabler — Migration + Types + Service Shell" \
  --label "sgd,enabler" \
  --body "Parent: #PARENT ..."

gh issue create --title "SPEC-NNN-S1: [User-facing capability] (TDD)" \
  --label "sgd,story" \
  --body "Parent: #PARENT\nBlockedBy: #ENABLER ..."
```

> **Spec-ID note:** `SPEC-NNN` is the current convention; legacy `SGD-NNN` is also accepted by the commit-msg hook and trailers.

> **Orchestration note:** implement the children sequentially, enabler first — each story in its own worktree, each running `/sgd:tdd-workflow` for its acceptance criteria.

**Gate the fan-out on `/sgd:build-ready-audit` before dispatching children.** Splitting into children is a fan-out, and a fan-out must not hand under-specified work to an implementation agent. Before starting the sequence, run `/sgd:build-ready-audit <enabler#>,<story#>,…` over the child issues you just created (its #872 Step-2G fold also returns each child's governance verdict in the same pass, so this front-loads classification too — pass each child's `results[].governance` down as `SGD_GOVTRACE_VERDICT` when you dispatch it, and its Phase 0.5 will reuse it instead of re-forking governance-trace):

- **`READY` (with a non-blocking governance verdict)** → implement it in sequence as normal.
- **`NOT_READY` / `TOO_LARGE`** → **skip and report it** — do not dispatch it blindly. A `NOT_READY` child is missing acceptance criteria / has an open question / has an unmet dependency; sharpen it (or resolve the blocker) first. A `TOO_LARGE` child was under-decomposed; route it back through `/sgd:decompose-issue`. Record which children were skipped and why in the parent comment below, so the gap is visible rather than silently swallowed.

After creating child issues: comment on the parent with the full sequence **and the build-ready verdict per child** (which are ready to start vs which were skipped and why), then ask "Start with the enabler?"
