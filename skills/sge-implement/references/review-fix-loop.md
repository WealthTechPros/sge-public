# Phase 7.2 — Review → Fix loop (full procedure)

Moved from `SKILL.md` Phase 7.2 (issue #2825) to keep the SKILL.md under the skills-ci 34 KB warn line. `SKILL.md` keeps the stub with the per-invocation rules (the 3-round bound and the never-suppress rules); the full procedure lives here.

## Review → Fix loop (repeat until clean — bound to 3 rounds)

This is the [bounded refinement loop](../../loops/SKILL.md#c-bounded-refinement-loop) bounded to **3 rounds**: root-cause fixes only (never suppress a finding), re-verify with a fresh review each round, stop-and-report at the bound.

**Review:** invoke `/sge:pr-review`. It claims `pr-reviewing`, runs the native `/code-review` (+ `/security-review` on sensitive paths) plus bundled and repo-specific specialist agents, validates against the linked issue, posts inline findings, and — on a clean pass — swaps `pr-reviewing → pr-reviewed` and enables auto-merge.

**Triage by the gate state, not just the review verb.** On a self-authored PR GitHub forces a `--comment` verdict even with Blockers, so never treat "the `gh pr review` verb was COMMENT" as "clean" — read `/sge:pr-review`'s Blockers/Majors and confirm the label:
- **Clean** — no Blockers/Majors AND `/sge:pr-review` applied `pr-reviewed` (confirm via 7.3) → auto-merge armed, loop done → go to 7.3.
- **Blockers / Major issues / REQUEST_CHANGES** — `/sge:pr-review` closes the gate (`pr-labels.sh fail`, freeing the mutex for the next attempt). You must **fix**, not stop.

**Fix every Blocker and Major** (plus any trivially-correct Minor):
1. Apply the smallest root-cause fix in the worktree. **Never** suppress a check, weaken an assertion, or delete a failing test to make a finding "pass".
2. Keep TDD discipline: if the finding is a missing or weak test, write the failing test first, then fix.
3. Re-run the quality suite (Phase 4) — green.
4. Commit + push each fix via **`/sge:commit`** (plain — it pushes so the PR updates; carries the trailer).
5. Reply to each addressed inline comment with the resolving commit SHA, then **re-run `/sge:pr-review`** for a fresh verdict.

**If it's CI checks (not review findings) that are red**, hand them to `/sge:pr-fix` — it reads live CI, reproduces locally, and applies the smallest root-cause fix without suppressing checks.

Bound the loop to **3 rounds**. If Blockers remain after 3 rounds, **stop**: the gate stays closed (`pr-reviewed` absent), post a summary of unresolved findings, and ask the user how to proceed (AskUserQuestion). **Never** apply `pr-reviewed` to silence a Blocker.
