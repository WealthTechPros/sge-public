# Phase 2 reviewer lanes — extended rationale & incident record

Reference-grade detail for the three-layer review, the structured-findings contract, the
silence/non-execution guards, and the bounded-wait rule in `../SKILL.md` Phase 2. The
actionable rules and helper calls live in the SKILL; this file records the incidents that
justify each guard. Nothing here is a new control.

## Layer model — cheapest first

Run review in three layers — **native floor → bundled specialists → repo specialists** — then
verify before posting. Cheapest lanes (native engine, existing bot signal) first; **escalate to
named specialists only where they leave a gap** — the tier rules are the exact definition of
"gap" (issue #688); never spawn `@code-reviewer`/`@security-auditor` as a reflex.

**Dispatch mode — prefer one-shot/fork over named teammate dispatch (issue #686).** Named/
addressable dispatch has stalled indefinitely on repeated `idle_notification` pings without
delivering findings, while `subagent_type: "fork"` completed cleanly in the same conditions —
Phase 2 reviewers get one prompt and return one structured reply, so prefer one-shot/fork unless
a repo agent genuinely needs multi-turn; if named dispatch is unavoidable, the bounded-wait rule
still applies.

**Model tier** (`agents/agent-registry.md`): `@code-reviewer` → **sonnet**, escalating to
**opus** on a security-path match; `@security-auditor` is CRITICAL-path and runs at **opus**.
Never route a security review below opus.

**Layer 3 repo specialists** join the same parallel batch only when the repo ships the agent AND
the trigger matches: **@contract-auditor-api** (API routes/handlers changed),
**@contract-auditor-database** (migrations/models), **@testing-specialist** (tests changed or
features added), plus any specialist the repo's `CLAUDE.md` names. Skip silently any agent the
repo doesn't define — never block on a missing agent.

## Structured findings contract — why silence is failure (issue #397)

A **genuine empty array `[]`** = clean pass. A **missing/empty/0-byte reply is NOT a pass** — it
is a reviewer that never reported: re-run it synchronously and use the re-run's result; never
count silence as a clean pass. Prose-only findings → ask once for the block. Phase 5 aggregates
**only** from these arrays.

## Structured findings contract — schema

Every Layer 2–3 (and verification) agent ends its reply with a fenced JSON array; include this schema verbatim in each dispatch prompt:

```json
[{"file": "path/to/file", "line": 42, "severity": "blocker|major|minor",
  "category": "correctness|security|performance|maintainability|requirements|traceability",
  "finding": "what is wrong", "suggestion": "the concrete fix"}]
```

A genuine `[]` = clean pass. A missing/empty/0-byte reply is NOT a pass — re-run synchronously (#397); never count silence as clean. Phase 5 aggregates only from these arrays.

**Sub-lane silence = failure (issue #855) — codified, not left to reviewer knowledge.** Every
dispatched sub-lane — `@security-auditor` (the security-audit sub-lane), `@code-reviewer`,
`/security-review`, any Layer 3 repo specialist, any blocker-verification agent — that returns
silence (no reply, an empty/0-byte reply, or only `idle_notification` pings with no findings
JSON) has **failed, not passed**. Include this instruction **verbatim in each dispatch prompt**:
*"Silence is a failure, not a pass — you must return the structured findings array (empty `[]`
only if genuinely clean) or an explicit failure line."* When a sub-lane goes silent,
**re-dispatch it synchronously** (fresh one-shot/fork, identical prompt) and block on the
re-dispatch's result before the verdict — never proceed to a `pass` on an unreturned lane, and
never terminate the review waiting on it. This is the sub-lane counterpart of the run-level
termination contract (Phase 9): a security-audit sub-lane that never reported cannot be silently
treated as clean.

**Sub-lane redundant full-suite re-runs — codified the same way (issue #2456).** The
"trust the PR's own tests, don't re-derive" guardrail ([`dispatch-scaling.md`](dispatch-scaling.md))
covers this from the *content* side; this is the dispatch-prompt-side enforcement, because
leaving it to reviewer judgment measurably failed: on one `high`-tier PR, 3 of 4 dispatched
lanes each independently ran (or attempted) the full ~4800-test project suite, and one of them
did so with the wrong Python interpreter — a global resolving imports from a *different*
worktree, silently producing spurious failures that cost an entire redundant verification cycle
to diagnose and redo. Include this instruction **verbatim in each dispatch prompt**: *"Do not
run the full project-wide test suite — Phase 3 already ran it once and its result is
authoritative. Run only targeted tests scoped to what you are personally verifying. Before
running any test command, check the target repo's own documented dev-environment setup
(CLAUDE.md / README) — a per-worktree virtualenv or equivalent isolation convention may be
required; a bare `python`/`pytest`/`npm test` on PATH is not safe to assume correct."* A lane
that needs the full-suite result for its own judgment reads it from Phase 3's already-posted
outcome (passed into the dispatch prompt), never re-runs it to obtain it fresh.

## Verify the agent actually ran before trusting its (non-)result (issue #883)

A `[]` from an agent that never did any work looks identical to a thorough clean pass — twice in
one session a dispatched specialist returned **zero tool calls** and a stray fragment of its own
opening reasoning as its "result", and the parent verdict trusted it (`ppp` PR #10091 merged
with an unverified section as a result). An empty/near-empty reply is not the only failure shape;
a `[]` (or plausible-looking findings) from an agent that spent tokens but ran **no tools** is
the subtler one. So before folding **any** dispatched agent's array into the Phase 5 aggregate,
mechanically confirm it executed — pass the harness-reported tool-call count for that agent and
its raw reply through the guard:

```bash
# When each Layer 2/3 agent is DISPATCHED (same message that spawns it), record
# it as PENDING in the per-PR attestation ledger so the merge gate can enforce
# that it was verified — pick any stable id (agent name / slot):
rl_reviewer_dispatch "$PR" "@code-reviewer"

# When its reply lands, VERIFY + CLEAR it. $TOOL_USES = the tool-call count the
# harness reports for THIS agent (0 when it never called a tool); "" when the
# dispatch surface reports none. rl_reviewer_attest runs rl_reviewer_ran and, on
# `ran`, marks the reviewer ATTESTED; otherwise it stays PENDING (exit 1):
rl_reviewer_attest "$PR" "@code-reviewer" "$TOOL_USES" reply.txt
#   prints ran | not-run:zero-tools | not-run:no-findings
```

`not-run:zero-tools` (a known count of exactly 0) or `not-run:no-findings` (no parseable
structured findings array) → **non-execution**: re-run that agent once with the identical prompt
(the redispatch is held to this same guard and re-attested under the same id), or escalate to
doing that specific check **inline** — never let its empty return count toward a clean verdict.
Only a `ran` result is eligible for aggregation. A genuine `[]` from an agent whose tool count is
`> 0` is a real clean pass and is trusted; it is `[]` **plus** a zero tool count that is the
trap. The guard **fails closed toward re-run** — an unverifiable reply is treated as
non-execution.

**Enforced mechanically, not by prose (issue #883, mirroring #754).** Because a
`rl_reviewer_dispatch` reviewer that is never attested stays PENDING in the ledger,
`pr-labels.sh pass` **refuses with exit 5** while any PENDING reviewer remains — an orchestrator
cannot skip the guard and still move the gate, exactly the hole the original incident exploited.
`start-review` resets the ledger; a genuinely inline review with no dispatched specialists
records nothing, so `pass` proceeds untouched (and `SGE_REVIEW_ATTEST_SKIP=1` is the explicit
escape hatch for that case). The tool-call count is caller-supplied — the guard is only as honest
as the `$TOOL_USES` passed at each `rl_reviewer_attest` call site.

## Bounded wait & stall detection (issue #686)

`idle_notification` is not a completion signal and not proof of progress either, and repeated
nudging produces more idle pings, not content. Treat a reviewer as **stalled** when it has
delivered no structured findings JSON within ~10 minutes or 3 `idle_notification` pings,
whichever comes first: never keep nudging the same stalled agent (one clarifying nudge while
genuinely unsure is fine); **re-dispatch a fresh one-shot/fork agent immediately** with the
identical prompt; use the fresh dispatch's result and discard any late reply from the stalled
agent (never double-count a slot); emit an interim status update ("still waiting on 2/4
reviewers; re-dispatching the stalled ones") rather than looping silently. The findings contract
applies to the redispatch too — an empty redispatch reply still counts as "never reported".

## Hand off dispatched checks — do not shadow-verify (issue #951)

Once a specific check is delegated to a dispatched lane (`/sge:pr-review` itself, a
`@code-reviewer`/`@security-auditor` fork, a Layer 3 specialist), the dispatching agent **waits
for that lane's verdict** rather than re-deriving the same thing in parallel (e.g. manually
grepping BDD step-def coverage while a reviewer was dispatched to check exactly that). Duplicated
verification burns tokens and wall-clock for zero added signal; block on the lane, then act on
its structured findings.

## Findings provenance — did the reply come from THIS diff? (issue #2200)

A dispatched review lane twice returned findings about a **completely different
diff** than the PR under review:

- reviewing `coherence-review#34`, a lane returned findings about
  `infra/cloudflare/__main__.py` — a `wtp-org` file, from the hub/control
  session that dispatched the review;
- reviewing `project-management#50`, the first lane returned DNS/Cloudflare
  Pages content matching nothing in that PR.

Both were caught only because the reviewing agent happened to cross-check the
findings against the diff it expected, then discarded and re-dispatched. That is
a lucky catch, not a gate. Uncaught, the failure is severe in both directions: a
PR approved on the strength of a review of **someone else's code** (a false-clean
verdict against the merge gate's core promise), or another repo's findings posted
onto this PR.

Both occurrences were in sessions where a hub repo was active alongside the
target — the documented Tier-0 dispatch model.

### Prevention, then detection

**Prevention: pin the target literally.** Every dispatch prompt — native Layer 1
and specialist alike — names `owner/repo` and the PR number as **constants**, and
makes `gh pr diff <N> --repo <owner/repo>` the lane's **first action**. A lane
must never infer "the PR under review" from ambient cwd or inherited context.

**Detection: verify the reply.** SPEC-057 fixes this class by resolving repo
context before the first `gh`/`git` call — but a dispatched sub-agent has its own
context, and no `cd` in the dispatching shell reaches inside it. Prevention does
not cross the sub-agent boundary, so detection has to:

```bash
PROV=$(rl_findings_provenance "$PR" "$REPLY_FINDINGS" "$REPO")
case "$PROV" in
  ok)           rl_findings_foreign_paths "$PR" "$REPLY_FINDINGS" "$REPO" ;;
                                          # fold in; report any foreign paths
  bleed)        ;;                        # dispatch FAILURE — discard, re-dispatch
  unverifiable) ;;                        # blocks identically; never treat as ok
esac
```

**Pass `$REPO` explicitly.** The detector must not resolve its own repo from
ambient cwd: a wrong-repo detector that itself resolves the wrong repo is this
bug class reproducing inside its own fix, and PR numbers collide across an org's
repos routinely, so it would compare against a real-but-wrong diff rather than
erroring.

**The exit status is part of the contract: `0 = ok, 2 = bleed, 1 = unverifiable`.**
Both non-zero results mean *do not fold*, so the natural
`if rl_findings_provenance …; then fold; fi` is safe rather than a trap.

**On `ok`, surface the foreign paths.** A mixed reply is accepted, but its
outside-the-diff entries are the residue of a partial bleed and belong in the
Phase 5 output — otherwise they are folded in with no signal at all.

### Why the test is not "every path must be in the diff"

The issue's literal ask was to reject any finding whose path is absent from the
diff. That is too strict, and would train the gate to discard real work: a
reviewer noting *"this signature change breaks `src/consumer.ts`"* is citing an
affected caller outside the diff and is doing its job.

The bleed signature is narrower and unambiguous: **at least one file-anchored
finding, and every one of them outside the diff** — a reply about a different
changeset entirely. That is `bleed`. A mix returns `ok`; the foreign paths are
still available via `rl_findings_foreign_paths` for the reviewer's judgement. A
genuine `[]` is a clean pass with nothing to place, never a bleed.

Renames are folded in via `previous_filename`, since a finding may legitimately
cite a path the diff carries only under its old name.

**Fails closed.** An unreadable findings file, an unfetchable diff, or an
unparseable array all return `unverifiable`, which blocks exactly as `bleed`
does. Unverified provenance is precisely the state that shipped both incidents.
