# Bring a PR branch up to date by MERGING main — never rebase + force-push (sge#2829)

Shared rule for every lane that pushes to an open PR's branch: `/sge:sge-implement`
(author), `/sge:pr-fix` (fix), the `/sge:team-pipeline` impl and fix dispatch
prompts, and `/sge:pr-review` Phase 6.5 direct fixes. Adopted by Rob on 2026-10-03.

## The rule

When the PR branch is behind its base (or conflicts with it):

```bash
git fetch origin "$BASE"
git merge --no-edit "origin/$BASE"     # resolve any conflicts — see below
git push origin HEAD                   # a plain, fast-forward push
```

- **Never** `git rebase origin/<base>` on a branch that already has an open PR,
  and **never** `git push --force` / `--force-with-lease` to publish one.
- `gh pr update-branch <PR>` (no `--rebase`) is the server-side equivalent and
  is fine when no local worktree holds the branch (#1666).
- Conflicts are resolved by reading both sides (`/sge:pr-fix` "AI conflict
  resolution"), then `git add` + `git merge --continue`, then a plain push.
- A branch with **no PR yet** (still local) may be rebased — nothing has been
  reviewed on it.

## Why

PR Warden carries an existing approval forward across a push only when the new
head is a **descendant** of the head it approved and the delta is clean
(the approval carry, #2743 / SPEC-090 §2.6). A merge commit keeps the approved
head in the new head's history, so the approval survives and only the delta is
re-reviewed. A rebase rewrites every commit: the approved head is no longer an
ancestor, the carry cannot apply, and the PR needs a full re-review — the
"failed the merge gate 2–3 times" churn #2829 measured. Force-pushes also
strand any worktree on the old commits (#1666).
