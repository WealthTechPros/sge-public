# decompose-issue — parent DAG comment example

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

```bash
"$IW" comment "$PARENT" "$(cat <<'EOF'
## Decomposed into parallel-safe sub-tasks

**Complexity:** 41 (Large) — split warranted.

| Child | Role | DependsOn | Parallel-safe with |
|-------|------|-----------|--------------------|
| #401 E1 | Enabler — migration + model + service shell | — | — |
| #402 S1 | CSV ingest + validation | #401 | S2, S3 |
| #403 S2 | Field mapping UI | #401 | S1, S3 |
| #404 S3 | Async job runner + progress | #401 | S1, S2 |

**Build order:** E1 first (foundation). Once #401 merges, S1/S2/S3 fan out — 3 concurrent lanes, no file overlap. No serialised pairs.

**Hand-off:** `/sge:team-pipeline` to fan the slices out, or `/sge:sge-implement <child>` one at a time.

_Decomposed via `/sge:decompose-issue`._
EOF
)"
```
