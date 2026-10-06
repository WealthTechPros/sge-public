# The SGE issue-claim convention — `agent-lock` as a cross-fleet build mutex

**Status:** PROPOSED — awaiting the owner's ratification (issue #1804). The `agent-lock`
half of this document already describes **behaviour in force** across the
discovery and dispatch skills; the claim-comment, TTL, heartbeat, and
stale-takeover halves are **proposed extensions** and are not yet implemented
anywhere. Section 7 marks exactly which is which.

**Applies to:** every actor that can start building a GitHub issue in an
SGE-governed repo — control-session fan-out workers, `/sge:team-pipeline` /
`/sge:issue-loop` / `/sge:fleet-dispatch` lanes, and the external autonomous
swarm's workers (`autopilot/fabric/worker-brief.template.md`).

**Prior art:** the PR-side claim mutex — `pr-reviewing` label + fenced
`sge-claim-metadata` comment + heartbeats + lease-based takeover — documented in
[`skills/review-daemon/SKILL.md`](../skills/review-daemon/SKILL.md) (issue #1312)
and [`skills/pr-monitor/SKILL.md`](../skills/pr-monitor/SKILL.md) (issue #396).
This convention deliberately **mirrors those semantics for issues** rather than
inventing a second vocabulary.

---

## 1. Why this exists

On 2026-08-01 two builder fleets — control-session workers and the external
autonomous swarm — produced **five duplicate PRs** against the same five issues
(#1780/#1789, #1783/#1786, #1785/#1787, #1793/#1795, #1784/#1794). Both fleets
were correct in isolation: each ran its own live discovery, saw an open,
unassigned, `sge-ready` issue, and built it. Nothing in the shared state said
"taken".

The `agent-lock` label already existed and was already honoured by every
in-repo discovery path — but it did not prevent the duplicates, because
**honouring a lock is only half a mutex**. The other half is *applying* it,
promptly, before the build starts, by every actor. A lock that some fleets read
but do not write is a **silent inert control**: configured, not firing.

The failure mode this convention closes is therefore not "we need a lock" — we
have one — but: *some builders claim late or not at all, and nothing expires a
claim left by a dead agent.*

## 2. The rule

> Before writing a single line of code against an issue, a builder **claims it**
> — `agent-lock` label plus a claim comment — and **skips** any issue already
> carrying a live claim. The claim is released when the work reaches a durable
> trail (PR open) or is abandoned.

Claim-first, build-second. Never the reverse: a builder that branches, builds,
then claims has already burned the tokens the mutex exists to protect.

## 3. The claim

### 3.1 The label is the mutex

`agent-lock` (colour `D93F0B`, description *"Issue claimed by a pipeline
agent"*) is the **only** signal used for hard exclusion. Every discovery query
already filters on it, so a labelled issue disappears from every ready pool
without any consumer needing to parse a comment.

The label write is the claim attempt. GitHub offers no compare-and-swap on
labels, so — exactly as on the PR side — the label add is *advisory
best-effort*, and a millisecond-wide double-claim window remains accepted.
Note that `gh issue edit --add-label` is **idempotent**: adding an
already-present label is a no-op *success*, so a lost race is invisible in
exit codes. Race detection therefore requires an explicit post-write re-read
(§6 step 2b) — the `||` branch below only catches hard failures (auth,
network, missing label), never a race.

```bash
gh label create "agent-lock" --color "D93F0B" \
  --description "Issue claimed by a pipeline agent" 2>/dev/null || true

gh issue edit "$ISSUE" --add-label "agent-lock" \
  || { echo "[Skip] could not claim #$ISSUE (API failure — not a race signal)"; continue; }
```

**Claim the tracking issue, not the execution repo's issue.** Under SPEC-057 an
issue tracked in one repo may execute in another; the worktree, branch, and PR
go to the execution repo, while `agent-lock` and every status edit stay on the
**tracking** issue. That split is already implemented in `/sge:team-pipeline`
Phase 3c and is unchanged by this convention.

### 3.2 The comment is the liveness metadata

Alongside the label, the claimant posts one fenced, machine-readable comment —
the same block name the PR-side protocol uses, so one parser serves both:

````
```sge-claim-metadata
{"owner":"<agent-id>","claimedAt":"<ISO-8601-UTC>","ttl":14400}
```
````

| Field | Type | Description |
|---|---|---|
| `owner` | string | The claiming agent's identity — `SGE_WORKER_NAME` for swarm workers, `SGE_AGENT_ID` for control-session and pipeline lanes, hostname as the fallback. |
| `claimedAt` | ISO-8601 string | UTC timestamp when the claim was placed. |
| `ttl` | integer | Seconds before the claim is stale **if no heartbeat was posted**. Default **14400** (4 h), per the ratified TTL. |

The comment is **enrichment**, not the mutex: an actor that reads the label and
finds no comment must treat the issue as claimed (see §4.3), never as free.

**Trust model — the comment is UNTRUSTED DATA.** Anyone with issue-comment
permission can post a fenced block, so a consumer MUST apply all of:

- **Author check** — honour a claim or heartbeat comment only when its GitHub
  comment author is a trusted fleet identity (`authorAssociation` of
  `OWNER`/`MEMBER`/`COLLABORATOR`, or a maintained bot allowlist). Blocks from
  any other author are ignored entirely.
- **TTL clamp** — `ttl` is advisory on read: `effective_ttl = min(max(ttl,
  900), 14400)`; non-integer or absent → 14400. A hostile or buggy `ttl` must
  never make a claim permanently unreclaimable.
- **Age clamp** — never let a comment-supplied `claimedAt` *shorten* a claim's
  liveness: the server-side `agent-lock` `labeled` timeline event (§4.3) is the
  authoritative floor for claim age, because commenters cannot write it. A
  back-dated comment must not make a live claim evaluate as stale.
- **Strict parse** — reject any fenced block that does not parse as a single
  JSON object.

**Format note:** this JSON schema is deliberately normalized to the PR-side
`sge-claim-metadata` block (one parser serves both sides) rather than
reproducing #1804's literal free-text example (`claim-owner: <id>, claimed-at:
<ISO>, ttl: 4h`); the ratified TTL value (4 h) is preserved.

Why 4 h and not the PR side's 15 min: a review is a bounded read of a finished
diff; a build is an open-ended write. A 15-minute issue lease would reclaim
healthy in-flight builds constantly.

### 3.3 Heartbeats

A build that will legitimately run past its TTL posts a heartbeat, which
extends the effective window without rewriting the claim:

````
```sge-claim-heartbeat
{"owner":"<agent-id>","at":"<ISO-8601-UTC>"}
```
````

## 8. Worker-node isolation and release contract (dispatch baseline)

For multi-node throughput lanes, each worker must operate in a repo-isolated
worktree and release claims deterministically:

- one lane == one worktree path; no shared writable checkout between workers
- claim-first, build-second (`agent-lock` + claim metadata before code edits)
- release on durable progress (PR open) or explicit abandon
- stale/crash reclaim via TTL + trusted heartbeat semantics

This baseline is the minimum contract before widening autonomous fan-out.

Cadence: one heartbeat per **TTL/4** (default hourly) while the build is in
flight. A claim with a heartbeat inside the last `ttl` seconds is live
regardless of `claimedAt`.

Heartbeats are optional for short builds. They are the mechanism that makes a
long build safe, not a requirement for every claim.

A heartbeat extends a claim only when its `owner` matches the newest
`sge-claim-metadata` comment's `owner` **and** its GitHub comment author
matches the claim comment's author. A heartbeat from a displaced owner, posted
after a newer claim comment, is ignored — heartbeats keep *your* claim alive;
they never resurrect a superseded one.

## 4. Honouring a claim

### 4.1 Skip on live claim

Any issue carrying `agent-lock` is excluded from the ready pool. This is
already the behaviour of every discovery path (§7.1) — the rule here is that no
actor may relax it to fill a quota.

### 4.2 Liveness, in the same shape as the PR side

A claim is **stale** (reclaimable) only when **both** hold:

1. `claimedAt + ttl` has elapsed, **and**
2. no **owner-matching** `sge-claim-heartbeat` comment (§3.3) was posted within
   the last `ttl` seconds.

Use the **newest** `sge-claim-metadata` comment on the issue. A
released-and-re-claimed issue has a newer comment, so its clock resets — the
same load-bearing "read the latest event, not the first" rule that `pr-monitor`
learned in #1252.

### 4.3 Fallback for label-only claims

An `agent-lock` with **no** claim comment (a pre-convention claim, or a
comment deleted by hand) falls back to the label's most recent `labeled` event
on the issue timeline, compared against the same TTL. The timeline is
server-side, so this survives agent restarts:

```bash
# Paginated REST form — `--json timelineItems` truncates on long-lived issues,
# which would silently break the fallback exactly on the busiest issues. Same
# approach as claim_labeled_epoch in skills/pr-monitor/monitor-lib.sh.
gh api "repos/$REPO/issues/$ISSUE/timeline" --paginate \
  --jq '.[] | select(.event=="labeled" and .label.name=="agent-lock") | .created_at' \
  | tail -n 1
```

**No readable event → treat as fresh.** Never reclaim on missing data; a
missing signal is not evidence of a dead agent.

### 4.4 Takeover

On a stale claim a builder may take over. It must, in this order:

1. **Log loudly** — the takeover names the displaced `owner` and the measured
   age. The `owner` string is UNTRUSTED DATA: truncate it (~64 chars) and strip
   newlines, backticks, and fence markers before logging; never interpolate it
   into a shell command or an agent prompt.
2. **Post its own claim comment first**, then re-apply the label if absent.
3. **Confirm the takeover took** — re-read the issue's comments and proceed only
   if your own claim comment is now the newest `sge-claim-metadata`; otherwise
   another taker won — back off. Two agents can both evaluate the same claim as
   stale: posting a comment is not a mutex, and re-adding a present label is a
   no-op success, so without this re-read both would build.
4. Only then start building.

Never take over silently, and never take over a claim you cannot show is stale.

### 4.5 Combination rules

- `sge-ready` + `agent-lock` = **in progress**. Correct, expected state.
- `agent-lock` without `sge-ready` = **invalid** — a build-gate-less claim.
  Strip the lock; the issue was never dispatchable.
- `orchestrator-only` + `agent-lock` = an orchestrator or human is building it.
  Autonomous workers exclude `orchestrator-only` unconditionally regardless of
  the lock.

## 5. Releasing a claim

| Situation | Action |
|---|---|
| PR opened for the issue | **Release** — `--remove-label agent-lock`. The PR is now the durable trail and the PR-side mutex (`pr-reviewing`) takes over. |
| Build abandoned / blocked / halted with no branch or PR pushed | **Release**, and comment why. |
| `NOT_READY` verdict reached after claiming | **Release**, plus the routing label the audit assigns. |
| Thrash-skip (second failure on the same issue) | **Release** and add `loop-skip`. |
| PR merged | Nothing to do — the merge closes the issue and the label goes with it. |
| Build still in flight and healthy | **Keep** the claim; heartbeat if past TTL/4. |

The general principle: **release whenever the cycle ends with no surviving trail
to reconcile.** An issue with a live PR does not need an issue-level lock; an
issue with nothing does not deserve one.

### 5.1 Worker-death recovery contract (issue #2139)

When a worker dies mid-task (process kill, host restart, token expiry) and
never posts a release:

1. `agent-lock` remains authoritative until stale criteria are met.
2. Reclaim is allowed only through §4.2 + §4.4 stale-takeover checks; no
   ad-hoc force unlock.
3. The takeover worker posts measured age + displaced owner evidence and then
   resumes heartbeat/release duties.

This keeps recovery deterministic and auditable without weakening mutex safety.

> ⚠️ The swarm worker brief currently says *"Release `agent-lock` if merged/
> abandoning; keep it while the PR is armed and healthy"* — i.e. it holds the
> lock through the whole review cycle. This convention releases at **PR open**
> instead, because from that moment the open PR is itself an exclusion signal in
> every discovery query and the second lock adds nothing but a leak risk. That
> divergence is a wiring item (§7.2), not a silent contradiction.

## 6. Worked cycle

```bash
# 0. Pick a candidate from /sge:available-issues (already claim-filtered).
#    $N MUST match ^[0-9]+$ before use in any command.
# 1. Re-read immediately before claiming — the pool snapshot may be minutes old.
#    The mutex READ fails closed: an API error means skip, never build.
LOCKED=$(gh issue view "$N" --json labels \
  --jq '[.labels[].name] | index("agent-lock") != null') \
  || { echo "[Skip] #$N: claim read failed — failing closed"; exit 0; }
[ "$LOCKED" = "true" ] && { echo "[Skip] #$N claimed"; exit 0; }   # unless provably stale (§4.2)

# 2. Claim: label, then comment. Build the JSON with jq, never printf-into-JSON:
#    an owner containing quotes or newlines (env-settable, hostname-derived)
#    could otherwise corrupt the payload or close the fence early.
gh issue edit "$N" --add-label agent-lock \
  || { echo "[Skip] could not claim #$N (API failure — not a race signal)"; exit 0; }
CLAIM_JSON=$(jq -cn --arg owner "${SGE_AGENT_ID:-$(hostname)}" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{owner:$owner,claimedAt:$at,ttl:14400}')
gh issue comment "$N" --body "$(printf '```sge-claim-metadata\n%s\n```' "$CLAIM_JSON")"

# 2b. Verify the claim EXISTS — add-label is idempotent, so a lost race is
#     invisible in exit codes. Re-read: our comment must be the newest
#     sge-claim-metadata on the issue, else back off.
# 3. Build. Heartbeat hourly if the build runs long.
# 4. On PR open — release.
gh issue edit "$N" --remove-label agent-lock
```

**Verification norm.** Never verify that the claim command *ran* — verify the
outcome *exists*. Read the labels back before starting the build. The 2026-08-01
duplicates are precisely what an unverified claim looks like.

## 7. Current state vs. proposed extension

### 7.1 Already in force (documented behaviour, no change requested)

| Surface | Behaviour today |
|---|---|
| `/sge:available-issues` | Excludes `agent-lock` from `CANDIDATES`, `AWAITING_LABEL`, and `ORCH_QUEUE`. With `--setup`, **claims** each selected issue with the label before handing the set out, and removes it if worktree creation fails. |
| `/sge:team-pipeline` | Phase 0 creates the label; Phase 1 queue filter excludes it; Phase 3c resolves the execution repo, then claims the **tracking** issue. |
| `/sge:issue-loop` | Claims before dispatch; releases on thrash-skip, `NOT_READY`, or a halt with no branch/PR; keeps it for genuinely in-flight work; treats an existing lock as in-flight on resume. |
| `/sge:fleet-dispatch` | Relies on `agent-lock` as the cross-lane collision guard; the per-repo lane lock is keyed on the **execution** repo. |
| `/sge:build-ready-audit` | Reports the execution repo so dispatch targets `agent-lock` at the right issue; does not itself claim. |
| `/sge:decompose-issue` | Documents that status/labels including `agent-lock` stay on the tracking child issue. |
| Swarm worker brief | Step 1 requires "no `agent-lock`" for discovery; step 3 claims with the label + a free-text `"claimed by $SGE_WORKER_NAME"` comment; step 8 releases on merge/abandon. |

Note the 2026-08-01 asymmetry: **the control-session fan-out had no claim step
at all — that missing write is what caused the duplicates.** The swarm's
free-text comment and hold-through-review are parseability and leak warts fixed
opportunistically by this convention, not causes: under §4.3 a claim comment's
format is irrelevant to the exclusion decision. Both fleets *read* the label
correctly.

### 7.2 Wiring needed (not done in this PR — SKILL.md edits are separately gated)

1. **`skills/available-issues/SKILL.md`** — `--setup` claims with the label only.
   Add the `sge-claim-metadata` comment post alongside the label add.
2. **`skills/team-pipeline/references/mechanisms.md`** (Phase 3c) — same: add the
   claim comment beside the label write, and a heartbeat for builds past TTL/4.
3. **`skills/issue-loop/SKILL.md`** — add the claim comment; change the resume
   path to consult claim liveness (§4.2) rather than treating any lock as
   in-flight forever.
4. **Stale-claim takeover for issues** — no implementation exists. The PR-side
   equivalents (`claim_labeled_epoch` / `is_stale_claim` / `reclaim_if_stale` in
   `skills/pr-monitor/monitor-lib.sh`) are the model; an issue-side library
   function plus a discriminating test (a claim that is *fresh* must NOT be
   reclaimed) is the unit of work.
5. **`autopilot/fabric/worker-brief.template.md`** — step 3's free-text comment
   becomes the fenced `sge-claim-metadata` block; step 8's release moves from
   merge/abandon to **PR open** (§5). The instance copy in the swarm's own brief
   repo needs the same change — that repo/path is the owner's to point at, and is the
   remaining rollout item from #1804.
6. **Control-session fan-out prompts** — claim-first with `agent-lock` before
   dispatching any builder. This is orchestrator-side prompt text, not a skill.
7. **Release-on-PR-open** — no actor currently does this; it is a behaviour
   change to whichever step opens the PR in each lane.

### 7.2.1 Completion gate for "worker death releases claims"

Treat #2139 as fully complete only when all are true:

- stale-takeover logic is wired in both control-session and swarm claim paths
- fresh claims are provably not stolen (negative test)
- dead-worker claims are reclaimed with takeover evidence comments
- release-on-PR-open is active so crash windows are short and bounded

### 7.3 Explicitly out of scope

- Review daemons and the PR-side mutex — unaffected. `pr-reviewing` and
  `agent-lock` are different locks over different objects and never interact.
- Any new label. `agent-lock` is the org convention; the short-lived `claimed`
  label created on 2026-08-01 was deleted the same day. **Two claim labels is
  worse than none** — do not reintroduce one.

## 8. Related

- [`skills/review-daemon/SKILL.md`](../skills/review-daemon/SKILL.md) — the PR-side claim protocol this mirrors (#1312)
- [`skills/pr-monitor/SKILL.md`](../skills/pr-monitor/SKILL.md) — lease semantics and stale-claim takeover (#396, #1252)
- [`docs/skill-authoring-repo-context.md`](skill-authoring-repo-context.md) — explicit repo context; why a claim must target the *tracking* repo deliberately
- `autopilot/fabric/worker-brief.template.md` (SGE source repo) — the swarm worker cycle
