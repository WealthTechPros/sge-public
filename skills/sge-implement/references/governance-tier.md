# sge-implement — proportional governance tier (T0/T1/T2)

Full mechanics for the governance **PROCESS** tier — a proposal ("sge v5.0.0:
tiered proportional governance") to make review cost proportional to change
size and risk instead of fixed at every change's maximum. Resolved once in
Phase 2 by `scripts/resolve-governance-tier.mjs`, then read by Phase 0.5
(fork-skip), Phase 5 (review-skip), and `/sge:pr-review` (review depth).

**Deliberately a second, separate axis from context DEPTH.**
`resolve-context-depth.mjs` (Phase 2.5) answers "how much governance context
should be read while implementing this?" — unchanged by this proposal. This
tier answers "how much governance PROCESS should this change pay for?". A
change can legitimately read full spec context (because it touches a spec's
own module) while being process-light, or vice versa — conflating the two
into one classifier would either thin context that a real change needs, or
keep paying full process tax on a change too small to need it. See the header
comment of `resolve-governance-tier.mjs` for the full rationale; this is a
deliberate divergence from the "one classifier drives everything" doctrine
`context-depth.md` documents for the depth axis, made explicit here rather
than silently contradicting it.

## The three tiers

| Tier | Condition | Phase 0.5 fork | Phase 5 sge-review | `/sge:pr-review` mode | `/sge:commit --no-verify` |
|---|---|---|---|---|---|
| **T0** fast lane | no-spec lane, score ≤ 15, risk = low | skipped* | skipped | `lightweight` | never |
| **T1** standard | no-spec lane, score 16–30, risk = low | runs | skipped | `correctness-subset` | never |
| **T2** audit-grade | spec lane (always), OR any risk-class path, OR score > 30 | runs | runs | `full` (current, unchanged) | never |

\* See "Phase 0.5 fork-skip stays narrower than T0" below — this is the one
place the wiring is intentionally more conservative than a literal reading of
T0's definition.

**Path risk always outranks score and lane-within-T0/T1** — a 5-line change to
an auth file is T2 even though its score is trivially small. **Spec-lane work
is always T2** — that is the audit-grade artefact WTP sells to clients; T0/T1
exist only for the no-spec (chore/infra) lane, where today's fixed-max-cost
tax has no proportional payoff.

**The risk map also covers the governance system's own infrastructure and two
process invariants T0 would otherwise silently override** (found by
security-auditor review of this PR, confirmed via design pass with the repo
owner — see `scripts/resolve-governance-tier.mjs`'s header comment for the
full rationale):

- **`GOVERNANCE_SELF_RE`** — `.github/**`, `skills/**`, `.claude/**`,
  `hooks/**`, `docs/specs/**`, `docs/decisions/**`, and this module's own
  sibling scripts (`scripts/resolve-*.mjs`) always force T2. Without this, a
  no-spec, low-score edit to the merge gate, a hook script, or the skill
  files that define the review process itself could resolve T0 and skip
  review entirely — the governance system auditing everything except its own
  changes. There is a **separate, already-existing** `SENSITIVE_RE` deny in
  `.github/workflows/sge-auto-merge.yml` (sge#2521/#2563) that already covers
  `.github/**` at the auto-merge-gate layer; `GOVERNANCE_SELF_RE` is the
  earlier **review**-tier layer (this module), closing the same class of gap
  one layer up for the paths the auto-merge deny does not reach (`skills/`,
  `.claude/`, `docs/specs/`, `hooks/`).
- **`UI_TOUCHING_RE`** — reuses `hooks/ui-edit-tracker.sh`'s UI-file glob
  (`.tsx`/`.jsx`/`.vue`/`.svelte`/`.css`/`.scss`/`.less`/`.html`)
  byte-for-byte, so it always forces T2. Without this, T0's unconditional
  skip of Phases 4.3-4.6 silently overrode `/sge:pr-review`'s Phase 4.5
  design-evidence gate (`skills/pr-review/references/design-evidence.md`),
  which explicitly states `SGE_UNATTENDED=1` is **not** exempt for
  UI-touching PRs. Deliberately does **not** replicate that hook's
  `primitives/` exemption — this risk map's doctrine is "over-matching is
  safe, under-matching is not", so a primitives-exempt UI file still forces
  T2 here even though the design-evidence gate itself would not have
  required a verdict for it.
- **`DUAL_BACKEND_PROXY_RE`** — a **conservative, path-only proxy** (matches
  literal `seam`/`seams`/`dual-backend` path segments) for the seam-evidence
  gate's (`skills/pr-review/references/seam-evidence.md`, Phase 4.4)
  dual-backend detection, which is actually a diff-content/spec-section
  heuristic (a demo/mock/fixture provider paired with a warehouse/real/live
  one) that a path list alone cannot replicate exactly. **This is a known,
  documented limitation, not full coverage**: a dual-backend surface whose
  paths don't literally name the convention will under-match here. Err
  toward T2 when in doubt is the doctrine; this proxy is the best a
  path-only classifier can do without reading the diff.

## Resolving the tier (Phase 2)

```bash
node "$SGE_ROOT/scripts/resolve-governance-tier.mjs" \
  --paths "<comma-separated touched/planned paths>" \
  --score <Phase 2 complexityScore> \
  --lane <spec|no-spec>
```

`--lane` is mechanical, not inferred: `spec` when Phase 0's grep found a
`SPEC-NNN`/`SGD-NNN` reference (or Phase 0.5's verdict resolved to
`MATCHES_EXISTING`/`MATCHES_EXISTING_MODIFIED`/`NEEDS_NEW_SPEC` and you are
past Phase 1); `no-spec` only once Phase 0.5 has actually landed in **0B: No-
spec lane** (`NO_SPEC_WARRANTED`, `NOT_ONBOARDED`, or an accepted
`NOT_SGE_SCOPE` override). **Never guess `no-spec` before Phase 0.5 has
resolved** — a spec citation not yet verified must not buy fast-lane
treatment; the script itself fails safe to T1 on a null/unset lane, so an
early speculative call under-tiers safely rather than over-tiers.

**Re-resolve, don't cache blindly, if the plan changes.** If Phase 3 touches
paths beyond what Phase 2 predicted, re-run this exactly as Phase 2.5's
re-tiering rule does for context depth — a newly-touched risk path re-tiers
the whole change to T2, and a broadened scope can push a T0 change's score
past 15.

**Log it — never silent (task requirement).** Record the full JSON result
(not just the `tier` string) in the Phase 3 starting map, export
`SGE_GOVERNANCE_TIER=<tier>` for the session, and carry `tier` +
`resolveGovernanceTier`'s `reason` into the Phase 6 PR body as a new HTML
comment alongside the existing `sge-cortex-stats`/`sge-phase5-verdict` ones:

```
<!-- sge-governance-tier: {"tier": "<T0|T1|T2>", "reason": "<reason>", "score": <N>, "risk": "<low|high|unknown>"} -->
```

`/sge:pr-review` reads this marker but — per the "Inherited Claims" doctrine
this repo already applies to every other inherited claim — **never trusts it
outright**: it re-derives the tier from the live diff's paths before honouring
a lightweight mode. See `mode-selection.md` in `pr-review`'s references.

## Phase 0.5 — fork-skip, and why it stays narrower than T0

The **Pre-fork tier gate** already in Phase 0.5 (`verdict-handling.md`) lets a
**context-depth-`trivial`** change (docs/test/config-only **and** score ≤ 15)
classify inline instead of forking `/sge:governance-trace` — a real, existing
mechanism this proposal extends rather than replaces.

**What this proposal changes here:** the pre-fork gate's inline path now also
runs the risk classifier (`resolve-governance-tier.mjs`'s risk map) before
accepting an inline verdict — a change to `docs/compliance/ai-policy.md`
previously classified `trivial` by path-extension alone (it is a `.md` file)
and could inline-classify; it is now risk = high and always forks. This closes
a real gap, not just adds ceremony: `resolve-context-depth.mjs`'s
docs/config/test heuristic has no way to know a documentation path is a
compliance artefact. See `skills/governance-trace/references/tier-gate.md`
Step 0.6/0.6L for the mechanics.

**What this proposal deliberately does NOT change:** it does not widen
fork-skip eligibility to genuinely non-trivial-by-extension code just because
its score is ≤ 15 and it touches no risk path — i.e. T0 as scored by this
module is a **necessary but not sufficient** condition for skipping the
Phase 0.5 fork; the existing (narrower) context-depth-`trivial` gate is still
required too. A code change can be T0 for Phase 5/commit/pr-review purposes
while still forking governance-trace once in Phase 0.5.

**Why.** The pre-fork gate's whole safety argument (`verdict-handling.md`,
"Safety — the gate can never under-classify a risky change") rests on the
inline path only ever firing on content that is *provably non-semantic by
extension* — the same "provably, not heuristically" standard
`dispatch-scaling.md` uses for `pr-review`'s own `trivial`/`prose` diff tiers.
A real code file's semantic content — does it modify a spec's stated
requirement — is exactly the judgment `/sge:governance-trace` exists to make,
and score/risk-path alone don't establish that a small code diff is
*additive* rather than a spec-changing edit; only reading it (even cheaply)
does. Collapsing that judgment for any small, non-risk-path code diff is a
bigger step than this proposal is prepared to take without dedicated design
review — **this is the one place this implementation is intentionally less
than a literal reading of the task's T0 definition**, flagged here and in the
PR description rather than silently narrowed. A code change that is T0 by
score+risk still gets the two other, larger wins (Phase 5 skip, lightweight
`/sge:pr-review`); it just still pays the governance-trace fork once.

If a future iteration wants to close this gap, the natural next step is
extending `governance-trace/references/tier-gate.md` Step 0.6L with a new
rule for "small, no-risk-path code change, issue body has no Gherkin/AC
language" — mirroring Rule 4's "Mixed trivial" confidence-`medium` pattern and
Rule 5's escalate-on-ambiguity safety net — rather than inventing a second
inline-classification codepath.

## Phase 5 — review skip (T0 and T1)

On `SGE_GOVERNANCE_TIER` `T0` or `T1`: **skip Phase 5 entirely** — no forked
`/sge:sge-review`, and (unlike the pre-existing context-depth `trivial`-tier
verification cap) **no inline-verification substitute either**. The task is
explicit that T0 skips "entirely", and T1 explicitly "relies on pr-review as
the single review" — Phase 4's quality suite (type-check/lint/tests) already
ran and is unconditional at every tier, and `/sge:pr-review`'s
`correctness-subset` (T1) / `lightweight` (T0) modes are the review that
covers the diff.

On `T2`: **unchanged.** Forked `/sge:sge-review` on `standard`/`critical`
context-depth tiers; the pre-existing inline-verification cap still applies
on a `T2` change that also happens to be context-depth-`trivial` (e.g. a
risk-path docs change) — that interaction is untouched by this proposal.

## `/sge:commit` — no `--no-verify` exception at any tier

`--no-verify` is prohibited absolutely, at `T0` as much as `T1`/`T2` — see
`skills/commit/SKILL.md`. An earlier draft of this proposal carved out a
narrow T0 exception keyed on `git diff -w -b --staged` being empty
("provably whitespace-only"); it was removed because that proof is
unsound, not just gameable — git's whitespace-ignoring diff also ignores
whitespace changes inside string literals, and in whitespace-significant
languages (Python indentation, YAML nesting) a real behavioral change can
still produce an empty whitespace-only diff.

## Worked examples

| Change | Lane | Score | Risk | Tier |
|---|---|---|---|---|
| Fix a typo in an error message (1 file, no tests needed) | no-spec | 2 | low | **T0** |
| Add a retry helper + 3 unit tests | no-spec | 9 | low | **T0** |
| Add a new REST endpoint + service method + 4 scenarios | no-spec | 22 | low | **T1** |
| One-line fix to `platform/src/auth/session.ts` | no-spec | 1 | **high** | **T2** |
| Fix a typo in `docs/compliance/ai-policy.md` | no-spec | 1 | **high** | **T2** |
| Any issue citing `SPEC-042` | spec | (any) | (any) | **T2** |
| Score-42 no-spec refactor, no risk path | no-spec | 42 | low | **T2** (Large — decompose first) |
| One-line wording tweak to `skills/pr-review/SKILL.md` | no-spec | 2 | **high** | **T2** (governance self-reference — `GOVERNANCE_SELF_RE`) |
| Small CSS tweak to a `.tsx` component, no other risk path | no-spec | 3 | **high** | **T2** (UI-touching — `UI_TOUCHING_RE`, closes the design-evidence-gate exemption gap) |
