# Closure integrity (Phase 4.1.1, issue #2221)

Two governance issues in a seeded repo were closed as `COMPLETED` by merged
PRs, and neither was complete. One had four acceptance criteria; the PR that
closed it shipped one capture instrument and left three unmet — including a
named fallback that does not exist. The other retired roughly half a
capability issue and closed it anyway, asserting a local-inference capability
that had never run a single token. Both were caught only by a manual sweep
after merge. In both cases the PR body itself said the issue was not
complete — the information needed to prevent the close was already in the
same artefact that triggered it.

The reviewer already has the linked issue's acceptance criteria and the diff
in hand from 4.1 — the natural place to ask "does this PR actually close what
it claims to close?" rather than let a keyword close it unexamined.

## The two checks

Run both, using the same requirements table 4.1 already built.

**1. Unmet criteria + closing keyword.** If the PR carries a closing keyword
(`Closes`/`Fixes`/`Resolves #N`) for the linked issue AND 4.1's own table has
any row marked ❌ (unimplemented), that is a BLOCKER on its own — independent
of the per-row blockers already raised for those same rows. Closing an issue
with unmet acceptance criteria asserts a state that is not true. State which
rows are unmet and recommend the PR use `Refs #N` (or `Part of #N`) instead
until they are addressed, or that it check off/evidence the remaining rows in
this same PR.

**2. Contradiction (hard block, always).** If the PR body says — in
substance — that the linked issue should stay open, remain open, or is not
yet complete/done/finished, while the PR also carries a closing keyword for
it, that is a machine-detectable self-contradiction: BLOCKER regardless of
the 4.1 table's state. Even an all-✅ table does not excuse a PR that says in
its own words the issue isn't done — the contradiction is with the PR's own
closing action, not with the criteria. Quote the contradicting sentence in
the finding.

## Relationship to the CI gate

This mirrors `.github/scripts/check-issue-closure-integrity.sh` — the
repo-local CI gate that runs the same two checks mechanically (offline
suite: `check-issue-closure-integrity.test.sh`). The reviewer catches it here
even on a repo/PR path the CI gate doesn't cover (a repo that hasn't adopted
the gate yet, or a closing keyword the gate's detection missed), and should
not wave a PR through on the assumption "CI would have caught it" — the
review is a second, independent check, not a rubber stamp on the gate's
result.

Deliberately separate from the tracking-close-keyword gate
(`check-tracking-close-keyword.sh`, #2265/#2242): that one blocks a PR
closing an issue labelled `tracking`/`epic` (an umbrella no single PR
satisfies) and is keyed on a **label**. This check is keyed on the target
issue's **own acceptance-criteria checklist and PR-body language**, and
applies to any issue — tracking or not. Both may fire on the same PR; they
are complementary, not redundant.

## Scope note

Fleet-wide gate-coverage registration (a `G5` entry in
`check-gate-coverage.sh`, alongside `sge-align`'s existing G1–G4) is
deliberately **not** part of this change — extending that catalogue changes
the score formula (`/4` → `/5`) and every hardcoded score assertion in its
contract test (`skills/tests/check-gate-coverage.test.sh`), which is a wider,
higher-risk edit than this slice warrants. Track as follow-up work, the same
two-PR shape #2242 (writer-side fix) → #2244 (G4 distribution) already used.
