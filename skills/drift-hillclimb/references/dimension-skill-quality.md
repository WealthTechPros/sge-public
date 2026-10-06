# Dimension: skill-quality — steps Q1–Q3

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

### Substrate it consumes (does not re-derive)

- `skills/sge-skill-audit/assets/scan-skills.sh` output — the mechanical SQ-0 (frontmatter integrity), SQ-3 (scope clarity), SQ-4 (UNTRUSTED DATA annotation), SQ-5 (tool sequencing) checks (`#737`, `#843`). Run it fresh each cycle; do not reuse a stale scan.
- `memory/skill-runs.jsonl` — `SkillRunRecord` rows (`#727`): `skill`, `verdict`, `timestamp`, … The join key back to a skill's mechanical status is the `skill` name itself (both substrates key on the skill directory name).

### Step Q1 — Measure (mechanical quality × call-record utilisation)

Run the mechanical scan, then join it with the run sidecar via the bundled scorer:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/sge-skill-audit/assets/scan-skills.sh" skills \
  --trend docs/sge/skill-quality-trend.jsonl > /tmp/skill-quality-scan.json
node "${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/drift-hillclimb/assets/score-skill-quality.mjs" \
  --scan /tmp/skill-quality-scan.json --runs memory/skill-runs.jsonl
# optional: --window-days <n> (default 30) to widen/narrow the utilisation window
```

Exit codes: `0` verdict on stdout · `1` no data to score (`--scan`'s `results[]` is empty — report "no skills found" and stop, a clean terminal state) · `2` harness/arg error. The verdict carries **two candidate lanes**, never re-implemented in prose — branch on the JSON:

- `worst` — the single highest-leverage **executability** gap: a skill whose blocked/failed/thrashing verdict rate is ≥ 50% *and* whose run count clears a noise floor (≥ 3 runs — a skill with one bad run out of one is never picked; not enough evidence). `null` when no skill clears both bars.
- `deprecationCandidates[]` — skills with **zero runs in the window** (default 30d), regardless of historical volume — a skill that ran heavily last quarter but not at all this month still qualifies. Never a signal to delete; see Step Q2.
- `perSkill[]` — the full per-skill breakdown (mechanical SQ-0/3/4/5 status + run/verdict/thrash-rate numbers) for the report and for `sge-skill-audit`-style deep dives.

### Step Q2 — Act (bounded PR + deprecation issues, never auto-delete)

Two independent actions, run in the same cycle:

- **Executability lane (PR-bound):** take `worst.skill` and open **one** PR that is the smallest root-cause fix raising its executability — tightening ambiguous instructions, adding the missing tool-sequencing/scope-clarity section a mechanical SQ finding names, or correcting a broken tool call the blocked/failed verdicts point at. Dispatch to `/sge:sge-implement` or a direct fix agent, same as any other gap. One skill → one branch → one PR through the normal merge gate (CI + `/sge:pr-review`); this loop never merges its own PR. `--dry-run` stops here and prints the PR that *would* be opened.
- **Utilisation lane (issue-only, unbounded by the PR round):** for each entry in `deprecationCandidates[]`, check for an already-open `deprecation-candidate` issue for that skill (idempotent — the shared Governor's dedupe rule) and, if none exists, open one summarising the zero-run window and the skill's last-run timestamp. **Never delete or archive the skill file** — that decision is a human's, exactly like a C13 content-drift gap; the issue is the artifact, not an autonomous removal. `--dry-run` prints the issues that *would* be opened instead of creating them.

### Step Q3 — Re-measure & trend

Next cycle, re-run Step Q1 (independent Verifier — never the implementing agent's self-report) and diff `worst.thrashRate` and `deprecationCandidates.length` against the prior cycle. The scorer emits a `trendRow` (`dimension`, `repo`, `timestamp`, `deprecationCandidateCount`, `worstSkill`, `worstThrashRate`, `skillsScanned`, `skillsFailingMechanical`); **append it to the canonical skill-quality trend plane `docs/sge/skill-quality-trend.jsonl`** (create `docs/sge/` if missing — `scan-skills.sh --trend` already appends its own dated mechanical row there each run) and commit it via `/sge:commit` so "worst-skill thrash rate 80% → 40% → 10%, deprecation candidates 6 → 3 → 1 over three cycles" is provable.

> This dimension shares its trend file with `scan-skills.sh`'s own `--trend` rows (both are skill-quality-plane facts), but writes a **sibling** file to `docs/sge/drift-trend.jsonl` — an Audit Score scorecard row and a skill-quality row carry different shapes, exactly as the token-economy dimension keeps its own plane.
