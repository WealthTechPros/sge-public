# Sweep-type issues — reject name-grep-only ACs (gate 2A)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

**Sweep-type issues — reject name-grep-only ACs.** A **sweep** (brand / config /
content sweep that removes or replaces a set of concrete values across many
files) whose acceptance criteria only check for *names* — e.g.
`grep -q 'wtp-logo\|WealthTech Pros'` — is a false-green trap: the name grep goes
to zero while the raw *values* the sweep removes (hex codes, font names, token
values, connection strings, vendor names) survive. In the 2026-07-06 run this let
raw brand hexes (`#eef7f8` / `#68c4cd` / `#4a4a56`) survive under a green
name-grep; only the review lane caught them (PR #846). So for a sweep issue, the
AC gate passes **only** if the criteria include **value-level checks for every
concrete value being swept, enumerated from the source of truth** (e.g.
`brand-assets/tokens.json`) — not just identifier-name greps. A sweep whose ACs
are name-grep-only → **fail** (route back for value-level ACs; `/sge:decompose-issue`
Phase 3b carries the guidance for writing them). A defect caught here costs one
grep; caught at review-time it costs a review-fix commit + a full CI re-run.
