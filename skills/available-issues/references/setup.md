# Setup (`--setup`) — claim and worktree procedure

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

`--setup` turns discovery into action for the selected set — it **claims** each chosen issue and creates its worktree, exactly the way `/sge:team-pipeline` Phase 3c does, so the two are interchangeable and never double-claim. The in-repo `.worktrees/issue-N` path below is team-pipeline's documented exception to the canonical sibling `../<repo>-worktrees/<purpose>-<id>` layout — see [`worktrees`](../../worktrees/SKILL.md):

```bash
gh label create "agent-lock" --color "D93F0B" \
  --description "Issue claimed by a pipeline agent" 2>/dev/null || true

WORKSPACE_ROOT=$(git rev-parse --show-toplevel)
BRANCH_PREFIX="${SGE_BRANCH_PREFIX:-fix/issue-}"   # default preserves fix/issue-<N>
for ISSUE in $PARALLEL_SAFE; do
  # claim is the mutex — if the label add loses a race, skip and re-derive next run
  gh issue edit "$ISSUE" --add-label "agent-lock" 2>/dev/null \
    || { echo "[Skip] could not claim #$ISSUE"; continue; }
  git -C "$WORKSPACE_ROOT" worktree add \
    "$WORKSPACE_ROOT/.worktrees/issue-${ISSUE}" -b "${BRANCH_PREFIX}${ISSUE}" origin/main \
    || { echo "[Skip] worktree exists for #$ISSUE"; gh issue edit "$ISSUE" --remove-label "agent-lock"; }
done
```

The branch prefix is `SGE_BRANCH_PREFIX` (default `fix/issue-`, so existing behaviour is unchanged when unset). Set `SGE_BRANCH_PREFIX=claude/issue-` for [Claude Code Routine](https://docs.claude.com/en/docs/claude-code/routines)-triggered runs so the Anthropic-hosted sandbox's default `claude/`-only branch-push guardrail stays intact; leave it unset for normal interactive, local, or headless use.

Claiming with the label **before** handing the set out closes the gap where two concurrent discovery runs pick the same issue. Without `--setup`, this skill claims nothing — the caller (or `/sge:team-pipeline`) owns the claim.

## Running across sessions

The ready pool is derived **live** every run from open issues, the `agent-lock` mutex, open branches and PRs, and dependency state — there is no remembered queue. That makes re-entry idempotent: a fresh `/sge:available-issues` after a blocker closes, a PR merges, or a lock releases just produces the now-correct set. For an autonomous picker, wrap `--mode autonomous-next` in a [recurring loop](../../loops/SKILL.md#d-recurring--cross-session-loop) (`/loop <interval> /sge:available-issues --mode autonomous-next`) and stop when it emits `"issue": null`.
