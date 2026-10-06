# Dimension: token-economy — steps T1–T3

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

### Substrate it consumes (does not re-derive)

- `memory/token-usage.jsonl` — `TokenUsageRecord` rows (the plugin's metering hook, sge#726).
- `memory/skill-runs.jsonl` — `SkillRunRecord` rows: `skill`, `verdict`, `sessionId`, … (sge#727). The join key back to token spend is `sessionId`.
- roi-report output (optional) — the **org-wide** `governedValuePerToken`. This dimension **owns the per-skill breakdown only**; it never edits or re-implements `skills/roi-report` (sge#823 owns that number). Pass it through with `--roi`.

### Step T1 — Measure (worst skill×outcome ratio)

Run the bundled scorer, which joins the two sidecars and ranks skills worst-first. Governed value = successful runs (`merged | pass | ready | done | approved`); a skill's value-per-token = successes ÷ tokens spent, so the **worst** skill is the one with the most tokens per success (a skill that spent tokens but shipped nothing is Infinity — worst by construction):

```bash
node "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/drift-hillclimb/assets/score-token-economy.mjs" \
  --usage memory/token-usage.jsonl --runs memory/skill-runs.jsonl
# optionally feed the org baseline from roi-report:
#   /sge:roi-report | … > roi.json ; then add:  --roi roi.json
```

Exit codes: `0` verdict on stdout · `1` no telemetry yet (report "no token-economy telemetry" and stop — a clean terminal state) · `2` harness/arg error. The verdict's `worst` object names the skill to fix, its `tokensPerSuccess`, and a `recommendedLever`; `skillsWithoutTelemetry` lists skills with runs but no attributable spend (reported honestly, never the worst pick). Do **not** re-implement this scoring in prose — branch on the script's exit code and read its JSON, exactly as Step 1 consumes `sge-align`'s JSON.

### Step T2 — Act (one bounded PR, the recommended lever)

Take the `worst.skill` and open **one** PR that pulls `worst.recommendedLever`:

- `prune-prose-to-references` — the skill is prompt-dominated (≥70% input tokens): move stable prose into `references/` the skill loads on demand, shrinking the per-run prompt.
- `extract-script` — the work itself is the cost: extract the skill's deterministic steps into a bundled `assets/*.mjs|*.sh` the skill *calls* instead of reasoning through token-by-token (this very scorer is that pattern).
- `demote-model-tier` — a premium tier (opus) dominates the skill's spend for work a cheaper tier handles: pin the lower tier for that skill's sub-agent.

One skill → one branch → one PR through the **normal merge gate** (CI + `/sge:pr-review`); this loop never merges its own PR and never weakens the signal (no deleting the telemetry hook, no lowering a threshold to make the number move). `--dry-run` stops here and prints the PR that *would* be opened. Only pull one lever per cycle — bounded to one PR, exactly like the Audit Score climb.

### Step T3 — Re-measure & trend

Next cycle, re-run the scorer (independent Verifier — never the implementing agent's self-report) and diff `worst.tokensPerSuccess` against the prior cycle. The scorer emits a `trendRow` (`dimension`, `repo`, `timestamp`, `worstSkill`, `worstTokensPerSuccess`, `worstValuePerToken`, `orgGovernedValuePerToken`); **append it to the canonical token-economy trend plane `docs/sge/token-economy-trend.jsonl`** (create `docs/sge/` if missing) and commit it via `/sge:commit` so "pr-review 5000 → 3200 → 1900 tok/success over three cycles" is provable.

> This dimension writes a **sibling** trend file, not `docs/sge/drift-trend.jsonl`. That file's rows are Audit Score scorecards whose row shape (`audit_score` integer + `checks[]`) the next full sweep's delta arithmetic depends on — `/sge:sge-align` deliberately **skips** appending in its own `--dimension` standalone modes for exactly this reason. A token-economy row carries no `audit_score`, so it lands in its own canonical plane; both are durable, committed trend files under `docs/sge/`.

Stop conditions are the shared Governor's: target tokens/success reached, `--max-rounds`, two sub-`--min-gain` cycles (no-progress), a lever that fails CI twice (thrash → abandon, report), or budget. Print the same ten-second report, keyed on tokens/success instead of Audit Score, and always state the stop reason.
