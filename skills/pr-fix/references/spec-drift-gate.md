# Spec-drift gate failures

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Spec-drift gate failures — control-preserving resolution

When a **spec-drift gate** fails (a CI check that detects changed code mapped to a spec whose acceptance criteria have not been updated), the default instinct to reach for the `spec-unchanged` bypass label **must be resisted**. Using the bypass without justification erodes governance over time: lanes get cleared by weakening controls rather than by fixing the spec.

Resolve spec-drift failures in this order — **always attempt step 1 first; only fall back to step 2 when step 1 is genuinely inapplicable**:

### Step 1 — Add the acceptance criterion to the owning spec (preferred)

The changed code implies a behaviour change. The correct fix is to capture that behaviour in the spec:

1. **Identify the owning spec** — the gate output will name the spec file (e.g. `specs/SPEC-NNN.md`). Read it.
2. **Propose a new or updated AC** — draft the acceptance criterion that describes the new/changed behaviour. Keep it in the existing Gherkin `Given / When / Then` style used by the spec.
3. **Add the source-citation fragment** — follow the repo's `.sources/` / changelog convention to link the spec AC to the PR as evidence (check `CLAUDE.md` for the exact format).
4. **Commit the spec change** on the PR branch (honouring the repo's commit convention, including the `commit-msg` hook — see *Commit conventions* above). The trailer must reference the spec: e.g. `SPEC-NNN`.
5. Re-run the spec-drift gate locally if possible; push once the gate would pass.

### Step 2 — Apply the `spec-unchanged` bypass label (exception only)

Apply this label **only** when the changed behaviour is already fully captured by an existing AC and no new AC is needed. Before applying it:

1. **Post a PR comment** explaining why no AC update is needed — quote the existing AC that already covers the changed behaviour and explain why it subsumes the change.
2. **Apply the label** `spec-unchanged` — this signals to the governance audit that the drift was reviewed and judged non-material.
3. **Human sign-off required** — the `spec-unchanged` label is logged as an exception in the governance-posture audit trail (`/sge:sge-align` surfaces it as an override requiring human confirmation). Do not rely on it to auto-clear a review gate; a human reviewer must confirm the label is warranted before the PR can merge.

### Anti-pattern — never use bypass as the default

Do **not** apply `spec-unchanged` as a quick way to clear a spec-drift gate. The same principle that bars `--no-verify` on the commit hook applies here: the gate is a control, not an obstacle. If you cannot identify the correct spec AC addition because the spec is ambiguous or the change is unclear, stop and raise it with the human rather than defaulting to bypass.

---
