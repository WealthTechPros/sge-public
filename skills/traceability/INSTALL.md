# SGD Traceability Module — Install Guide

Adds an interactive PR traceability chart to any SGD-governed repo's docs site.

## Prerequisites

- GitHub Actions already deploys your docs (e.g. Just the Docs, MkDocs, VitePress, or plain HTML) to GitHub Pages.
- Node.js 18+ is available in your CI runner (true for all `ubuntu-latest` Actions runners).

## Option A — SGD Web UI (recommended)

1. Go to `sgd.wealthtechpros.com/repos/<owner>/<repo>` → **Modules** tab.
2. Click **Install** next to "Traceability Chart".
3. Review and merge the PR that SGD opens (`feat(sgd): install traceability chart module`).
4. The chart goes live on your next push.

## Option B — CLI skill

From inside any SGD-governed repo checkout:

```
/sgd:traceability
```

This copies the three module files into the repo and opens a draft PR. Review and merge.

## Option C — Manual

Copy these three files from `skills/traceability/` in the SGD repo:

| Source | Destination in your repo |
|---|---|
| `build-traceability.mjs` | `scripts/build-traceability.mjs` |
| `traceability.html` | `docs/traceability.html` |

Then add this step to your docs workflow (`.github/workflows/docs.yml` or equivalent), **after** the `actions/checkout` step and **before** the Pages upload step:

```yaml
- name: Build traceability data
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: node scripts/build-traceability.mjs
```

By default the builder writes to `docs/assets/traceability.json`. Override with:

```yaml
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    GITHUB_REPOSITORY: ${{ github.repository }}
    TRACEABILITY_OUTPUT_PATH: docs/assets/traceability.json
```

Ensure your docs build includes `docs/assets/traceability.json` in the Pages upload artifact.

## Verification

After the workflow runs, open `https://<your-pages-domain>/traceability.html`.

You should see:
- A stats bar showing total PRs, traceable count, and trace%.
- A left-panel tree of all specs referenced in your PR history.
- A "Governance Gaps" section listing PRs with no spec reference.

## Troubleshooting

**`Failed to load traceability.json`**: The builder step did not run, or the output path does not match what `traceability.html` expects. Check that `TRACEABILITY_OUTPUT_PATH` resolves to a path inside your Pages artifact root.

**All PRs show as untraceable**: PRs must reference `SPEC-NNN`, `CAP-NNN`, or `CAP-NNN-FNNN` in their branch name, title, or body. Older PRs without spec links will appear in Governance Gaps — this is expected.

**Rate-limit errors**: `GITHUB_TOKEN` is automatically provided in Actions with sufficient `repo` read scope. If running locally, export a PAT: `export GITHUB_TOKEN=ghp_...`.
