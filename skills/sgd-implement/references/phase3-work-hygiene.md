# Phase 3 work hygiene — WIP checkpoints and the starting map

Two Phase 3 habits that protect work-in-progress and make the Phase 5 review
cheaper. Both are unconditional; neither depends on the repo or the change type.

## WIP checkpoint on interruption

On a shutdown/timeout/kill mid-slice — or before terminating with uncommitted
changes — commit them as:

```
wip: checkpoint before shutdown
```

with the `SGD-Override: WIP; checkpoint before shutdown` trailer, and **push
before exiting**. The commit may be red; a successor agent picks it up from the
remote. **Never strand uncommitted work when a push is possible** — an unpushed
worktree is invisible to every other lane and is the single most common way a
slice's work is silently lost.

Rationale and the full WIP rule: [`../../worktrees/SKILL.md`](../../worktrees/SKILL.md).

## Track your starting map as you work

When you read a file for context but change nothing, note it — filename plus a
one-line rationale:

```
src/widgets/WidgetCard.tsx — verified CSS shrink chain, no change needed
```

Pass this list to the Phase 5 reviewer. It lets the reviewer **verify your
claims** rather than re-discovering the neighbourhood from scratch, which is
both cheaper and a stronger check: a claim you recorded is one the reviewer can
falsify, whereas a file you silently skipped is one nobody looks at.
