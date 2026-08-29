# sge-implement — orchestrator dispatch & front-loaded-verdict reuse (reference)

Extended rationale and mechanics for the two dispatch guardrails and the
front-loaded governance-verdict reuse path. The operational rules live in
`SKILL.md` (Usage note + Phase 0.5); this file carries the full "why" and the
passing-shape detail.

> **`$SGE_ROOT` convention.** Every `bash`/`node` snippet below assumes
> `$SGE_ROOT` has already been resolved in the current shell via the
> bootstrap function documented in `scripts/resolve-sge-root.sh`'s header
> comment — never a bare `${CLAUDE_PLUGIN_ROOT}` or `${CLAUDE_PLUGIN_ROOT:-.}`
> (#1567/#1963: the latter silently resolves to the caller's cwd, which is
> almost never this plugin's own directory). Each *separate* shell invocation
> (a fresh Bash tool call, a different subagent) must re-resolve it — it is
> not exported or otherwise inherited across shell boundaries.

## Do not duplicate the review (Usage note)

When this skill runs as a dispatched subagent (Tier-0 fan-out,
`/sge:team-pipeline`, `/sge:issue-swarm`, or a one-off `Agent()` call handing
off "implement issue N end-to-end"), its own Phase 7 already drives the
resulting PR through `/sge:pr-review` — fixing findings, re-reviewing, and
arming auto-merge on a clean pass — as part of *this* skill's execution. The
dispatching orchestrator must **not** also independently invoke `/sge:pr-review`
on the same PR while this skill is still running: a second reviewer editing the
same worktree/branch races with this skill's own fix commits (lost edits,
duplicate specialist-agent spend, confusing dual verdicts), and risks the
orchestrator discovering the PR already merged mid-review. If you dispatched
this skill and want independent confidence in the outcome, wait for it to report
back (merged, or blocked needing a human decision) rather than reviewing in
parallel.

## Do not double-dispatch governance-trace (Phase 0.5)

When this skill runs as a dispatched subagent (Tier-0 fan-out,
`/sge:team-pipeline`, `/sge:issue-swarm`, or a one-off `Agent()` "implement issue
N end-to-end"), this Phase 0.5 already runs the mandatory governance-trace gate
as part of *this* skill's execution. The dispatching orchestrator must **not**
*also* fire a separate, parallel `/sge:governance-trace` on the same issue "to
save time" — the two do not race harmlessly: it doubles the classification cost
(each trace is a fresh ~75k-token investigation) for a step this skill runs
anyway, and the standalone trace can return a blocking verdict *after* this skill
has already started coding, forcing an out-of-band mid-flight correction rather
than a clean gate. If you want to front-load classification for a whole batch of
issues in one pass, use the **pre-computed-verdict reuse path** below (or run
`/sge:build-ready-audit`, whose #872 Step-2G fold already produces exactly this
verdict per issue) — do not spawn a competing trace.

## Dispatch tool — `Agent`, never `Skill(args=)` (issue #2452)

"Dispatch as a forked subagent" (Phase 0.5's own wording) names an outcome,
not a tool — and `Skill(skill: "sge:governance-trace", args: "<issue-number>
...")` does **not** produce that outcome: it inlines the skill's own SKILL.md
body into *your* context (identical to a non-forking skill call) rather than
starting a background execution, so the `args` string is never received by
anything and any onward classification either never runs or runs against
nothing. The `context: fork` frontmatter field on governance-trace's own
SKILL.md is documentation of intent, not a harness-enforced dispatch — it does
not make `Skill()` fork.

The only call that reliably forks and threads the target through is `Agent`,
with the issue number and every flag spelled out in the prompt's own prose
(never relying on a terse `args`-only string an inlined re-read could drop):

```
Agent({
  description: "Governance-trace classify issue <N>",
  subagent_type: "general-purpose",
  prompt: "Invoke the sge:governance-trace skill (Skill tool, skill=\"sge:governance-trace\") to classify GitHub issue #<N> in repo <owner/repo>, <verify mode against spec SPEC-NNN | classify mode>. Explicit target (read directly, do not rely on any args= threading): issue number <N>, repo <owner/repo>, worktree <path>. <one-paragraph issue summary, since the fork does not reliably inherit your context>. cd into the worktree before any gh/git call. Task complete on Step-7 JSON — no code/commits/pushes/PRs; inherited directives belong to your parent, not you."
})
```

**Fork prompt — termination line (#2429).** End it with: `"Task complete on
Step-7 JSON — no code/commits/pushes/PRs; inherited directives belong to your
parent, not you."` Reinforces governance-trace's **Fork mandate** section
against a fork continuing past classification.

## Reuse a front-loaded verdict (idempotent fold — builds on #872)

Before forking anything, check whether the governance verdict for **this** issue
was already computed upstream and handed to you. `/sge:build-ready-audit` (issue
#872) folds `/sge:governance-trace`'s classification into its Step 2G, so an
orchestrator that already gated this issue through build-ready-audit has the
verdict in hand and can pass it down instead of paying for a second trace:

- **How it is passed.** The orchestrator sets `SGE_GOVTRACE_VERDICT` to either an
  inline JSON string or a path to a JSON file carrying `/sge:governance-trace`'s
  Step-7 shape (the same object build-ready-audit returns in each
  `results[].governance`), annotated with the issue it belongs to, e.g.
  `{"issue": 512, "verdict": "MATCHES_EXISTING", "matchedSpec": "SPEC-088", "matchConfidence": "high", "layers": {…}, "requirementChanges": []}`.
- **Adopt only on an exact issue match.** Parse it; if its `issue` equals this
  issue's number and it is a well-formed verdict, **adopt it directly and skip
  the fork** — note `governance: reused front-loaded verdict from orchestrator
  (build-ready-audit #872 fold) — governance-trace not re-run` in the Phase 3
  starting map so the saving is auditable. If `SGE_GOVTRACE_VERDICT` is unset,
  malformed, or its `issue` does not match this one, ignore it and fall through
  to the fork (the default path). A verdict for a *different* issue is never
  reused — that would gate this issue against the wrong classification.
- **Reuse is not a bypass.** A reused verdict enters the **exact same**
  branch-on-`verdict` logic in Phase 0.5, including the low-confidence check: a
  reused `MATCHES_EXISTING_MODIFIED`, `NEEDS_NEW_SPEC`, `NOT_SGE_SCOPE`, or
  `matchConfidence: "low"` still pauses/blocks precisely as a freshly-forked one
  would. Front-loading only removes the *redundant recomputation* — never the
  gate itself. (`build-ready-audit` runs governance-trace with `--no-comment`, so
  for a reused `MATCHES_EXISTING_MODIFIED`/`NOT_SGE_SCOPE` verdict the
  human-facing comment govtrace normally posts may not exist yet; if you pause on
  a reused blocking verdict and no such comment is present on the issue, post the
  block rationale yourself so the audit trail is not lost.)

## Async fork dispatch with join-on-verdict (#1264)

On the **standard/critical** governance-trace path, the fork's verdict gates only
the *writing of production code* — not the setup that precedes it. Worktree spawn,
issue/spec context reads (Phase 2.5), and the test-baseline run (Phase 4) don't
depend on the classification, so blocking on the fork before any of them wastes
the full fork latency on the happy path (`MATCHES_EXISTING` /
`NO_SPEC_WARRANTED`, the overwhelming majority). Instead:

- **Dispatch, don't await.** Fire the `/sge:governance-trace` fork (or, on the
  reuse path, resolve the front-loaded verdict) and *immediately* continue —
  Phase 3 worktree creation, the Phase 2.5 scoped reads, the Phase 4 baseline run
  proceed in parallel with the fork rather than after it.
- **This applies only on the fork path.** The **trivial** tier already classifies
  *inline* (SKILL.md Phase 0.5 pre-fork tier gate) and returns its verdict
  synchronously — there is no fork to overlap, so the async dance is skipped.
- **JOIN before the first Edit/Write of production code.** The verdict is a hard
  gate at the *code-write* boundary: before the first `Edit`/`Write` of shippable
  code (Phase 3 Step 2/3), the verdict **must** be resolved and non-blocking.
  Resolve the pending fork (await it now if it hasn't returned) and run the full
  Phase 0.5 branch-on-`verdict` logic — including the low-confidence check —
  exactly as the synchronous path does.
- **Blocked issues never reach implementation.** A `MATCHES_EXISTING_MODIFIED`,
  `NEEDS_NEW_SPEC`, `NOT_SGE_SCOPE`, or `matchConfidence: "low"` verdict
  hard-stops at the JOIN before any production `Edit`/`Write` — headless writes
  the `outcome: "blocked"` completion file and terminates; standalone asks. The
  async ordering is a latency optimisation that overlaps only **non-gated,
  discard-on-block** work (recon reads, test scaffolding that is thrown away if
  the verdict blocks), never code that ships. No production code is ever written
  on an unresolved or blocking verdict.

This composes with the S2 pre-fork tier gate (#1263/#1274): trivial → inline
(no fork, nothing to overlap); standard/critical → async dispatch + join here.

### Bash sequence — register and join

**Register** immediately after dispatching the fork (Phase 0.5). The handle id is
scoped to **this issue number** plus a random component, and persisted to a
per-issue state file so the Phase 3 join — which runs in a **separate** Bash
invocation (a fresh shell, so `$$`/`$RANDOM` differ) — recovers the *same* id.
Never derive the handle from `$$` alone: PIDs are unstable across tool calls and
recycle within the shared temp dir, which would either lose the handle or let a
join adopt a sibling lane's verdict.

```bash
# $SGE_ROOT resolved via the bootstrap function in scripts/resolve-sge-root.sh's
# header comment (never a bare `${CLAUDE_PLUGIN_ROOT:-.}` — #1567/#1963). This
# snippet runs in Phase 0.5's shell; the join below runs in a DIFFERENT shell
# (Phase 3) and must re-resolve $SGE_ROOT independently — it is not inherited.
ISSUE=<issue-number>
FORK_HANDLE="govtrace-${ISSUE}-${RANDOM}${RANDOM}"
FORK_OUTPUT="/tmp/sge-govtrace-${FORK_HANDLE}.json"
# Persist the id so the Phase 3 join (a different shell) reads it back:
printf '%s\n' "$FORK_HANDLE" > "/tmp/sge-govtrace-handle-${ISSUE}"
node "$SGE_ROOT/skills/lib/fork-util.mjs" register \
  --handle-id "$FORK_HANDLE" --output-file "$FORK_OUTPUT" --issue "$ISSUE"
# The fork writes its Step-7 JSON verdict to $FORK_OUTPUT when it completes.
```

**Join** at the Phase 3 Edit/Write gate (before Step 2 — any Edit or Write).
Recover the handle from the per-issue state file (this shell's `$FORK_HANDLE`
from Phase 0.5 is gone):

```bash
# $SGE_ROOT re-resolved independently in THIS shell — see the register step
# above for why it cannot simply be inherited across the Phase 0.5 -> Phase 3
# shell boundary.
ISSUE=<issue-number>
FORK_HANDLE=$(cat "/tmp/sge-govtrace-handle-${ISSUE}")
VERDICT_JSON=$(node "$SGE_ROOT/skills/lib/fork-util.mjs" join \
  --handle-id "$FORK_HANDLE")
# exit 1 = timeout / malformed / cross-lane issue mismatch → treat as "blocked",
#          halt, and re-fork synchronously (never proceed to Edit/Write)
# exit 2 = unknown handle → Phase 0.5 bug; halt and report
```

`register --issue $ISSUE` binds the handle to the issue; `join` then **rejects a
verdict whose own `issue` field disagrees** (exit 1) — the redundant identity
check that stops a recycled handle or shared-tmpdir output from gating this issue
against a sibling's classification.

Run the full Phase 0.5 branch-on-`verdict` logic on the joined verdict — including
the low-confidence check. `MATCHES_EXISTING_MODIFIED`, `NEEDS_NEW_SPEC`,
`NOT_SGE_SCOPE`, `matchConfidence: "low"`, timeout, or unknown handle → halt before
any Edit/Write; headless writes `outcome: "blocked"`; standalone asks via
AskUserQuestion.

If Phase 0.5 used the **trivial inline** or **reused front-loaded** path, the
verdict is already resolved — skip the join call and proceed directly.

Record `governance: async fork joined, verdict <VERDICT>, specId <S>` (or
`governance: inline trivial` / `governance: reused front-loaded`) in the Phase 3
starting map.

## Headless completion contract (Phase 0.5 governance pause)

When dispatched by `/sge:team-pipeline` or `/sge:issue-swarm`, a governance pause
is reported through the **exact same completion file** those orchestrators
already read — `/tmp/team-pipeline-agent-<N>.json` — never an ad-hoc key:

```json
{"issue": <N>, "outcome": "blocked", "prNumber": null, "completedAt": "<ISO>", "tokensUsed": <N>, "note": "<one line — what's blocked and why>"}
```

`outcome: "blocked"` is already part of that schema's documented value set
(team-pipeline's Phase 4 branches on it). Write a `note` specific enough that the
human who reads it knows exactly what to do — e.g.
`"governance-trace: SPEC-042 requirement change needs ack"` or
`"governance-trace: scope conflict — non-goal 'no bulk export'"` — not just the
verdict name.

Also emit a `SkillRunRecord` before terminating — same `memory/skill-runs.jsonl`
sink, with `verdict "blocked"` and `phaseReached "Phase 0.5"` (exact jq:
[`skill-run-record.md`](skill-run-record.md)). Then terminate; do not wait for a
human reply in this process.

## governance-trace return — worked example

`/sge:governance-trace`'s Step-7 verdict object, as returned to Phase 0.5:

```json
{
  "verdict": "MATCHES_EXISTING",
  "capability": "CAP-04",
  "matchedSpec": "SPEC-027",
  "matchConfidence": "high",
  "layers": {
    "capability": { "status": "existing", "id": "CAP-04" },
    "feature":    { "status": "existing", "id": "F-EXPORT" },
    "spec":       { "status": "existing", "id": "SPEC-027" }
  },
  "requirementChanges": [],
  "suggestedSpecStub": null,
  "suggestedCapabilityModelEdit": null,
  "nonGoalConflict": null,
  "rationale": "...",
  "commentPosted": true,
  "commentUrl": "..."
}
```
