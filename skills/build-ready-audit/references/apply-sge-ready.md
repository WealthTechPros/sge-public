# Step 3S: Interactive Dispatch-Label Decision (`--apply-sge-ready` only)

The full mechanics behind the SKILL body's Step 3S pointer — held here to keep
the SKILL body within its size budget (progressive disclosure, same pattern
`pr-review` uses for its `references/` files).

**This step runs only when `--apply-sge-ready` was passed.** Without the flag,
skip straight to Step 4 — the behaviour documented in Step 3R Rule 2 (READY
issues leave unlabelled, on the assumption a human already applied the
dispatch label to get them into the audit) is unchanged.

## What this flag is, and what it is not

`sge-ready` (or the repo's configured `dispatch-label`) is a **human quality
attestation** — a person judged the issue worth an agent's time — kept
deliberately separate from build-*readiness*, which this audit's Step 2 gates
already check by machine. `--apply-sge-ready` does **not** collapse that
separation by writing the label automatically. Instead it puts a **human
directly in the loop, one issue at a time**: for every `READY` issue, this
step shows the person running the audit the build-readiness gates, the
governance verdict, and a recommendation, then **stops and asks** — the human
decides whether the dispatch label gets written, held, or something else
entirely. This is closer to the SGE vision of specification-governed work
than a batch self-certifier ever was: the machine narrows and recommends, the
human still owns every write.

There is **no batch/non-interactive mode**. A prior version of this flag
self-certified automatically when a governance predicate matched — that
design is retired. If a fleet-wide sweep across many repos is ever needed
again, it means sitting through every `READY` issue across every repo, one at
a time; this flag no longer offers a shortcut around that, by design.

## Preconditions — refuse before touching any issue

- **Incompatible with `--skip-governance`.** Refuse the whole run with an
  error (not a warning) if both flags are present. Without Step 2G's verdict
  there is nothing to *recommend* against (see the recommendation logic
  below), and presenting a human with an ungoverned READY verdict as if it
  were a complete picture would be misleading, not merely automation without
  a check.
- **Human-invoked, foreground, interactive only.** `--apply-sge-ready`
  requires a live human on the other end of the conversation who can actually
  answer a question and wait for the response. It must never be honoured:
  - in **dispatched (headless) mode** (called by `/sge:available-issues` or
    `/sge:team-pipeline`'s Duration Mode, not run directly by a person);
  - **forked or backgrounded** — this skill's own frontmatter declares
    `context: fork` by default, which is the normal, correct mode for the
    rest of this audit's read-only analysis, but a forked/backgrounded agent
    **cannot** block on a human's answer. When `--apply-sge-ready` is passed,
    Step 3S must run **inline in the main conversation**, not in a fork — if
    the audit as a whole was dispatched as a fork/background task, treat the
    flag as unset for that run, report it was ignored, and say why (the
    caller should re-run interactively for the READY issues found).

  In both cases: treat the flag as absent, proceed as if it were never
  passed, and report that it was ignored and why. This is a structural
  refusal, not a prose reminder a dispatcher's prompt could omit — a headless
  or backgrounded caller has no human to actually ask.

## Mechanics (per READY issue only, human-invoked interactive runs only)

Process `READY` issues **one at a time**, in the order Step 3's table lists
them. For each:

1. Resolve the dispatch-label name via `scripts/issue-read.sh`'s
   `dispatch-label` subcommand — the same port `/sge:available-issues` uses
   (default `sge-ready` when the repo declares none). This skill's
   `allowed-tools` frontmatter must grant the script explicitly; bind it
   locally before use:
   ```bash
   IR="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/scripts/issue-read.sh"
   DISPATCH_LABEL="$("$IR" dispatch-label)" || exit 1   # fail loud on a malformed value (#1726) — never fall back to a bare "sge-ready" literal
   ```
2. If the issue **already carries** the dispatch label, skip it silently (no
   prompt) — it did not need a decision, and re-applying is a no-op. Note it
   in the Step 4 report as "already labelled", not as a decision this run made.
3. **Form a recommendation** — this is the same predicate the retired batch
   mode used to act on automatically, now demoted from a decision to
   advice: recommend **self-certify** when the Step 2G verdict is
   `MATCHES_EXISTING` or `NO_SPEC_WARRANTED` **and** `matchConfidence` is not
   `low` (the same auto-ready/human-ack split SPEC-095 §2.4 pins in
   `services/triage-pod/state.py`'s `is_auto_ready_tier`); recommend **hold**
   for every other governance verdict (`MATCHES_EXISTING_MODIFIED`,
   `NEEDS_NEW_SPEC`, `NOT_SGE_SCOPE`, `DISPATCH_FAILED`, or a low-confidence
   match) — these are spec-shaping or unresolved territory, exactly what
   Step 2G already flags as needing a human look.
4. **Present the issue and stop for the human's decision.** Show, at minimum:
   the issue number/title/URL, the four Step-2 gate results, the governance
   verdict + matched spec + confidence, the one-line rationale, and the
   recommendation from step 3 with its reasoning spelled out (do not just
   say "recommend: yes" — say *why*, citing the governance verdict). Then
   offer the human a concrete choice — do not accept free-text as the primary
   path; the options are:
   - **Self-certify** — apply `DISPATCH_LABEL` now.
   - **Hold** — do nothing; record it as a reported governance hold, same as
     an automatic hold would be (Step 3R does not touch READY issues, so no
     routing label is written — this just means "no dispatch label either").
   - **Skip / decide later** — do nothing this run, leave it for a future
     pass; distinct from Hold in the Step 4 report so a deliberate hold
     (recommendation was "no") is not confused with a deferral (no decision
     made yet).
   - **View more** — show the full issue body / comment thread / matched
     spec before deciding (loop back to this same choice afterward, does not
     consume a decision).

   The recommendation from step 3 should be the visually first/default option
   when the interface supports that, but the human's literal answer — not the
   recommendation — is what determines the outcome. **A recommendation is
   never applied by default or by timeout; every write requires an explicit
   human "yes" for that specific issue.**
5. **Apply the human's decision exactly, whichever way it goes** — including
   overriding the recommendation. Self-certifying a `MATCHES_EXISTING_MODIFIED`
   issue against the recommendation is the human's prerogative (they may know
   something the classifier doesn't); record that it was an **override** in
   the traceability comment (step 7) and the Step 5 result, so the audit
   trail is honest about which self-certifications matched the machine
   recommendation and which didn't.
   ```bash
   gh issue edit "$N" --repo "$TARGET" "--add-label=${DISPATCH_LABEL}"
   ```
6. **Never apply it to a `NOT_READY` or `TOO_LARGE` issue.** Step 3S only
   ever runs on the `READY` branch — those issues already got a routing
   verdict label in Step 3R and are not re-litigated here.
7. **Always post a traceability comment** when the human chooses self-certify:
   `Applied sge-ready via /sge:build-ready-audit --apply-sge-ready (human
   decision, interactive) — build-readiness gates passed; governance verdict
   <verdict> (confidence: <level>); recommendation was <self-certify|hold>
   <matched|overridden>.` A transient JSON field is not a durable record once
   the run ends — the comment is what lets a later reader tell an
   interactively-approved `sge-ready` apart from a human's own direct
   attestation, and tell a matched recommendation apart from an override.
8. Carry in that issue's Step 5 result: `selfCertified` (`true` only if the
   human chose self-certify and this run wrote the label), `recommendation`
   (`"self-certify"` | `"hold"`), and `humanDecision` (`"self-certified"` |
   `"held"` | `"skipped"` | `null` if already labelled/not reached).

## Never

- Never write the dispatch label without an explicit per-issue human answer
  obtained in this run. No default-yes, no timeout-applies, no "recommended
  so I proceeded."
- Never batch multiple issues into a single yes/no prompt — one issue, one
  decision, every time. Grouping "these 5 all look the same, apply to all?"
  defeats the purpose of putting a human in the loop per issue.
- Never run this step forked, backgrounded, or in dispatched/headless mode —
  see the Preconditions above. If the audit as a whole is running as a fork
  (this skill's own default `context: fork`), Step 3S must be skipped with a
  clear "requires interactive mode — re-run directly" note, never silently
  auto-decided instead.
- Never accept `--apply-sge-ready` together with `--skip-governance` — refuse
  the run (error) rather than presenting a human with a recommendation that
  has no governance verdict behind it.
- Never let the recommendation read as the decision in the Step 4 report —
  always show what was recommended **and** what the human actually chose,
  especially when they differ.
