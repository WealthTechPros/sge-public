# Systematic debugging (issue #3517)

A shared reference, not a skill (no description to spend against the #2917
listing budget). Load it whenever a fix loop starts: `/sge:pr-fix` (red CI),
`/sge:sge-implement` Phases 3-4 (a test or the quality suite goes red) and
Phase 7.2 (a review finding that is a bug), and anything else running the
[bounded refinement loop](../loops/SKILL.md#c-bounded-refinement-loop).
Production incidents have their own playbook (`/sge:prod-reliability-playbook`);
reproducing an issue's claim before routing is
[`reproduce-first.md`](../sge-implement/references/reproduce-first.md).

The failure this prevents: trying one plausible fix after another until
something goes green, without knowing why it was red.

## The four steps

1. **Find the root cause before any fix.** Read the whole error and stack
   trace, not the check name. Reproduce it locally with the narrowest command.
   Check what changed recently (`git log -p` on the failing paths, the base
   branch's new commits). Trace the bad value back through the data flow to
   where it first goes wrong, rather than patching where it surfaces.
2. **Compare against similar code that works.** Find the nearest working
   example (a sibling test, the same call elsewhere, the last green commit) and
   list every difference. The cause is usually among them.
3. **Form one hypothesis and change one variable at a time.** Write the
   hypothesis down ("X fails because Y"), make the single change that tests
   it, and re-run. If it was wrong, undo that change before trying the next.
   Never stack several speculative changes into one attempt.
4. **Fix it with a failing test first.** Write (or identify) a test that fails
   for the root cause, make the smallest fix, and see it pass
   ([`/sge:tdd-workflow`](../tdd-workflow/SKILL.md)). For a bug fix, then run
   the revert-the-fix check below.

A **fix attempt** is one change pushed or run against the failing signal in
the belief that it fixes it. Diagnostic runs that change nothing are not
attempts.

## Three failed fixes: stop and question the design

After **three failed fix attempts at the same problem**, stop. Do not try a
fourth. Three misses mean the model of the problem is wrong, or the design
makes the fix hard: question the design, not the next patch.

How this sits with the existing bounds (it adds a per-problem cap, it does not
replace any of them):

- **A2 comes first.** The #3511 repeat-failure trigger
  ([A2](../../docs/agent-registry.md#opus-advisor-escalation-triggers)) fires
  when the *same* failure (same signature) occurs a second time: a read-only
  opus advisor diagnoses it before the third attempt. So in the usual case,
  attempt 3 is made with the advisor's diagnosis in hand.
- **At strike three, escalate once more, upward.** If A2 already fired for
  this problem, the advisor has been tried: escalate to a human. If A2 never
  fired (each attempt failed with a different signature, so no failure
  repeated), spawn the one read-only opus advisor now, asked about the design
  rather than another patch, and escalate to a human with its answer. A
  session already at opus does the design review itself. If the advisor
  cannot run (opus unavailable, or A2 fired but could not run), record
  "advisor not run" and the reason, and escalate without its answer: a missing
  advisor never blocks the stop.
- **Escalating to a human** means: attended, an AskUserQuestion with the three
  attempts, the failure output of each, the advisor's view and a recommended
  next step; unattended, a SPEC-093 tier (c) BLOCKED report
  (`blockerKind: failed-precondition`) naming the same, then a clean exit
  ([unattended contract](../sge-implement/references/unattended-contract.md)).
- **Tighter loop bounds still win.** `/sge:pr-fix`'s two-tries rule (the same
  fix twice on the same surface) pauses that lane before strike three.
  `/sge:sge-implement` Phase 7's 3 rounds of review→fix bound the whole review
  loop across all findings; the three-strike cap is per problem. Whichever
  bound is hit first stops the loop.
- **Never** weaken, skip or delete the failing check to get out of the loop
  (loops §C). A stop is reported, not hidden.

A new attempt counts toward the same problem until the failing signal changes
for a reason you can explain. A genuinely different failure, after the first
one is fixed, starts its own count.

## Revert-the-fix check

Required for **every bug-fix issue** (#3515), not only security diffs: a `bug`
label, a `fix/` branch, a `--sentry` run, or acceptance criteria that describe
a defect. A regression test that passes with or without the fix proves nothing.

1. With the fix in place, run the regression test(s): they pass.
2. Revert only the production change, keeping the test. The fix is usually
   already committed (each green slice is), so a stash would leave it in
   place. Commit any outstanding work first, then restore the production
   paths from the pre-fix revision: `git checkout <base-sha> --
   <production paths>`. Alternatively, copy the test into a
   `git worktree add --detach <base-sha>` checkout of the pre-fix revision.
3. Run the same test command: it must **fail**, for the reason the bug
   describes (read the failure, not just the exit code).
4. Restore the fix (`git checkout HEAD -- <production paths>`, or remove the
   worktree) and re-run: green. `git status` must then be clean of the
   production paths. If the fix deleted a production file, that path is not
   in HEAD, so delete it again with `git rm -q -f <path>` (or use the
   worktree method for that case).

Record the result in the PR body's `sge-prepr` comment as
`"reverted_fix": "fails-on-base"` (or `passes-on-base`, which is a finding to
fix before review), with the command used. A security- or control-bearing
diff still gets its one adversarial pass
([pre-pr-review](../sge-implement/references/pre-pr-review.md#pre-pr-adversarial-pass-sge2914));
that pass reuses this result instead of repeating it.
