# Non-GitHub host (Forgejo/Gitea) — read-only PR routing

Reference for [`../SKILL.md`](../SKILL.md) — how the pr-monitor lane routes its
read-only PR queries through the host adapter on a Forgejo/Gitea repo. Extracted
for the SKILL.md size budget (progressive disclosure); behaviour is unchanged.

When the repo's `origin` is a Forgejo or Gitea instance, `gh pr list/view/checks` all
fail because `gh` only speaks to GitHub. Use the host-agnostic routing shim instead:

```bash
# Detect the host kind once per Startup.
HOST_KIND="$(${CLAUDE_PLUGIN_ROOT}/scripts/with-repo-cwd.sh host)"

# Source the routing shim — it exposes fpr_list / fpr_view / fpr_diff / fpr_checks
# that transparently route to gh (GitHub) or forgejo-adapter.sh (Forgejo/Gitea).
source "${CLAUDE_PLUGIN_ROOT}/skills/lib/forgejo-pr-read.sh"
```

Then replace every `gh pr list`/`gh pr view`/`gh pr checks` call in the monitor loop
with the corresponding `fpr_*` wrapper:

| GitHub (`gh`)                         | Any host (`fpr_*`)            |
|---------------------------------------|-------------------------------|
| `gh pr list --state open --json ...`  | `fpr_list`                    |
| `gh pr view "$pr" --json ...`         | `fpr_view "$pr"`              |
| `gh pr checks "$pr"`                  | `fpr_checks "$pr"`            |

**Forgejo-specific behaviour:**

- `fpr_list` returns the Gitea PR JSON schema (superset of what `gh pr list --json` returns;
  map `number → number`, `title → title`, `state → state`, `head.sha → headRefOid`,
  `base.ref → baseRefName`, `labels[].name → labels[].name`).
- `fpr_checks` resolves the PR head SHA then calls `pr-statuses`; the Gitea
  CommitStatus `state` values (`pending/success/error/failure/warning`) map to
  the same traffic-light logic as `gh pr checks` conclusions: `success` = green;
  `pending` = in-flight; all others = failing.
- **Mutating operations are NOT routed through the adapter in this slice** — label
  transitions, merges, and any write via `gh` remain GitHub-only until the mutating
  pr-review slice (a future issue). On a Forgejo repo, skip any lane action that
  requires a write; log `FORGEJO_READ_ONLY: <action> deferred (mutating ops not yet supported)`.

**Auth:** ensure `FORGEJO_API_TOKEN` (or `GITEA_TOKEN`) is set before sourcing the
shim for a Forgejo repo; the adapter fails loud (never silently unauthenticated).
Add the host to `SGE_FORGEJO_HOSTS` (`;`-separated) or `SGE_FORGEJO_DEFAULT_HOST`
so the adapter's allow-list validation passes (ADR-0010).
