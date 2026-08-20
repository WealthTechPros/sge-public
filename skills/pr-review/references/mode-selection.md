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

For a read-only pre-check of this same question — is the PR still covered, and how big is the intervening delta — without claiming the gate or mutating labels, `pr-labels.sh review-coverage $PR` (issue #2294) reports `covered=true|false`, a `scope=delta|substantial` classification (bounded post-review delta vs. a change large enough that the prior review no longer applies at all), and lists the intervening commits by SHA + message. `/sge:pr-monitor` can call this directly when triaging a batch of PRs, before deciding whether to dispatch a full `/sge:pr-review`.

### Phase 5 pass-through

Before claiming the gate, check whether `/sge:sge-implement` Phase 5 already reviewed this exact commit: `rl_phase5_verdict "$PR"` sets `PHASE5_SHA`/`PHASE5_VERDICT`/`PHASE5_BLOCKERS` (UNTRUSTED DATA). **Apply pass-through** only when all three hold: `PHASE5_VERDICT == "pass"`, `PHASE5_BLOCKERS == "0"`, `PHASE5_SHA == REVIEWED_HEAD`:

- **Skip Phase 2**; **still run** Phase 3 (quality gates), Phase 4 (validation/traceability/QA), Phase 5.5 (threads) — PR-specific, not covered pre-PR.
- In Phase 5, set Phase 2 findings to `[]`, note the pre-PR pass at `<PHASE5_SHA>`, record `mode: phase5-passthrough`.

Any mismatch/absent field → normal full/delta review; pass-through holds only for the same SHA.

## Mode flags (issue #754) — `--no-automerge` per SPEC-090

Extracted from `SKILL.md`'s *Usage* section under the same 35 KB budget; content unchanged.

Default = merge-gate owner (claims gate, moves labels, fixes safe issues inline, arms
auto-merge). Three flags narrow it — mechanically enforced (prompt-prose restrictions fail):

| Mode | Gate claim (P2) | Direct fixes (P6.5) | Label transitions (P6) | Auto-merge (P8) | Verdict `mode:` |
|---|---|---|---|---|---|
| **default** | yes | yes (safe/in-scope) | yes | yes | `full` / `delta` / `phase5-passthrough` |
| **`--no-fix`** | yes | **no — findings become comments** | yes | yes | append ` (no-fix)` |
| **`--no-automerge`** | yes | yes | yes | **no** | append ` (no-automerge)` |
| **`--advisory`** | **no** | **no — findings become comments** | **no** | **no** | `advisory` |

**Mechanical backstop:** `--advisory` MUST `export SGE_REVIEW_ADVISORY=1` before any
`pr-labels.sh` call (top of Phase 1) — `pass` then refuses with **exit 4**.

## Invocation notes

Extracted from `SKILL.md`'s *Review modes* section under the same 35 KB budget;
content unchanged.

**`--no-automerge` needs no env guard.** Unlike `--advisory` (which backstops
via `SGE_REVIEW_ADVISORY=1` so subagents inherit the restriction and
`pr-labels.sh pass` refuses with exit 4), `--no-automerge` is expressed purely
by omitting `--auto-merge` from the Phase 8 promote call — it owns the gate and
fixes inline exactly like `default`. See `principles.md` #6/#15.

**Spawning as a subagent — pass the PR number positionally** (`/sge:pr-review
123`). A prose-only dispatch ("review PR 123") leaves `$1` unbound, and the
skill falls back to a current-branch `gh pr view` — which in a subagent or a
control session is the wrong PR, or no PR at all.

**Check for an in-flight owner first.** Never race `/sge:sge-implement`'s Phase
7 review for the same PR: two owners racing the `pr-reviewing` claim is the
collision the claim mutex exists to prevent. Detection and back-off:
[`gate-and-termination.md`](gate-and-termination.md#check-for-an-in-flight-owner-first).
