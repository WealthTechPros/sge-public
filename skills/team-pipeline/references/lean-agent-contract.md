# team-pipeline — Lean Agent Contract rules

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

**Rule 1 — Capped reconnaissance.** Orient from ONLY the file-map in the issue's
intake acMap (`refs`, Phase 3c Step 2); **no open-ended searches** (`grep -r`, `find`, `rg --glob`,
recursive reads). Read only file-map files + files you directly edit; if no
file-map, read ≤ 5 files to locate the surface, then build.

**Rule 3 — Cheap inline quality gates only.** Before the final push run ONLY
type-check / static analysis (repo's typecheck per `CLAUDE.md`), the specific
test(s) you wrote or touched, and write-format the files you changed
(discovered per `/sge:pr-fix`; dispatch Rule 3). **Do NOT run** the full test
suite, linter, whole-repo format-check, or build-storybook — those belong to
the separate `/sge:pr-review` step (Phase 3d's full battery).
[Why these rules exist](rationale.md).
