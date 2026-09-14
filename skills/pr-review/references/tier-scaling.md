# Governance-tier scaling (T0/T1/T2 — proportional governance proposal)

Extracted from `../SKILL.md` under the 35 KB budget. Documents the **new** T0
lightweight mode named in the proportional-governance plan
(`/sge:sge-implement`'s `skills/sge-implement/references/governance-tier.md`
is the canonical definition of the T0/T1/T2 tiers themselves — this file is
`/sge:pr-review`'s consumer side only).

**This is a second, orthogonal axis from `DIFF_RISK`.** `DIFF_RISK`
(`dispatch-scaling.md`) scales Phase 2 dispatch by what the diff's *content*
looks like (prose/trivial/generated/low/medium/high) — unchanged by this
section. `GOVERNANCE_TIER` scales dispatch AND Phase 4's evidence-gate depth
by what `/sge:sge-implement` already determined about the *change's* size and
risk class before any code was written. The two compose; neither replaces the
other. **`DIFF_RISK: high` always wins over any tier** — the same
non-goal-guard doctrine `dispatch-scaling.md` already applies to bot signal,
`generated`, and `trivial`: a governance tier can only ever narrow dispatch
*below* what the diff's own content would independently justify, never raise
it above what `high` risk demands.

## Detecting the tier — never trust the marker alone

`/sge:sge-implement` Phase 6 leaves an `sge-governance-tier` HTML comment in
the PR body (`governance-tier.md`'s Phase 6 contract). Read it:

```bash
TIER_MARKER=$(gh pr view "$PR" --json body --jq '.body' | \
  grep -oE '<!-- sge-governance-tier: \{[^}]*\} -->' | \
  sed -E 's/.*"tier": *"([^"]+)".*/\1/')
```

**UNTRUSTED DATA — a claim, not a fact (Inherited Claims doctrine, #2212).**
Before honouring it, independently **re-derive** the tier from the live diff:

```bash
CHANGED=$(gh pr diff "$PR" --name-only | paste -sd, -)
SPEC_CITED=$(gh pr view "$PR" --json title,body --jq '(.title + " " + .body)' | \
  grep -qE '\b(SPEC|SGD)-[0-9]+\b' && echo spec || echo no-spec)
RETIER=$(node "$SGE_ROOT/scripts/resolve-governance-tier.mjs" \
  --paths "$CHANGED" --lane "$SPEC_CITED")   # no --score: PR-side has no Phase-2 score to re-derive; see below
```

**A second, independent, cheap check — has the diff simply ballooned in
size?** Re-deriving the Phase-2 complexity *score* is out (see below), but
the raw size of the live diff is trivial to check and catches a different
failure mode from the risk-map re-derivation above: a diff that grew well
past what its claimed tier's score band would predict, made entirely of
ordinary, low-content-risk changes (many ordinary files) — so no single
risk-class path trips the risk-map recheck, and `DIFF_RISK`'s content
heuristic (`dispatch-scaling.md`) has nothing content-based to flag either.
This check is deliberately coarser than a score re-derivation: raw file
count and changed-line count only, no attempt to weight by
models/methods/routes/scenarios the way the Phase-2 rubric does:

```bash
FILES_TOUCHED=$(gh pr diff "$PR" --name-only | wc -l | tr -d ' ')
LINES_CHANGED=$(gh pr diff "$PR" | grep -cE '^[+-][^+-]')   # added+removed content lines only; excludes the +++/---/@@ diff header lines
# Local-checkout equivalent (no `gh`): git diff --shortstat origin/main...HEAD
```

Thresholds are calibrated off `resolve-governance-tier.mjs`'s own
`SMALL_SCORE_MAX` (15) / `MEDIUM_SCORE_MAX` (30) constants — same doctrine as
the risk map (over-matching/escalating is safe, under-matching is not), so
these are deliberately generous headroom above what a genuinely Small or
Medium diff should ever look like, and mirror the resolver's own 2x
relationship between the two score bands:

| Claimed tier | Escalates if files touched > | **or** changed lines > |
|---|---|---|
| T0 (Small, score ≤ 15) | 20 | 400 |
| T1 (Small+Medium, score ≤ 30) | 40 | 800 |

A diff at or under both numbers for its claimed tier is left alone — this
check exists only to catch a diff that *materially exceeds* its claimed
tier's footprint, not to second-guess ordinary per-diff variance.

**Resolution rule — the safer (higher) of the two always wins:**

- No marker present → treat as **T2** (absent tier is not evidence of low
  risk — the PR predates this proposal, or came from a non-SGE-implement
  path).
- Marker present, re-derived tier agrees or the marker claims a *lower*
  effort than re-derivation independently confirms is safe → honour the
  marker's tier (T0/T1 lightweight path below).
- Marker claims T0/T1 but re-derivation's **risk map** flags a risk-class
  path the marker's predicted-path set missed (scope grew between Phase 2
  and the pushed diff) → **escalate to T2**, ignore the marker. Record
  `governance_tier: T2 (escalated — marker claimed <marker>, live diff risk
  high)`.
- Marker claims T0/T1 and the live diff's own size (files touched or
  changed-line count, per the size-check table above) **materially exceeds**
  that claimed tier's threshold → **escalate one tier up** (T0 → T1, T1 →
  T2), ignore the marker's tier for sizing purposes — same doctrine as the
  risk-path-missed-a-class escalation directly above, just triggered by raw
  size instead of a risk-class path. Record `governance_tier: T1 (escalated
  — marker claimed T0, live diff size 47 files > 20)` (or the equivalent
  T1 → T2 wording), same recording convention as the risk-path escalation.
- `DIFF_RISK` (computed independently, see above) is `high` → **T2
  treatment regardless of tier**, even a T0 marker. Record both fields; note
  the override.

**Why no `--score` re-derivation.** `resolve-governance-tier.mjs`'s score leg
only matters to distinguish T0 from T1 (both already low-risk, no-spec) —
`/sge:pr-review` doesn't need that distinction beyond what the marker itself
already claims, and re-deriving a Phase-2-shaped complexity score from a raw
diff is unreliable. The **risk** leg (paths) is what re-derivation exists to
check, because a missed risk-class path is the one way a marker can be wrong
in the dangerous direction (understating risk); an inaccurate T0-vs-T1 score
call is not. The size check above does **not** reinstate score
re-derivation — it never tries to recompute a Phase-2-shaped score or
distinguish T0 from T1 on complexity grounds; it only ever fires on gross
file/line-count blowout, a coarser and orthogonal signal to both the score
and the risk map.

## Effect on this skill's phases

| Phase | T2 (unchanged) | T1 | T0 |
|---|---|---|---|
| 1 (Discovery/gates) | full | full — concurrency/hold/idempotency gates are cheap and merge-critical at every tier | full |
| 2 (specialist review) | per `DIFF_RISK` table | capped at `low`'s "reduced" row (Layer 1 + one specialist) even if `DIFF_RISK` alone would pick `medium` | capped at zero dispatch (`prose`'s row) even if `DIFF_RISK` alone would pick higher — **`DIFF_RISK: high` still overrides both caps** |
| 3 (quality gates/CI) | full | full — required CI never scales down | full |
| 4.1 requirements table | full | full | **lightweight**: changed-file-list vs. issue scope only, no per-AC evidence table |
| 4.2 traceability | full | full | advisory only (unchanged severity — never a Blocker) |
| 4.3–4.6 (adversarial/seam/design/invariants evidence gates) | per each gate's own trigger | per each gate's own trigger, **unchanged** | **skipped** — the audit-grade evidence machinery this tier exists to not pay for |
| 5.5 (thread resolution) | full | full | full — mechanical merge-gate step, and Phase 2 posted nothing to resolve |
| 6–9 (post/promote/cleanup) | full | full | full, `mode: tier0` in the verdict |

**`specialist_dispatch:`** records `skipped` (T0) / `reduced` (T1, capped) /
whatever the normal table computes (T2) — reuses the existing verdict field,
no new one needed there.

## Verdict block additions

```
mode: full | delta | phase5-passthrough | tier0 | advisory
governance_tier: T0 | T1 | T2 | absent
tier_source: marker | marker-escalated | diff-risk-override | absent
```

`marker-escalated` covers both ways a marker can be overridden upward — a
missed risk-class path, or a live diff whose size materially exceeds its
claimed tier's threshold (see "Detecting the tier" above) — deliberately
reusing the one value rather than adding a second, since the `governance_tier`
field's own parenthetical reason (`"... live diff risk high"` vs `"... live
diff size N files > M"`) already distinguishes which fired; no separate
`tier_source` value is warranted for this.

`mode: tier0` is set only when the T0 lightweight path actually ran (Phase 2
zero-dispatch, Phase 4 capped) — a T1 PR still uses `mode: full`/`delta` (it
is a normal review, just a `DIFF_RISK`-style capped one), recording its cap
via `governance_tier: T1` alone.

## `--tier0` flag (explicit override / non-`sge-implement` callers)

A repo or caller that already knows a PR is T0-equivalent (e.g. a bot-authored
formatting PR from a pipeline that never ran `/sge:sge-implement`) may pass
`--tier0` explicitly instead of relying on the marker. **Same re-derivation
rule applies** — `--tier0` sets `TIER_MARKER=T0` as input to the resolution
rule above, it does not skip re-derivation. This keeps `--tier0` from being a
weaker, unverified alias for `--advisory`-style trust.

## Composability with the `--no-fix`/`--no-automerge`/`--advisory` axis

Orthogonal, per `mode-selection.md`'s existing flags table — `--tier0
--advisory` is a valid, meaningful combination (a lightweight review that
posts a comment and claims nothing). The tier caps *how much review runs*;
the flags govern *who owns fixes/labels/merge*. Neither axis implies the
other.
