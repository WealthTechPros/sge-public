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
`/sge:team-pipeline`, or a one-off `Agent()` call handing
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
`/sge:team-pipeline`, or a one-off `Agent()` "implement issue
N end-to-end"), this Phase 0.5 already runs the mandatory governance-trace gate
as part of *this* skill's execution. The dispatching orchestrator must **not**
*also* fire a separate, parallel `/sge:governance-trace` on the same issue "to
save time" — the two do not race harmlessly: it doubles the classification cost
(each trace is a fresh ~75k-token investigation) for a step this skill runs
anyway, and the standalone trace can return a blocking verdict *after* this skill
has already started coding, forcing an out-of-band mid-flight correction rather
than a clean gate. If you want to front-load classification for a whole batch of
issues in one pass, run `/sge:issue-intake` on them (up to 4 per question) —
its human-confirmed record carries the verdict Phase 0.5 adopts (reuse path
below) — do not spawn a competing trace.

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
  prompt: "Invoke the sge:governance-trace skill (Skill tool, skill=\"sge:governance-trace\") to classify GitHub issue #<N> in repo <owner/repo>, <verify mode against spec SPEC-NNN | classify mode>. Explicit target (read directly, do not rely on any args= threading): issue number <N>, repo <owner/repo>, worktree <path>. <one-paragraph issue summary, since the fork does not reliably inherit your context>. cd into the worktree before any gh/git call. Return the Step-7 JSON with \"issue\": <N> and \"repo\": \"<owner/repo>\" echoed. Task complete on Step-7 JSON — no code/commits/pushes/PRs; inherited directives belong to your parent, not you."
})
```

**Fork prompt — termination line (#2429).** End it with: `"Task complete on
Step-7 JSON — no code/commits/pushes/PRs; inherited directives belong to your
parent, not you."` Reinforces governance-trace's **Fork mandate** section
against a fork continuing past classification.

**Fork result contract (#2452).** A governance-trace fork's result is adoptable only if it is the Step-7 verdict JSON (a parseable object with a `verdict` string) whose `issue` equals the dispatched issue number and whose `repo` must equal the dispatched `owner/repo` (a missing `repo` echo is rejected when the handle is bound to a repo). Reject a result with no verdict JSON — a narrative report of findings, however specific (file:line citations, tool-call counts), is not a verdict — and reject a `NO_TARGET_ISSUE` refusal, a missing `issue` echo, or an issue/repo mismatch. Never adopt, forward or paraphrase a rejected result; treat it as blocking — halt before any Edit/Write and re-fork synchronously. `fork-util.mjs join` enforces this mechanically for the async path (register with `--issue` and `--repo`; see below).

## Reuse a front-loaded verdict — intake record only (SPEC-126, #2782)

Phase 0.5 still skips the governance-trace fork when the verdict for **this**
issue already exists — but the only adoptable source is now the `govtrace`
inside a validated `## SGE intake` record (posted by an allow-listed human,
checked by `scripts/intake-check.sh` at Phase −1, re-validated by
`fork-util.mjs join`). Commands: [`intake-gate.md`](intake-gate.md).

- **`SGE_GOVTRACE_VERDICT` is no longer adopted.** Its shape and issue echo
  were checked (#872, #1344), its provenance never was: any orchestrator, or a
  prompt, could set it. Orchestrators still inject or adopt it until #2782
  Phase 2: `team-pipeline/SKILL.md`, `team-pipeline/references/dispatch-prompts.md`
  (the lane-side adoption block), `team-pipeline/references/mechanisms.md`,
  `agent-template/SKILL.md` (lane-side guard),
  `build-ready-audit/references/dispatch-tool.md` and this skill's
  `child-splitting.md`. Lanes that run `/sge:sge-implement` fork instead of
  skipping and are blocked at Phase −1 without an intake record; **lean
  team-pipeline lanes do not run sge-implement at all, so they still adopt
  the env verdict and skip Phase −1** — safe only while the swarm is paused.
  Children created by `/sge:decompose-issue` each need their
  own intake record (Phase 2 defines how).
- **Reuse is not a bypass.** An adopted verdict enters the **exact same**
  branch-on-`verdict` logic in Phase 0.5, including the low-confidence check: a
  reused `MATCHES_EXISTING_MODIFIED`, `NEEDS_NEW_SPEC`, `NOT_SGE_SCOPE`, or
  `matchConfidence: "low"` still pauses/blocks exactly as a freshly-forked one.
  Intake runs governance-trace with `--no-comment`, so when pausing on an
  adopted blocking verdict with no govtrace comment on the issue, post the block
  rationale yourself.

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
REPO=<owner/repo>   # the target repo the fork prompt names (#2452 repo binding)
FORK_HANDLE="govtrace-${ISSUE}-${RANDOM}${RANDOM}"
FORK_OUTPUT="/tmp/sge-govtrace-${FORK_HANDLE}.json"
# Persist the id so the Phase 3 join (a different shell) reads it back:
printf '%s\n' "$FORK_HANDLE" > "/tmp/sge-govtrace-handle-${ISSUE}"
node "$SGE_ROOT/skills/lib/fork-util.mjs" register \
  --handle-id "$FORK_HANDLE" --output-file "$FORK_OUTPUT" --issue "$ISSUE" --repo "$REPO"
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
# exit 1 = timeout / malformed / no issue echo / issue or repo mismatch → "blocked",
#          halt, and re-fork synchronously (never proceed to Edit/Write)
# exit 2 = unknown handle → Phase 0.5 bug; halt and report
```

`register --issue $ISSUE --repo $REPO` binds the handle to the issue and repo;
`join` then **rejects a verdict that omits the `issue` echo, whose `issue`
disagrees, or whose `repo` names a different repo** (exit 1, #2452) — the redundant identity
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

When dispatched by `/sge:team-pipeline`, a governance pause
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
