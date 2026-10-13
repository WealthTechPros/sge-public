# Bring a PR branch up to date by MERGING main — never rebase + force-push (sge#2829)

Shared rule for every lane that pushes to an open PR's branch: `/sge:sge-implement`
(author), `/sge:pr-fix` (fix), the `/sge:team-pipeline` impl and fix dispatch
prompts, and `/sge:pr-review` Phase 6.5 direct fixes.

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

**Enforced, not only stated:** `hooks/git-policy-guard.sh` (SPEC-132) denies a rebase of a pushed
branch with an open PR and a force-push to `main` or to any open PR's branch, before the
command runs. A denial is the rule working: merge the base instead. Only a human-set,
logged `SGE_POLICY_OVERRIDE` lets one through.

## Why

PR Warden carries an existing approval forward across a push only when the new
head is a **descendant** of the head it approved and the delta is clean
(the approval carry, #2743 / SPEC-090 §2.6). A merge commit keeps the approved
head in the new head's history, so the approval survives and only the delta is
re-reviewed. A rebase rewrites every commit: the approved head is no longer an
ancestor, the carry cannot apply, and the PR needs a full re-review — the
"failed the merge gate 2–3 times" churn #2829 measured. Force-pushes also
strand any worktree on the old commits (#1666).


## Resolving conflicts without losing good code

Strong models resolve conflicts well and we use them for it. The point of this
section is to make that trust *checkable*, so a wrong resolution cannot land
silently and good code is not lost or regressed. It applies to every lane and
every model; conflict resolution is never handed to a lightweight tier.

1. **Read both sides and the base, not just the markers** (`git diff --merge`,
   `git show :1:<file> :2:<file> :3:<file>`). Decide per hunk: ours, theirs, both,
   or rewritten.
2. **Never resolve wholesale.** No `git checkout --ours|--theirs <file>`, no
   `-X ours|theirs`, no `-s ours`, and no deleting a conflicted hunk to make the
   markers go away. If a whole-file choice is genuinely right, say why in the
   merge body.
3. **A test, assertion, guard, lock or validation present on either side must
   still be present afterwards**, unless the merge body names why it is obsolete.
   Never default a conflicted test file to the side that deletes it.
4. **Diff the result against both parents before the plain push.** After the
   merge commit, the PR's own change must be unchanged except where you resolved
   a conflict on purpose:

   ```bash
   BASE=$(git merge-base HEAD^1 HEAD^2)
   git diff "$BASE" HEAD^1   # the branch's own change BEFORE the merge
   git diff HEAD^2 HEAD      # the branch's own change AFTER the merge
   git diff HEAD^1 HEAD      # what the base brought in PLUS any intentional resolution edits
   ```

   Compare the first two by their actual changes (which files, which added and
   removed lines), not as rendered patch text: base changes shift hunk headers
   and context even when the branch's change is untouched. Any difference must
   be a conflict you resolved on purpose. A line removed from either parent that
   the other side's change does not account for is a regression until explained.
5. **Run the tests of both sides** (the ones the branch added and the ones the
   base added) before pushing. A resolution that needs a test edited to pass is a
   finding, not a fix.
6. **Record it in the merge body**: both parent tips (`HEAD^1`, `HEAD^2`), each
   conflicted file and its decision. Keep git's default merge subject: a custom
   `merge: ...` subject tripped the trailer check (sge#3004, replaced by #3008).
7. **Review reads a conflict-resolution merge as a diff against both parents.**
   A removed test, assertion or guard is a finding. Files where a silent loss is
   expensive (workflows, rulesets and policy, security guards, compliance data)
   get the one adversarial pass the lean flow already allows.

Because the rule is merge-only, every resolution keeps both histories reachable:
a wrong one is repaired by a follow-up commit or a revert, never by rewriting
history. Record the parent tips (item 6) so that is always possible.
