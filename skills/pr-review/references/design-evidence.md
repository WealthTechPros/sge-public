# Design-evidence gate — UI-touching PRs must carry a passing design-reviewer verdict

The actionable Phase 4 **design-evidence convention** for `/sge:pr-review`, held here to keep the
SKILL body within its size budget — the full mechanics behind the one-line §4.5 pointer (issue
#2235, methodology spec **SPEC-115**). Nothing here is a new control the SKILL body cannot express;
it is the detail the pointer defers.

## Why (the enforcement gap this closes)

SGD-004's static check answers "did this PR use the approved building blocks?" — a rule-matching
question. It cannot catch a page that uses every approved token and component and still reads as
generic AI-slop. SPEC-115's session-time hooks (`ui-edit-tracker.sh`, `design-gate.sh`) push an
adversarial, judgment-based review during the Claude Code session — but a session-time hook is only
as strong as the discipline of the session that ran it. Same measured-but-not-enforced gap #2206
names for governance documents, applied to design: without a merge-time check, a determined
fail-through (or an unattended run, where the hooks deliberately stand down) reaches `main` with no
design evidence at all. This gate is that merge-time backstop — the artifact-shaped complement to
`qa-audit`'s behavioural evidence (issue #732, §4.3).

## When the gate fires (UI-touching detection)

Treat a PR as **UI-touching** when the diff includes at least one file matching the UI-file glob:
`.tsx`, `.jsx`, `.vue`, `.svelte`, `.css`, `.scss`, `.less`, `.html` — the same glob
`hooks/ui-edit-tracker.sh` uses (kept in sync; if that hook's glob changes, update this list too).

**Primitives exemption:** a file under a directory literally named `primitives/`
(path-segment match, e.g. `src/landing/components/primitives/DeviceFrame.tsx`
— not a substring match like `primitives-old/`) is exempt regardless of
extension. design-reviewer's review model is inherently route-based
("screenshots affected routes" — SPEC-115 §2); a reusable non-screen
wrapper/decorative component that never renders as its own route falls
outside that model. This mirrors `hooks/ui-edit-tracker.sh`'s exemption —
kept in sync the same way as the glob above.

A PR with **no** UI-file changes is out of scope — the gate does not fire, and its absence is never
a finding (same posture as the `## Reconciliation` rule for non-data-bearing screens, and the
seam-evidence gate's single-backend carve-out).

## What the gate checks

For a PR whose diff touches the UI-file glob:

1. **A verdict artifact exists for the reviewed commit.** Check the PR body/comments for a
   `design-reviewer` verdict — either the raw `.claude/design-review/latest.md` contents pasted into
   the PR description (since that file is git-ignored session scratch, not committed), or a comment
   quoting it, timestamped/associated with a commit SHA reachable from the PR's current head. No
   artifact found → **flag**.
2. **The artifact reads `VERDICT: PASS`, or its FAIL passes the base-relative rule.** A missing
   first line → **flag**, same as a missing artifact. A `VERDICT: FAIL` is evaluated by the
   base-relative rule below; when that rule does not pass it → **flag** — never partial credit.
3. **The artifact is not stale.** If the PR has new commits after the verdict was posted that touch
   the UI glob again, the verdict no longer covers the current diff → treat as missing (mirrors the
   QA-evidence staleness rule in §4.3: a report vouches only for the commit it exercised).

### Base-relative rule for a FAIL verdict (#2837, SPEC-115 I3)

design-reviewer judges the rendered page, so a PR that edits one file on a page that already
carries design debt gets a FAIL for problems it did not introduce. Blocking that PR forces an
unrelated redesign into a small change, or teaches people to skip the gate. So design-reviewer
also scores the PR's merge-base on the same routes and viewports and tags each finding
`[introduced]` or `[pre-existing]` (`agents/design-reviewer.md`, "Base comparison"). A FAIL
verdict **passes** the gate only when all of these hold:

- a base score was actually captured (`Base: NN/16 @ <sha>`, not `Base: not captured`);
- no `[introduced]` finding scores a rubric category at 0 (an untagged 0 counts as introduced, and
  so does a category base scored higher than head);
- the head score is not below the base score.

Otherwise the FAIL **flags**. With no base captured the absolute rule applies: any FAIL flags.
A stale verdict never passes under either rule (SPEC-115 I2). Evaluate the pasted verdict with
the deterministic helper rather than by eye:

```bash
# save the verdict text from the PR body/comment to a file first
node "${CLAUDE_PLUGIN_ROOT}/scripts/design-verdict-gate.mjs" verdict.md [--stale] --json
# exit 0: pass | base-relative-pass, 1: flag, 2: bad args
```

A base-relative pass does not waive the debt. Record
`design_evidence: base-relative-pass@<commit> (head NN/16, base NN/16)` in the verdict notes and
list each `[pre-existing]` finding as a `minor` follow-up, so it stays visible in the review.

**Unattended exemption — deliberately NOT granted (SPEC-115 §"Unattended PRs still require design
evidence at merge").** A PR produced with `SGE_UNATTENDED=1` has its session-time hooks stood down by
design (`ui-edit-tracker.sh`/`design-gate.sh` both exit 0 immediately when `SGE_UNATTENDED=1`) — so
for exactly those PRs, this Phase 4.5 check is the *only* enforcement point left. Do not skip it on
an unattended PR; if anything, its absence there is more likely, not less relevant.

**Severity & posture — this finding blocks `pr-reviewed` (settled #2837).** SPEC-115 §4 said a
fresh FAIL "blocks pr-reviewed", while this file used to call it a non-blocking `major` (the
seam-evidence posture). The base-relative rule settles the conflict: since pre-existing debt no
longer fails the gate, what remains flagged is attributable to the PR (or is missing evidence), so
it blocks.

- UI-touching PR, verdict artifact **missing or stale, or a FAIL the base-relative rule does not pass** →
  `{severity:"major", category:"traceability", finding:"UI-touching PR with no passing design-reviewer verdict"}`.
  `traceability` because the finding schema has no `design` category. While this finding stands the
  review must not reach `pr-labels.sh pass` (verdict `REQUEST_CHANGES`). It clears only when a fresh
  passing verdict (PASS or base-relative pass) for the current head is posted. Phase 6.5 cannot fix it
  inline, because design-reviewer must re-run against the rendered app.
- Non-UI-touching PR → no check, nothing recorded.
- Verdict artifact **present and PASS, not stale** → record `design_evidence: pass@<commit-or-timestamp>`
  in the verdict notes; nothing to flag.
- **FAIL that passes the base-relative rule, not stale** → record
  `design_evidence: base-relative-pass@<commit>` plus head/base scores; each `[pre-existing]`
  finding becomes a `minor` follow-up; nothing blocks.

## Genericisation rule

The shipped skill and template text describe the rule only in glob-shape terms (the UI-file
extension list). It names no client or product repo — any SGE-governed repo with a UI surface maps
onto this the same way.
