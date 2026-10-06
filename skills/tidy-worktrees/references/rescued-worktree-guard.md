# Mandatory rescued-worktree guard

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Mandatory rescued-worktree guard — rebase onto base + isolated install before any verification claim (issue #951)

A worktree rescued from stale WIP (or resumed from an abandoned session) has two silent failure modes that make its own `tsc`/test output untrustworthy, so a "Push + draft PR" rescue **must not assert any verification result in the PR description until this guard is clean**:

1. **Behind base.** The rescued branch was cut before other work merged; pushing it as-is lets a stale branch merge *behind* main.
2. **Junctioned/shared `node_modules`.** Repos that speed up worktree spawn junction `node_modules` (or a workspace package) from the MAIN checkout. The junction serves main's stale `dist`, so a source change in the worktree never reaches the build — tests fail (or pass) against the wrong tree, and the confusing "wrong value" errors burn ~45 min of misdiagnosis (the ppp payment-price incident that filed this issue: `27500` vs `29900`).

Run the shared guard against the rescued worktree — it answers both questions mechanically (see [`../worktrees/rescue-guard.sh`](../../worktrees/rescue-guard.sh)):

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/worktrees/rescue-guard.sh" assess "<worktree-path>" origin/main
# behind_base:<N|unknown>   shared_node_modules:yes|no   verdict:<...>
# exit 0  -> up-to-date, not shared: safe to push, verification claims trustworthy
# exit 10 -> action required (see verdict); exit 3 -> not a git worktree
```

On a non-`up-to-date` verdict (exit 10), **before `git push`**:

- `needs-rebase` / `needs-rebase-and-isolated-install` → rebase the rescued branch onto the fetched base first: `git -C "<worktree>" fetch origin main && git -C "<worktree>" rebase origin/main` (resolve conflicts, or abort and surface them rather than pushing a stale branch).
- `isolated-install-only` / `needs-rebase-and-isolated-install` → run an **isolated** dependency install *in the worktree* (never reuse the junctioned tree): the repo's install command per its `CLAUDE.md` (e.g. `pnpm install --ignore-workspace` / a fresh non-junctioned `node_modules`), then re-build any workspace package the branch touched.

Re-run the guard until it returns `up-to-date` (exit 0). Only then push and open the draft PR — and state in the PR body that the environment was verified isolated (rebased onto `origin/main`, isolated install run), so `/sge:pr-review` can trust the checklist rather than re-running everything. This is a **default action, not an optional troubleshooting note**.

### Gate the PR state on a real quality run — `verify` (issue #1447)

`assess` proves the tree is *trustworthy to verify* (rebased, not junctioned); it does **not** prove the rescued code compiles/formats/tests. A rescue that clears `assess` can still open a PR with red CI when the branch was committed without an install (real incident: a product repo's #2399 — a rescued worktree opened with 6 red checks: type errors, unformatted files, a genuine logic bug). So once `assess` is clean, run `verify` to decide **ready vs draft**:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/worktrees/rescue-guard.sh" verify "<worktree-path>" "<worktree-path>/CLAUDE.md"
# install:pass|fail|skip  typecheck:…  format:…  test:…   verify:pass | verify:fail:<stage>
# exit 0  -> verify:pass         -> the rescue may open a READY PR
# exit 20 -> verify:fail:<stage> -> open a DRAFT PR with a "CI-unverified (<stage>)" note, never ready
# exit 3  -> not a git worktree
```

`verify` runs the repo's own isolated install + typecheck + format:check + affected tests — discovered from the repo `CLAUDE.md`'s `rescue-verify:<stage>:` marker lines, so it is stack-agnostic and each stage is optional. A repo that declares no markers yields `verify:fail:config` — treat that exactly like a fail (draft PR, note that the suite is undeclared). This makes the "**must not assert any verification result in the PR description until this guard is clean**" rule mechanically enforceable rather than prose: **`verify:pass` is the only gate that lets a rescue push a ready PR.**
