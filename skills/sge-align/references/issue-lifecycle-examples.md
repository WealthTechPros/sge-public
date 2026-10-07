# Worked examples — raising and reconciling issues (Steps 3 and 4)

Full worked examples referenced from `SKILL.md` Steps 3 and 4.

## Step 3 — raising an issue from a gap record

Render each gap record's `proposedIssue` through the search-before-file seam (#2647) — `$IW create-deduped` searches open items first, returns the existing ref on an exact-title match and prefixes `Possible duplicate of #N` on a near match (the `sge-drift-key` dedupe still runs first; this also catches a human-filed twin):

```bash
IW="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/scripts/issue-write.sh"
N=$("$IW" create-deduped \
  "[SGE drift] C3 Capability→Spec: CAP-ORDER-CHECKOUT has no spec" \
  "$(cat <<'EOF'
**Broken link:** Capability → Feature Spec (`spec_coverage`)
**Artefact:** `CAP-ORDER-CHECKOUT` (status: built) — `.claude/product-context/capability-model.yaml`
**Expected:** a `docs/features/*.md` spec carrying `capability: CAP-ORDER-CHECKOUT`
**Found:** none at audited SHA `<sha>`
**Why it matters:** a built capability with no governing spec gives AI agents and reviewers no acceptance criteria to check against — the next change drifts freely.
**Suggested fix:** write a feature spec (or run `/sge:sge-init`) with Gherkin acceptance criteria; or mark the capability `design` if it isn't built yet.

<!-- sge-drift-key: C3:CAP-ORDER-CHECKOUT -->
EOF
)" --search "CAP-ORDER-CHECKOUT")
gh issue edit "$N" --add-label "$LABEL"   # create-deduped takes no --label
```

Respect `--max`: if there are more gaps than the cap, file the **highest-severity** first and log the deferred count — never silently truncate.

## Step 4 — mutating a reconciled issue (only under authorization)

```bash
# close with audit trail (only under authorization)
gh issue comment <n> --body "Reconciled by /sge:sge-align: <rationale + artefact@commit>"
gh issue close   <n> --reason "not planned"
# or re-align rather than close
gh issue edit <n> --add-label "cap:<successor>" --remove-label "cap:<old>"
```
