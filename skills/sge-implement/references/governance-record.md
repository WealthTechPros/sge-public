# sge-implement — the governance record (SPEC-128, sge#3254)

After Phase 0.5 resolves a **fresh** governance classification, post one
governance record on the issue. It is evidence that the change was classified,
not an approval. A repo whose `.sge/posture.yaml` says `enforcement: enforced`
fails a pull request that closes or implements an issue with no record
(`Require enforcement profile`, SPEC-128); under `onboarding` that is a notice.
So an agent-built PR satisfies the gate by construction.

No marker or approval is required to start a build. Never wait for a record,
never ask for one first, and never read one back: an existing record is not
adopted as a verdict, exactly like any other issue comment (Phase 0.5, SPEC-126).

## When

- **Fork path.** After the governance-trace fork's verdict is joined and the
  human has chosen on a blocking verdict (`NEEDS_NEW_SPEC`,
  `MATCHES_EXISTING_MODIFIED`), i.e. when the build goes ahead. A cancelled or
  headless-blocked run posts nothing.
- **Inline trivial path.** The inline classification posts too: build the same
  object from it (`issue`, `repo`, `verdict`, `matchedSpec`).
- Unattended runs post it as well. It is an ordinary comment, not a human
  decision.

A verdict with `cacheReused: true` is not a fresh classification and never
becomes a record (the script refuses it).

## Command

Run from the target repo's checkout (SPEC-057), once, right after the verdict:

```bash
VF="$(mktemp)"; printf '%s' "$VERDICT_JSON" > "$VF"   # the Step-7 object (issue, repo, verdict, matchedSpec)
"$SGE_ROOT/scripts/with-repo-cwd.sh" assert-repo "$TARGET" -- \
  bash "$SGE_ROOT/scripts/governance-record.sh" post "$ISSUE" "$VF"
```

`governance-record.sh post` writes an ordinary issue comment through
`scripts/issue-write.sh comment` (GitHub, Azure DevOps or Jira). It goes through
`$SGE_AUTHOR_WRAPPER` when the org names one ([`author-identity.md`](author-identity.md)),
so the comment is the agent App's, never a human's. It is idempotent: when the
issue already holds a record with the same fields (everything but `at`) nothing
is posted, so a resumed lane or a re-run never reposts an identical record.

## Shape

One marker line in the comment:

```text
<!-- sge-governance: {"issue":N,"repo":"owner/repo","verdict":"NEEDS_NEW_SPEC","matchedSpec":null,"mainSha":"<hex>","at":"<ISO-8601 Z>"} -->
```

The fields are the governance-trace Step-7 echo (`issue`, `repo`, `verdict`,
`matchedSpec`) plus the default-branch sha and a timestamp. The gate checks it
for existence and shape only, never for who wrote it.

## If the post fails

A failed post does not stop the build. Report it in the PR body: the PR gate
names the issue and the fix (`/sge:issue-intake <N> --record`, which anyone can
run) if the record is still missing under `enforced`.

## Spec-first

When the recorded verdict is `NEEDS_NEW_SPEC` or `MATCHES_EXISTING_MODIFIED`, the
PR must add or amend the spec file. That is already what those verdicts mean in
Phase 0.5; the CI gate now checks it at the pull request.
