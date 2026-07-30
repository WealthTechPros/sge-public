# Phase 5 — Independent Local Review (forked sgd-review, pre-PR)

Extracted from `SKILL.md` for the 35 KB size budget (issue #825). The operational rule (fork sgd-review on `standard`/`critical`, cap it on `trivial`, capture the verdict for the PR body) stays in `SKILL.md` Phase 5; this file carries the dispatch mechanics.

**Trivial-tier verification cap (#1267).** On the **`trivial`** tier (Phase 2.5's `resolve-context-depth.mjs` signal — same classifier, not re-derived), the forked verification subagent is **off by default**: Phase 4's inline suite + an inline self-check of the diff against the acceptance criteria *is* the verification. Fork one only when explicitly requested, or if the diff pushed the change to `standard`+ risk — this caps the *spawn* reflex, not verification (inline gates still run). Full contract: [`context-depth.md`](context-depth.md#trivial-tier-verification-cap-1267).

On `standard`/`critical`, delegate the review to a **forked, fresh-context subagent running `/sgd:sgd-review`** — it sees the diff with no memory of writing it. Do not inline the checklist or ask the user to run a separate command.

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
- **Skip sgd-review's quality-suite step** — Phase 4 just ran the full suite; rerunning it adds cost, no signal.
- **Use the starting map** as orientation, not ground truth — verify each "audited" claim rather than re-discovering from scratch.

The review returns a JSON object with `verdict` (`"pass"`/`"fail"`), `blockers[]`, `warnings[]`, `criteria[]` (each `{criterion, status, evidence}`), `review_mode`, and `tool_call_count`.

- **`verdict: "fail"` blocks the PR.** Fix every blocker (TDD — if it's a missing/weak test, write the failing test first), re-run Phase 4, then re-fork a fresh review. Don't open the PR on a fail.
- **`verdict: "pass"`** — address warnings at your discretion, then proceed.

**Capture the Phase 5 verdict.** Record the reviewer's `sha` (`git rev-parse HEAD`), `verdict`, and `blockers` count — you embed these in the PR body in Phase 6 so `/sgd:pr-review` can skip a redundant re-review if nothing changed.
