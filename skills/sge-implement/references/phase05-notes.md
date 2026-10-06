# sge-implement — Phase 0.5 async fork and low-confidence check

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

**Dispatch this fork async (#1264).** On the fork path, `fork-util.mjs register` the handle and proceed through Phase 3 Step 1 (worktree) / Phase 1 / Phase 2.5 reads without blocking on the verdict; JOIN before the first Edit/Write (Phase 3 JOIN gate below). Bash sequence + ordering guarantees: [`orchestration.md`](orchestration.md#bash-sequence--register-and-join).

**Low-confidence check (before branching on verdict).** If `matchConfidence` is `"low"`, treat it as worth a human glance regardless of verdict: **standalone** asks via AskUserQuestion; **headless** does not silently proceed — write the completion file (below) with `outcome: "blocked"` and a low-confidence `note`. [`verdict-handling.md`](verdict-handling.md).
