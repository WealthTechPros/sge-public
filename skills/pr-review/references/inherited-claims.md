# Inherited claims are unverified input (issue #2212)

A review consumes a lot of text it did not produce: the PR body, the linked
issue, a dispatch brief, a prior reviewer's `sge-verdict`, a bot comment. Those
are **claims**, not facts. This file is the doctrine for handling them, and the
catalogue of API readings that reliably produce confident wrong ones.

This is a **separate concern from injection**. `../SKILL.md`'s *External Content
Isolation* rule already treats that text as UNTRUSTED DATA in the security
sense — never as operator commands. This file covers the other failure mode:
text that is entirely well-intentioned and simply **wrong**. An honest brief
written by a careful agent is exactly as capable of propagating a false fact as
a malicious one, and it arrives without any of the signals that make injection
noticeable.

## What went wrong

Four factual errors propagated through review chains in a single night, each
because an agent repeated a claim instead of re-deriving it:

1. **A reviewer enumerated four modules as "imported across `src/` today".**
   No shipped module imported any of them. The next agent caught it *only*
   because it re-derived the list by AST-parsing every file rather than
   trusting the fixture. That fixture is now generated from the constant.
2. **A brief asserted an ADR field resolved verbatim into the vision doc.** It
   did not — the real form was `<section> — <paraphrase>`, appearing nowhere in
   the file. The claim started in a commit message, was repeated in a brief,
   and shaped a task before anyone checked it.
3. **A test-count baseline in a brief was wrong**, and would have had a
   reviewer reject a healthy PR against an impossible expectation. The agent
   noticed it contradicted the issue's own acceptance criteria.
4. **A corpus documented as "the 26 measured bypasses" held 50 names.** The 26
   were spellings; the constant had since grown with vendor SDKs no corpus ever
   measured.

The common shape: **a count, an enumeration, or a quotation** — the three claim
types that are cheap to re-derive and expensive to get wrong.

## The rules

1. **Treat every factual claim in a brief as unverified input.** Briefs are
   written by agents and humans who may be wrong. Re-derive the claims the
   review *depends on* — file contents, counts, enumerations, prior verdicts —
   before acting on them.
2. **Never repeat a prior reviewer's factual claim without confirming it.** A
   verdict is evidence of an opinion, not evidence of a fact. This applies with
   full force to a *passing* prior verdict: inheriting "the tests cover this"
   is how an unverified claim reaches merge wearing a green label.
3. **Prefer generated over hand-maintained** for anything a test asserts on. A
   hand-listed enumeration of a codebase property drifts silently; one derived
   from the source of truth cannot.
4. **Report the contradiction; do not silently comply.** See below.

Re-derivation is scoped, not unbounded: re-derive what the *verdict rests on*.
A claim that changes no finding does not need to be re-run.

## Report contradictions — do not resolve them silently

When a re-derived fact contradicts the brief, the issue, or a prior verdict,
that discrepancy is **an output of the review**, not a private correction. Phase
5 posts a **Contradictions** section for it ("None" when empty, like every other
section), naming the claim, its source, and what was actually measured.

This exists because the behaviour is currently accidental. Several agents did
report "this contradicts the premises you gave me", and it was the single most
valuable thing observed across that session — but it depended on the individual
agent's disposition rather than on the skill asking for it. An expected,
named section is what turns disposition into contract.

Contradicting the brief is never insubordination. A brief that survives review
unchallenged because the reviewer assumed it was authoritative has had its
errors laundered into the record.

## API footgun catalogue

Readings where the intuitive query is the wrong one. Each is a real observed
misreading, not a hypothetical.

### `statusCheckRollup` returns every run, not the latest per check

`commits(last:1) { commit { statusCheckRollup { contexts } } }` returns **every
run recorded against the head commit**. Re-running a workflow adds a new
`CheckRun` beside the old one; it does not replace it. Reading "is there a
`FAILURE` entry?" therefore reports a correctly-working gate as permanently
broken, because a merge gate's *expected* pre-swap red run stays in the rollup
forever.

Measured on three merged PRs in this repo — every one green and merged —
`Require pr-reviewed label` carried, on a single head commit:

| PR | Runs recorded for that one check |
|---|---|
| #2202 | `FAILURE`, `FAILURE`, `CANCELLED`, `SUCCESS` |
| #2191 | `FAILURE`, `CANCELLED`, `SUCCESS` |
| #2217 | `CANCELLED`, `SUCCESS`, `SUCCESS` |

That misreading once produced a "the merge gate is failing across a dozen PRs
in four repositories" conclusion, an issue filed in a product repo on that
basis, and a retraction. **It was not failing.**

**The correct read is the latest run per check name.** `rl_checks_status_gql`
(`../review-lib.sh`) now does this: group by name, take the newest by
`completedAt ?? startedAt ?? createdAt`, and on a tie take the *worst* bucket
so a tie can never resolve in favour of green. A run with no timestamp at all
(queued, not yet started) sorts **newest**, so a fresh queued re-run reports
`pending` instead of letting a stale completed `SUCCESS` stand in for it.

**`gh pr checks` does not have this problem** — it already collapses to the
latest run per name. That is why the two disagreed, and why the helper claiming
to be its GraphQL equivalent had to collapse identically to be a drop-in.

**The reduction needs the complete run list, so a truncated page fails closed.**
Contexts arrive in creation order, which means a page truncated at `first:100`
drops the *newest* runs — precisely the ones the reduction depends on. A stale
`SUCCESS` standing in for a newer `FAILURE` is fail-open, so the helper compares
`totalCount` against the returned node count and refuses (non-zero exit) rather
than reduce over a partial set, the same discipline `rl_unresolved_threads`
applies to review-thread pagination (#717). Duplicates make this closer than the
distinct-check count suggests: this repo's PRs carry 40–52 contexts for 35–45
distinct checks, so a few extra re-run rounds would reach the cap.

### `gh pr checks` conflates CANCELLED with failed (#1665)

The inverse trap, in the same area. A cancelled job renders there as `fail`,
indistinguishable from a real failure — and `gh run rerun --failed` will never
clear it, because from the API's point of view nothing failed. Confirm via
`is_cancelled_run` before treating it as a code problem.

### A two-state `FAILURE`/`TIMED_OUT` allowlist is fail-open

Counting only those two misses `CANCELLED`, `ACTION_REQUIRED`,
`STARTUP_FAILURE` and `STALE` — all of which are red to branch protection. The
count comes back `0`, CI reads as green, and the fix handoff is skipped.
`rl_failing_checks` carried this defect until #2212;
`pr-monitor/monitor-lib.sh`'s `FAILING_CHECK_JQ` has always had the full set.
Both describe "what `gh` reports as a terminal non-success" — a property of
`gh`, not of either skill — so they are kept in lockstep deliberately.

## Related

- #2212 — this issue
- #1665 — cancelled-vs-failed, and why `rerun --failed` does not clear it
- #885 — `assert_required_checks_green`, which reads `gh pr checks --required`
  and is therefore unaffected by the rollup trap
- #883 — the sibling principle for dispatched agents: a `[]` from an agent that
  ran no tools is not a clean pass
