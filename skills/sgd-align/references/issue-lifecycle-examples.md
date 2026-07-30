# Worked examples — raising and reconciling issues (Steps 3 and 4)

Full worked examples referenced from `SKILL.md` Steps 3 and 4.

## Step 3 — raising an issue from a gap record

Render each gap record's `proposedIssue`:

```bash
gh issue create \
  --title "[SGD drift] C3 Capability→Spec: CAP-CLIENT-ONBOARDING-ACCEPT has no spec" \
  --label "$LABEL" \
  --body "$(cat <<'EOF'
**Broken link:** Capability → Feature Spec (`spec_coverage`)
**Artefact:** `CAP-CLIENT-ONBOARDING-ACCEPT` (status: built) — `.claude/product-context/capability-model.yaml`
**Expected:** a `docs/features/*.md` spec carrying `capability: CAP-CLIENT-ONBOARDING-ACCEPT`
**Found:** none at audited SHA `<sha>`
**Why it matters:** a built capability with no governing spec gives AI agents and reviewers no acceptance criteria to check against — the next change drifts freely.
**Suggested fix:** write a feature spec (or run `/sgd:sgd-init`) with Gherkin acceptance criteria; or mark the capability `design` if it isn't built yet.

<!-- sgd-drift-key: C3:CAP-CLIENT-ONBOARDING-ACCEPT -->
EOF
)"
```

Respect `--max`: if there are more gaps than the cap, file the **highest-severity** first and log the deferred count — never silently truncate.

## Step 4 — mutating a reconciled issue (only under authorization)

```bash
# close with audit trail (only under authorization)
gh issue comment <n> --body "Reconciled by /sgd:sgd-align: <rationale + artefact@commit>"
gh issue close   <n> --reason "not planned"
# or re-align rather than close
gh issue edit <n> --add-label "cap:<successor>" --remove-label "cap:<old>"
```
