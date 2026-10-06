# Step 4 — standalone report format

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Print a scannable table, readiest first. The **Governance** column carries the
Step-2G verdict (omit the column entirely when `--skip-governance` was passed):

```markdown
## Build-Ready Audit — <set description> (<N> issues)

| Issue | Verdict | Governance | Rationale |
|-------|---------|------------|-----------|
| #256  | READY | MATCHES_EXISTING (SPEC-088) | AC present; no open QDs; deps clear; matches SPEC-088 unchanged |
| #261  | NOT_READY `needs-decision` | NO_SPEC_WARRANTED | No acceptance criteria, no SPEC link (2A); chore, no spec needed |
| #270  | TOO_LARGE | NEEDS_NEW_SPEC | 6 independent deliverables across 3 modules (2B) → decompose; no capability maps |
| #298  | READY | MATCHES_EXISTING | AC present; deps clear; **executes in acme/web-app, not the tracking repo** (2R) |

**Build-ready:** #256, #298 · **Needs-spec:** #261 · **Too-large:** #270
**Cross-repo execution (2R):** #298 → `acme/web-app` (dispatch worktree/lock/PR there)
**Governance holds (human review):** any `MATCHES_EXISTING_MODIFIED`, `NOT_SGE_SCOPE`, `DISPATCH_FAILED`, or low-confidence match
```

Routing verdict labels (Step 3R) are always applied. If asked to record the
rationale, post it as a comment; otherwise post nothing beyond governance-trace's
own always-post exceptions and `superseded` citations.
