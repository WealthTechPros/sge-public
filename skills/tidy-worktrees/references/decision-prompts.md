# Decision prompts

Ask only after the audit and assessments are in. Recommendation first. In Claude Code use `AskUserQuestion` with **at most 4 questions per call**; make as many calls as needed. Without it (GitHub Copilot on Azure DevOps) print the same options as a numbered list and read the reply (`1`, `1,3`, `none`); treat no reply or anything unclear as keep.

## 1. Merged and superseded: one plan (always first)

Show the plan table (item, kind, PR link or supersession evidence, full tip SHA, literal commands). Options: `1. Remove all A and D (recommended)`, `2. Choose a subset (list numbers)`, `3. Keep everything`. Remote branches: a second question showing the literal `git push origin --delete '<branch>'` lines; local approval does not cover them.

## 2. Draft PRs: one multi-select

"Open draft PRs for these N unmerged branches?" Multi-select with at most `SGE_TIDY_MAX_DRAFT_PRS` (default 10) options, recommended items first. Only items that individually have supersession `live` and an open linked issue appear. Each option label: branch, one-line value, linked issue. Selecting an item authorises: apply the rescued-worktree guard, push the branch, open a **draft** PR that says "Part of #N". It never authorises merge, auto-merge, label changes or force-push. Items over the cap wait for the next run.

## 3. Everything else: batched per-item questions

For B items not selected, and each C item, ask one question each, batched 4 per call:
- B not selected: `Keep (recommended if unsure)` / `Discard (tip SHA recorded)`.
- C `PART-COMPLETE` or in-flight: `Continue (named gap: …)` / `Keep (blocker: …)` / `Checkpoint locally`.
- C `UNCOMMITTED` or `STASH`: `Checkpoint locally (recommended)` / `Keep` / `Discard (these files are lost: …)`.

## Numbered fallback example

```
Merged, safe to remove (7): 1) wt ../r-worktrees/a feat/a 3f2c…  2) branch feat/b 91ab…  …
  [1] Remove all 7 (recommended)   [2] Choose subset   [3] Keep all
Reply with a number.
```
