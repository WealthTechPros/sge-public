# Fleet mode — org-wide sweep

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

```
/sge:sge-align --fleet wtp/sge wtp/client-x   # explicit repos
/sge:sge-align --fleet wtp/*                  # org glob
/sge:sge-align --fleet                        # repos from docs/sge/fleet.yaml
```

Orchestrate as a **Workflow**: one **read-only audit agent per repo** (cap concurrency ~8), each of which gets the repo locally (existing checkout, else `gh repo clone --depth 1`), runs Steps 0–2 in **dry-run** (fleet agents never file/close issues) then Step 6, and returns a schema-validated Step 5 JSON (malformed → one retry, then `error` in the roll-up). The orchestrator aggregates a **fleet Audit Score scorecard** (per-repo rows worst-first, org Audit Score = mean of per-repo `audit_score`, per-check fleet pass rates) — this aggregate is the fleet **Audit Score** rollup, an operational audit signal. Since ADR-0018 (#2916) the Audit Score is the canonical SM-2 in the SGE Vision, so this rollup is the fleet SM-2 figure. Issue mutations happen only under `--apply`, sequentially, post-audit.

**Recurring cadence.** The Audit Score is a trend, not a snapshot — wrap `--fleet` in `/loop <interval> /sge:sge-align --fleet …` (weekly) and commit `docs/sge/drift-trend.jsonl` each run so the next sweep has something to diff against.
