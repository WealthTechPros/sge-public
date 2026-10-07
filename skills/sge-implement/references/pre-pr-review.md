# Phase 5 — Independent Local Review (forked sge-review, pre-PR)

Extracted from `SKILL.md` for the 35 KB size budget (issue #825). The operational rule (fork sge-review on `standard`/`critical`, cap it on `trivial`, capture the verdict for the PR body) stays in `SKILL.md` Phase 5; this file carries the dispatch mechanics.

**Trivial-tier verification cap (#1267).** On the **`trivial`** tier (Phase 2.5's `resolve-context-depth.mjs` signal — same classifier, not re-derived), the forked verification subagent is **off by default**: Phase 4's inline suite + an inline self-check of the diff against the acceptance criteria *is* the verification. Fork one only when explicitly requested, or if the diff pushed the change to `standard`+ risk — this caps the *spawn* reflex, not verification (inline gates still run). Full contract: [`context-depth.md`](context-depth.md#trivial-tier-verification-cap-1267).

On `standard`/`critical`, delegate the review to a **forked, fresh-context subagent running `/sge:sge-review`** — it sees the diff with no memory of writing it. Do not inline the checklist or ask the user to run a separate command.

**Before dispatching**, build the starting map:

```bash
DEFAULT=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
TOUCHED=$(git diff --name-only "$DEFAULT"...HEAD)
```

Format your "audited, no change needed" notes from Step 3 into a structured block. Pass both to the reviewer in the dispatch prompt:

```
Starting map (verify each claim independently; do not trust blindly):
- Touched files: <TOUCHED list>
- Audited, no change needed: <Phase 3 notes, e.g. "src/foo.ts — verified interface stable, no change needed">
```

Tell the subagent to:
- **Resolve its repo context first (SPEC-057).** A forked subagent's shell state doesn't persist across tool calls, so the review can silently target the wrong repo. State the target repo + worktree path explicitly, and have the reviewer re-enter it atop every `gh`/`git` call via `cd "$(${CLAUDE_PLUGIN_ROOT}/scripts/with-repo-cwd.sh resolve owner/repo)" || exit 1`.
- **Skip sge-review's quality-suite step** — Phase 4 just ran the full suite; rerunning it adds cost, no signal.
- **Use the starting map** as orientation, not ground truth — verify each "audited" claim rather than re-discovering from scratch.

The review returns a JSON object with `verdict` (`"pass"`/`"fail"`), `blockers[]`, `warnings[]`, `criteria[]` (each `{criterion, status, evidence}`), `review_mode`, and `tool_call_count`.

- **`verdict: "fail"` blocks the PR.** Fix every blocker (TDD — if it's a missing/weak test, write the failing test first), re-run Phase 4, then re-fork a fresh review. Don't open the PR on a fail.
- **`verdict: "pass"`** — address warnings at your discretion, then proceed.

**Capture the Phase 5 verdict.** Record the reviewer's `sha` (`git rev-parse HEAD`), `verdict`, and `blockers` count — you embed these in the PR body in Phase 6 so `/sge:pr-review` can skip a redundant re-review if nothing changed.

## Pre-PR adversarial pass (sge#2914)

**Lean flow: PR Warden is the one reviewer.** The builder adds no other review layer before it. There is no skeptic subagent and no advisory pr-review run on the draft PR (both came from sge#2829 and were removed by sge#2914: with the forked `/sge:sge-review` and PR Warden they stacked up to four reviews on one PR).

**The one exception: security- or control-bearing diffs.** When the diff touches auth, secrets or credentials, a permission or policy gate, or a hook, script or CI check that enforces a control, run **one adversarial pass** after the forked `/sge:sge-review` passes and before the PR leaves draft. The `trivial`-tier cap above (#1267) still applies: no extra pass there.

One adversarial pass means a forked, fresh-context subagent is told to *refute* the change, not review it: find the input, path or state where the fix does not hold, and prove each claimed fix with a **reverted-fix test**. Run the change's own regression test(s) against the pre-change revision and confirm they FAIL there. Reuse `/sge:qa-audit --adversarial`'s Step 4 pre-change run for this (a `git worktree add --detach <base-sha>` checkout, the same corpus on both sides, results recorded as `pre_fix_status`/`post_fix_status`) rather than building a second harness. A regression test that also passes on the unfixed code is a **major**: the test proves nothing. Fix its blockers/majors first (TDD, re-run Phase 4), and record or decline its minors per the [follow-up cap](../../lib/follow-up-cap.md). Run it once: don't loop it, and don't add a second reviewer after it.

Record it in the PR body (`<!-- sge-prepr: {"adversarial": "pass|fail|n/a", "reverted_fix": "fails-on-base|passes-on-base|n/a"} -->`) so PR Warden can see what was already tried. Branch updates follow [merge-not-rebase](../../lib/merge-not-rebase.md).

## Phase 5 dispatch rule (moved from SKILL.md)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

**Tiered skip (T0/T1).** `SGE_GOVERNANCE_TIER` `T0`/`T1` → skip this phase **entirely**, no inline substitute; Phase 4 + `/sge:pr-review` cover it. `T2`: unchanged (forked review below; context-depth-`trivial` inline cap applies underneath). Mechanics: [`governance-tier.md`](governance-tier.md); procedure: [`context-depth.md`](context-depth.md#trivial-tier-verification-cap-1267).

On `standard`/`critical`, delegate the review to a **forked, fresh-context subagent running `/sge:sge-review`** (it sees the diff with no memory of writing it) — pass it a starting map (touched files + your "audited, no change needed" notes) to verify, not trust; tell it to resolve its repo context first (SPEC-057) and to skip the quality suite (Phase 4 already ran it). A `verdict: "fail"` blocks the PR (fix every blocker TDD-first, re-run Phase 4, re-fork); on `pass`, capture the reviewer's `sha`/`verdict`/`blockers` for the Phase 6 PR body. Dispatch mechanics, the repo-context resolver, prompt template, and returned JSON shape: [`pre-pr-review.md`](pre-pr-review.md).
