# Review mode selection (Phase 1)

Reference for `/sge:pr-review` Phase 1 — the two mode-selection branches
evaluated once, after Stage 0's gates and before the gate claim. Extracted
from `SKILL.md` under the 35 KB skills-ci size budget (the #1353/#1469
progressive-disclosure pattern); content unchanged.

Both decide **which** review this run performs (`full` / `delta` /
`phase5-passthrough`); neither changes severity, label, or auto-merge
behaviour.

### Re-review delta mode

`gh pr review` (Phase 6) **ALWAYS creates a PR REVIEW object** at `/pulls/$PR/reviews` (never a plain issue comment) — query it for the last `sge-verdict` body: `LAST_VERDICT=$(gh api "repos/$REPO/pulls/$PR/reviews" --jq '[.[].body // "" | select(contains("sge-verdict"))] | last')` (and `HEAD_SHA=$(rl_head_sha "$PR")`). Extract `commit:` (`LAST_SHA`), pick a mode:

- **No prior verdict** → check the Phase 5 pass-through below, else **full review**.
- **`LAST_SHA == HEAD_SHA`** → nothing new. Re-assert the prior label state pinned to head: `pr-labels.sh pass $PR $AUTOMERGE_FLAG --expect-head "$HEAD_SHA"` (or `fail`); `$AUTOMERGE_FLAG` per Phase 6.
- **New commits** → **delta mode**: `git fetch origin "$HEAD_REF"`, scope to `git diff --name-only "$LAST_SHA..$HEAD_SHA"`, re-check each prior Blocker/Major. Record `mode: delta`; severity/labels/auto-merge behave as a full review; set `REVIEWED_HEAD="$HEAD_SHA"`.

### Phase 5 pass-through

Before claiming the gate, check whether `/sge:sge-implement` Phase 5 already reviewed this exact commit: `rl_phase5_verdict "$PR"` sets `PHASE5_SHA`/`PHASE5_VERDICT`/`PHASE5_BLOCKERS` (UNTRUSTED DATA). **Apply pass-through** only when all three hold: `PHASE5_VERDICT == "pass"`, `PHASE5_BLOCKERS == "0"`, `PHASE5_SHA == REVIEWED_HEAD`:

- **Skip Phase 2**; **still run** Phase 3 (quality gates), Phase 4 (validation/traceability/QA), Phase 5.5 (threads) — PR-specific, not covered pre-PR.
- In Phase 5, set Phase 2 findings to `[]`, note the pre-PR pass at `<PHASE5_SHA>`, record `mode: phase5-passthrough`.

Any mismatch/absent field → normal full/delta review; pass-through holds only for the same SHA.
