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

## Pre-PR checks — skeptic pass + advisory review (sge#2829)

On **`standard`/`critical` tiers only** (the `trivial`-tier cap above, #1267, still applies — no extra pass there), after the forked `/sge:sge-review` passes and **before** the PR leaves draft for review, the builder runs two more checks and fixes every blocker/major they raise first (TDD, re-run Phase 4):

1. **Adversarial skeptic pass.** A forked, fresh-context subagent is told to *refute* the change, not review it: find the input, path or state where the fix does not hold, and prove each claimed fix with a **reverted-fix test** — run the change's own regression test(s) against the pre-change revision and confirm they FAIL there. Reuse `/sge:qa-audit --adversarial`'s Step 4 pre-change run for this (a `git worktree add --detach <base-sha>` checkout, the same corpus on both sides, results recorded as `pre_fix_status`/`post_fix_status`) rather than building a second harness. A regression test that also passes on the unfixed code is a **major**: the test proves nothing.
2. **`/sge:pr-review "$PR" --advisory`** on the draft PR. Advisory mode never claims the gate, moves a label or arms auto-merge (#754) — it only posts the would-be verdict. Fix its blockers/majors, record or decline its minors per the [follow-up cap](../../lib/follow-up-cap.md), then hand the PR to the real gate.

Record both in the PR body (`<!-- sge-prepr: {"skeptic": "pass|fail", "reverted_fix": "fails-on-base|passes-on-base|n/a", "advisory": "<verdict>"} -->`) so the merge-gate reviewer can see what was already tried. Branch updates during this loop follow [merge-not-rebase](../../lib/merge-not-rebase.md).
