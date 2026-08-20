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
2. **The artifact reads `VERDICT: PASS`.** A `VERDICT: FAIL` or missing first line → **flag**, same
   as a missing artifact — do not treat a FAIL as partial credit.
3. **The artifact is not stale.** If the PR has new commits after the verdict was posted that touch
   the UI glob again, the verdict no longer covers the current diff → treat as missing (mirrors the
   QA-evidence staleness rule in §4.3: a report vouches only for the commit it exercised).

**Unattended exemption — deliberately NOT granted (SPEC-115 §"Unattended PRs still require design
evidence at merge").** A PR produced with `SGE_UNATTENDED=1` has its session-time hooks stood down by
design (`ui-edit-tracker.sh`/`design-gate.sh` both exit 0 immediately when `SGE_UNATTENDED=1`) — so
for exactly those PRs, this Phase 4.5 check is the *only* enforcement point left. Do not skip it on
an unattended PR; if anything, its absence there is more likely, not less relevant.

**Severity & posture** (consistent with Phase 4.2's advisory-for-non-SGE stance and the seam-evidence
gate's major-not-blocker posture):

- UI-touching PR, verdict artifact **missing, stale, or FAIL** →
  `{severity:"major", category:"traceability", finding:"UI-touching PR with no passing design-reviewer verdict"}`.
  A `major` does not by itself refuse a `pass`, but it is a fix-inline / comment finding the verdict
  must carry — never silently dropped.
- Non-UI-touching PR → no check, nothing recorded.
- Verdict artifact **present and PASS, not stale** → record `design_evidence: pass@<commit-or-timestamp>`
  in the verdict notes; nothing to flag.

## Genericisation rule

The shipped skill and template text describe the rule only in glob-shape terms (the UI-file
extension list). It names no client or product repo — any SGE-governed repo with a UI surface maps
onto this the same way.
