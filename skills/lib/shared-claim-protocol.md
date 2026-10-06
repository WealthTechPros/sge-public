# Shared PR claim protocol

Every agent that touches a PR takes and honours **one** claim. That includes orchestrator sessions, their subagents, `/sge:pr-review`, `/sge:pr-fix`, and the review daemon (PR Warden). This stops two agents from working the same PR at once.

## The claim

| Lane | Label | Taken by | Claim record |
|---|---|---|---|
| `review` | `pr-reviewing` | `pr-labels.sh start-review` (what `/sge:pr-review` runs) | `sge-claim-metadata` comment `{owner, claimedAt, ttl}` |
| `fix` | `pr-fixing` | `pr-labels.sh claim-fix` (what `/sge:pr-fix` runs) | label only; aged by its labelled event against `SGE_FIX_CLAIM_TTL_MIN` (default 30 min) |
| `work` | `agent-working` | `pr-labels.sh claim-work`, to reserve a PR for any other agent work | `sge-claim-metadata` comment `{owner, claimedAt, ttl, lane: "work"}` |

**A claim is live until any of these happens:**
- `claimedAt + ttl` passes with no owner-bound `sge-claim-heartbeat` inside the ttl window;
- the 4 h lifetime ceiling is reached;
- the claim is released.

A label with no live claim record behind it is not a lock.

## Front end: `${CLAUDE_PLUGIN_ROOT}/scripts/pr-claim.sh`

```bash
PC="$SGE_ROOT/scripts/pr-claim.sh"        # SGE_ROOT via scripts/resolve-sge-root.sh
"$PC" check     owner/repo#N --owner "$ME"               # 0 free/mine, 3 held, 1 unreadable
"$PC" take      owner/repo#N --lane work --owner "$ME" [--ttl 3600]   # 3 = refused, back off
"$PC" heartbeat owner/repo#N --owner "$ME"               # at least every ttl seconds
"$PC" release   owner/repo#N --lane work --owner "$ME"
```

- **Refusal:** `take` refuses (exit 3) any live claim held by another owner, in any lane. `check` prints `free`, `mine lane=.. owner=..`, or `held lane=.. owner=.. age=..s`.
- **Concurrent takes:** GitHub comments have no compare-and-swap, so `take --lane work` posts its claim and then re-reads: the **oldest** live work claim wins (comment ids are monotonic, so every racer agrees). A loser exits 3 and withdraws only its own comment; no agent ever deletes another owner's claim comment — a stale one is simply superseded. Only claims from repo OWNER/MEMBER/COLLABORATOR authors, the SGE bots, or logins listed in `SGE_CLAIM_TRUSTED_LOGINS` (e.g. another App's `<slug>[bot]`) compete, so a drive-by commenter cannot park a PR.
- **Trusted readers:** the same trust rule applies to **every** claim reader (`check`, `take`, `release`, `start-review`), not only to the race above. A claim comment from any other author is invisible, so it can neither park the real owner's release nor read as someone else's claim (sge-public#71 review).
- **One claim record per lane:** each lane is read from its own latest trusted claim comment. An orchestrator's `work` claim and its subagent's `review` claim coexist; `check`/`take` refuse on a live foreign claim in any lane, and `release --lane X` only looks at, and only deletes, lane X's claim. `take --lane work` always posts a `lane: "work"` claim, even when the caller already holds a claim in another lane, so `agent-working` is never left without a claim record.
- **Owner id:** `--owner` is the claim owner id. It falls back to `$SGE_AGENT_ID`, then the hostname. Use one stable id per agent, e.g. `orch-<session>/<subagent>`.

## Orchestrators

1. **Before dispatching a subagent onto a PR,** run `check`. On exit 3, pick another PR or wait. Never force past a live claim.
2. **Take the claim yourself** with `take --lane work --owner <id>`. Put the same `<id>` in the subagent's brief, and have it heartbeat on long runs.
3. **Release when the subagent finishes,** on success or failure (use a trap). An abandoned claim self-expires after its ttl.
4. **If the subagent will run `/sge:pr-review` under your work claim,** export `SGE_REVIEW_CLAIM_HANDOFF_OWNER=<id>` in its environment. That is the structural handoff the daemon uses. Otherwise, release the work claim before it starts.

## PR Warden

The review daemon skips, in both its review and fix lanes, any PR that has:
- a live `work` claim by an owner other than itself (the poster must be one of the daemon's trust anchors, or a repo OWNER, MEMBER or COLLABORATOR);
- a fresh `pr-fixing` label.

It re-checks both at dispatch time. An unreadable claim state is skipped for that cycle. See `services/review-daemon-poc/github_adapter.py` `_foreign_lane_claim`.
