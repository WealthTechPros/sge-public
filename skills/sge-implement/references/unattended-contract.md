# Unattended contract (`SGE_UNATTENDED=1` or `--unattended`) — SPEC-093

Moved here from the removed `/sge:implement-issue` router (#2915). `/sge:team-pipeline`
lanes embed the same contract in their dispatch prompt.

When unattended mode is active, `/sge:sge-implement` **must never end a turn with a clarifying question.** A question posed to no one stalls a headless run until morning; permissions being pre-granted (`--dangerously-skip-permissions`) does not make the run *decide*, and deciding is what this contract adds.

On any ambiguity, resolve it by this three-tier policy, tried **strictly in order**:

- **(a) Apply the spec's (or issue's) decision rules.** If the governing spec or the issue body states a decision rule or default that resolves the ambiguity, apply it and continue.
- **(b) Else take the most-reversible option, and log it.** When no rule applies, choose the option cheapest to undo later (draft PR over merge, additive over destructive, narrower scope over broader), record the decision **and its rationale** to the run-report **decision journal** (`{specId, trigger, optionTaken, rationale}` — schema: `run-report/decision-journal.md` (SGE source repo: `skills/run-report/decision-journal.md`)), and continue.
- **(c) Else write a BLOCKED report and exit cleanly.** When genuinely blocked — a missing credential, a failed precondition, or a **regulated-output boundary** (per `SPEC-071`) — do not guess. Write a BLOCKED report naming *exactly* what a human needs to unblock it, and exit cleanly for morning triage. BLOCKED report schema: `run-report/decision-journal.md` (SGE source repo: `skills/run-report/decision-journal.md`).

**Blocked-fast at the regulated boundary.** A regulated-output boundary is **always** tier (c), **never** tier (b) — the most-reversible-option fallback does not apply there, and the run must never auto-continue past it. Blocked-fast is the correct behaviour, not a failure.

Every AskUserQuestion option gate in the skill becomes a tier (a)/(b)/(c) decision under this contract. The intake gate (Phase −1) and a blocking governance verdict (Phase 0.5) are always tier (c): never run `/sge:issue-intake` headless and never auto-approve a spec change.

Attended runs (neither `SGE_UNATTENDED=1` nor `--unattended`) are unchanged and may still end a turn with a clarifying question. The `Stop`-hook backstop, the spec-template "Decision rules & defaults" section, and the questions-per-run metric are sibling slices of the same epic (#1120) — this contract is the behaviour they enforce and measure.
