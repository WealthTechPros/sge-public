# sge-implement — Phase 2.5 complexity-tiered scoped read (extended rationale)

Full rationale and worked examples for the Phase 2.5 governance-context read
(epic #785; #807 path-scoping, #809 tier→depth mapping). The operational
resolver commands, tier table, and read steps stay in `SKILL.md` Phase 2.5; this
file carries the "why" and the audit-trail worked examples.

## Non-goal guard — CRITICAL context is never thinned

CRITICAL classification wins over every other signal: a one-line YAML tweak to
an auth policy, or a "small" migration edit, still reads the full stack. The
tier→depth mapping only ever *narrows* reads for demonstrably trivial or standard
work — it can never down-depth a CRITICAL path. If the resolver reports
`tier: critical`, do **not** run `resolve-context-scope.mjs` to thin the read;
read everything the change's blast radius touches.

## Step B read-depth detail

1. **Digest (always, every tier).** Read `docs/sge-digest.md` (location per repo
   CLAUDE.md; format contract: `docs/sge-digest-schema.md` in the sge repo) —
   vision one-liner + non-goals, capability position, active ADR constraints,
   change protocol, open spec pointers, each line linking to the full artefact.
   Follow a link only when the task actually needs the detail. If the repo has no
   digest, orient from the artefacts CLAUDE.md names and move on — do not
   reconstruct one inline.
2. **The governing spec is always a full read.** Spec lane: the `SPEC-NNN` from
   Phase 1 (preflight already read it — re-read only what Phase 3 needs). Scoping
   applies to the *other* specs and ADRs, never to the artefact being
   implemented.
3. **`standard` tier — resolve the path-scoped deep-read set.** (Skip this for
   the `trivial` tier — the digest is enough. For the `critical` tier, ignore
   scoping and read the full stack instead.) Deep-read only the returned
   `artefacts[]` (each entry carries its file path and the reason it was
   selected); everything in `excluded[]` is governance noise for these paths — do
   not load it. An ADR about the payments adapter is never read for a docs-site
   change.
4. **Fail-safe, not fail-open.** `scoped: false` (the manifest carries no scope
   globs, or the path set is empty) means the resolver cannot narrow: stay
   digest-first and follow digest links on demand. It is never a reason to read
   the full stack — and never a reason to skip the digest.
5. **Leave the audit trail.** Note the tier, depth, and what was deep-read vs
   scoped out in the Phase 3 starting map (it feeds the Phase 5 reviewer), e.g.
   `governance: standard tier → digest + 2 specs + 1 ADR loaded, 5 scoped out
   (resolve-context-depth + resolve-context-scope)` or
   `governance: critical tier (auth path) → digest + full L0–L8 stack, not thinned`.

## Re-tiering mid-implementation

If the plan changes mid-implementation to touch new paths, re-run
`resolve-context-depth.mjs` (Step A) — a newly-added CRITICAL path re-tiers the
whole change to `full` — then, for the `standard` tier, re-run the scope resolver
with the updated path set before editing them.

## Trivial-tier verification cap (#1267)

The Phase 5 "independent local review" step normally spawns a **forked,
fresh-context subagent** (`/sge:sge-review`) to verify the change. That fork is
valuable on real code changes — a reviewer with no memory of writing the diff
catches what the author cannot. But it is expensive: a docs-only lane was
observed spawning a 97k-token / 10-minute codebase-verification subagent
*unprompted*, to confirm a change that Phase 4's inline quality suite plus a
30-second read of the diff already fully verified.

**The cap.** On the **`trivial`** tier — the same `resolve-context-depth.mjs`
signal Phase 2.5 already computed (docs/config/test-only, complexity ≤ 15), read
straight from that Step A result, never re-derived — the forked verification
subagent is **off by default**. The verification on a trivial tier is:

1. **Phase 4's inline quality suite** — type-check, lint, tests — which runs on
   every tier regardless, and
2. **an inline self-check of the diff against the issue's acceptance criteria** —
   you read your own diff and confirm each criterion, in-context, no fork.

**What the cap does and does not do.** It caps the *reflex to spawn a
verification subagent*, not verification itself: the cheap inline gates still
run on every trivial change, so a control is never weakened to save tokens — only
the redundant fork is removed. On `standard` and `critical` tiers the forked
review is **unchanged and unconditional** (and CRITICAL, as everywhere, is never
thinned).

**The cap is a default, not a hard ban.** Forking a verification subagent on a
trivial-tier change stays available as a **deliberate opt-in**: if the dispatch
or issue explicitly asks for a forked review, or if the diff turned out to touch
`standard`+ risk after all (re-tier via Step A), fork it exactly as the
`standard`/`critical` path does. The point is that on trivial work the fork
becomes a *choice you make*, not the silent default.

This reuses the E1/#1261 → `resolve-context-depth.mjs` tier path that #1263 (S2)
wired into the pre-fork governance gate — there is deliberately **no second
tiering rule** for verification; the one classifier decision drives context
depth, the governance-fork cap, and now the verification-fork cap alike.

### Inline verification procedure (#1345)

When the trivial-tier cap is active, inline verification replaces the forked
subagent. It must stay within ≤ 5 000 tokens total:

1. **Diff review** — `git diff origin/main...HEAD` read in-context; confirm each
   AC is satisfied.
2. **Targeted grep** (only as needed, for the changed paths). Anything requiring
   a broad codebase search signals the tier was wrong — escalate.
3. **Side-effect check** — compare `git diff --name-only origin/main...HEAD`
   against the **expected path set** (the spec's "Files to Create/Modify" or the
   0B plan). If any changed file falls *outside* that set:
   - The change has an unexpected side-effect.
   - Immediately **escalate to standard-tier**: spawn a forked `/sge:sge-review`
     subagent exactly as for a `standard`-tier change.
   - Record `verification_mode = "subagent (escalated from trivial)"`.
   - The PR description (Phase 6 `sge-phase5-verdict` comment) carries this value
     so the escalation is auditable in CI logs.
4. **Auditable outcome** — once verification completes (inline or escalated), set
   `verification_mode` to one of:
   - `"inline"` — trivial-tier inline gates passed, no side-effect found.
   - `"subagent"` — a forked `/sge:sge-review` ran (standard/critical, or
     explicit opt-in request).
   - `"subagent (escalated from trivial)"` — inline side-effect check triggered
     escalation to a forked subagent.

   The value is embedded in the Phase 6 PR body as `"verification"` inside the
   `sge-phase5-verdict` HTML comment, making it visible to `/sge:pr-review` and
   queryable in CI logs.
