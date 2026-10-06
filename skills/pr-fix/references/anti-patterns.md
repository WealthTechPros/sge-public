# Anti-patterns — refuse these

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Anti-patterns — refuse these

The general rule: **never suppress a signal to make it green** — fix what the signal points at, in any stack, any toolchain.

- **Skipping, deleting, or quarantining a failing test** (skip/ignore/disabled annotations, commenting it out, marking it flaky) instead of fixing the cause.
- **Type-system escapes** — ignore pragmas, unchecked casts, "any"-style loopholes — to silence a type/static-analysis error. Fix the type.
- **Linter-suppression comments or rule deactivation** (any linter, any language) as a workaround — fix the violation, or configure the rule correctly repo-wide if the lint is genuinely wrong (e.g. honouring an `_`-prefix unused convention).
- **Loosening thresholds** — lowering coverage minimums, raising allowed-warning counts, widening timeouts to mask a race.
- **Conflict resolution that discards a side** — `checkout --ours`/`--theirs` or `merge -X theirs` to clear a conflict without reading it.
- **Force-push or rebase** an open PR's branch — use new commits and merge the base in; a rewrite drops PR Warden's approval carry (#2743, #2829).
- **`--no-verify`** to bypass hooks — investigate the hook (see *Commit conventions* above).
  - Enforced by `hooks/git-policy-guard.sh` (SPEC-132), which denies it before it runs.
- **Marking a check non-blocking to dodge a real failure.** Only make a check non-blocking when it is *structurally* impossible to pass (see below) — never to hide a bug.

---
