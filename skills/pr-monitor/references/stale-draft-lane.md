# Stale-draft lane (issue #1248)

Reference for `/sge:pr-monitor` — the **fourth leg** of the eligibility scan,
over abandoned draft PRs. Extracted from `SKILL.md` under the 35 KB skills-ci
size budget (the #1353/#1469 progressive-disclosure pattern); content unchanged.

### Stale-draft lane — abandoned drafts are invisible to the whole fleet (issue #1248)

`sge-implement` opens every PR as a **draft**, marked ready only at a run's *end* — so an implementer that dies mid-run strands its PR in draft **forever**, seen by no lane. The #755 carve-out routes it into a full `/sge:pr-review` — wrong and expensive when CI is **already green** (one `gh pr ready` from done), and no help for a red one.

This **fourth leg**: any draft for which `is_stale_draft <pr>` returns 0 — no `pr-reviewing`/`pr-reviewed` label, head older than `STALE_DRAFT_MINUTES` (default **45**), **and** no check in flight — is presumed abandoned. Act via `stale_draft_lane <pr>` (re-guards on `is_stale_draft` — a terminal action must not touch a live draft):

1. **CI green** → `gh pr ready` + loud `WARNING:` log + audit comment; now label-less, it enters the next `fetch_candidate_prs` pool.
2. **CI red / incomplete** → an **idempotent** (per-head-SHA) abandonment comment naming the failing check(s), routing to `/sge:pr-fix` instead of aging invisibly. **Never** auto-readied over red CI.

A draft with a recent commit or a running check is a no-op. Mechanics in [`monitor-lib.sh`](../monitor-lib.sh), covered by `skills/tests/pr-monitor-stale-draft-lane.test.sh`.
