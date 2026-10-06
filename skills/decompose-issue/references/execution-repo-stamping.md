# decompose-issue — execution-repo stamping (SPEC-057, #863/#1024)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

A parent decomposed from a hub can have children whose deliverable lives in a
**different** repo than the parent's tracking repo — the `sge#798` shape: the
tracking issue sat in `sge`, but the deliverable belonged in `web-app`
(and a real decomposition's children `sge#839/#840` executed in the org hub repo).
Without a signal, the pipeline assumes each child executes in the parent's repo
and sets up the worktree/branch/PR there — the wrong place.

So **stamp `Repo: owner/name` on every child whose execution repo differs from
the parent's tracking repo.** Use the canonical grammar (short `Repo:` form,
value MUST be `owner/name` or a GitHub URL) — do NOT hand-roll a variant. It is
the same field `/sge:team-pipeline` and `/sge:fleet-dispatch` HONOR when they
target the worktree/branch/PR (via `scripts/with-repo-cwd.sh issue-repo`), and
the grammar/parser is defined once in
[`docs/skill-authoring-repo-context.md`](../../../docs/skill-authoring-repo-context.md).
Children that execute in the parent's repo carry `Repo: —` (or omit the field).

Worked example — a child whose deliverable lives in another repo (the `sge#798`
shape), stamped so team-pipeline routes its worktree/PR to `owner/other-repo`:

```bash
S4=$(JIRA_ADAPTER_ALLOW_CREATE=1 "$IW" create-deduped \
  "${SPEC}-S4: Wire the adviser allowlist (TDD)" \
  "$(cat <<EOF
Parent: #${PARENT}
DependsOn: #${E1}
Repo: owner/other-repo            # executes here, not in the parent's repo
Owns: app/allowlist/*, tests/allowlist_*
ParallelSafeWith: S1, S2
ConflictsWith: —

One vertical slice whose deliverable lives in owner/other-repo. Strict TDD.
Acceptance criterion: <the specific criterion this slice satisfies>
EOF
)")
gh issue edit "$S4" --add-label "sge,story"
```

Status/labels (including `agent-lock`) stay on the tracking child issue created
here; only the worktree/branch/PR follow the stamped `Repo:` — that split is the
honoring contract team-pipeline/fleet-dispatch implement.
