# Review record (read in preference to comment markers)

`/sge:pr-review` writes one [review record](../../../docs/schemas/review-record.schema.json) per PR at
verdict time to `.sge/review-records/<pr>.json` on the PR branch (sge#3322, ADLC epic sge#3320).
When the record exists, read the tier and the verdict from it. The PR-body markers
`sge-governance-tier` and `sge-phase5-verdict` are the fallback for PRs that predate the record.

```bash
node "$SGE_ROOT/scripts/review-record.mjs"   # exports resolveTierAndVerdict({ record, markers })
```

`resolveTierAndVerdict` returns `{ tier, verdict, source }`, where `source` is `review-record`,
`markers` or `none`. `/sge:regulatory-trace` follows the same order.

## What the record holds

Issue, spec id, governance tier (resolved and declared floor), the `pr-review` verdict and depth,
eval results, policy checks run, the model id and plugin version used (both pinned), a human
decision reference and timestamps. The human decision is never free text: it is a GitHub review
approval id (`github-review`, required for T2 or a declared T2 floor) or `sampled` / `auto` for T0/T1.

Validate with `node "$SGE_ROOT/scripts/check-artefact-schemas.mjs" --repo <target> --json`
(`/sge:sge-align` C42 covers `.sge/review-records/`). Retention and who writes what:
`docs/compliance/review-records.md` in the sge source repo.
