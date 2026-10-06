# decompose-issue — child-issue creation examples

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

```bash
IW="${CLAUDE_PLUGIN_ROOT:-.}/scripts/issue-write.sh"
PARENT=312
SPEC=SPEC-027

E1=$(JIRA_ADAPTER_ALLOW_CREATE=1 "$IW" create-deduped \
  "${SPEC}-E1: Enabler — Migration + Model + Service Shell + Types" \
  "$(cat <<EOF
Parent: #${PARENT}
DependsOn: —
Owns: db/migrations/*import*, models/import_job.*, services/import_service.* (shell only)

Technical foundation only — no user-facing output, no TDD required.
Verified by: migration runs and rolls back cleanly, types compile, module resolves, lint passes.
EOF
)")
gh issue edit "$E1" --add-label "sge,enabler"   # GitHub path; Jira labels are S4 (P9)

JIRA_ADAPTER_ALLOW_CREATE=1 "$IW" create-deduped \
  "${SPEC}-S1: CSV ingest + validation (TDD)" \
  "$(cat <<EOF
Parent: #${PARENT}
DependsOn: #${E1}
Owns: services/import_service.parse*, parsers/csv.*, tests/csv_*
ParallelSafeWith: S2, S3
ConflictsWith: —

One vertical slice. Strict TDD: failing test → minimum implementation → passing test.
Acceptance criterion: <the specific criterion this slice satisfies>
<!-- Sweep child only: AC includes value-level greps for every concrete value being swept, enumerated from the source of truth (e.g. brand-assets/tokens.json) — not just name greps. -->
EOF
)"
```
