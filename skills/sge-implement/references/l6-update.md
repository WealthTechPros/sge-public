# Phase 8.1 — L6 UPDATE (close the audit chain, spec lane)

Moved from `SKILL.md` Phase 8.1 (issue #2825). `SKILL.md` keeps a stub; the full steps live here.

## L6 UPDATE — close the audit chain (spec lane)

After merge, update the governed artefacts so QD → SPEC → SHA traces end-to-end:

1. **Spec status** — mark the spec implemented (per repo convention), referencing the PR and merge SHA.
2. **Capability model** — update the capability entry the spec serves (status/links; per repo CLAUDE.md).
3. **DAG manifest** — mark the spec's node built so downstream dependency checks see reality. If the repo declares a DAG-regeneration script (`/sge:commit` step 1.5 auto-runs it against the staged diff), this happens automatically when committing steps 1–2 — don't hand-edit `docs/sge-dag.json` when a generator owns it.
4. **Requirement-change rewrite** (only if Phase 0.5 returned `MATCHES_EXISTING_MODIFIED`) — rewrite each `requirementChanges[]` clause to its `proposed` text verbatim, not just the status field, in the same commit as the status update — the human acknowledged it in Phase 0.5, so the doc changes alongside the code.

Commit these via `/sge:commit` with the `Spec: SPEC-NNN` trailer — a docs-only change; branch + PR if main is protected. (No-spec lane: skip.)
