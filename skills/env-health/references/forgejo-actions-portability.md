# Forgejo Actions portability — GitHub-only steps (sge-public#48)

Forgejo Actions runs GitHub-Actions-*shaped* workflows, but a workflow copied
from a GitHub repo is not portable by default. Two classes of step break on a
self-hosted Forgejo runner, and both look like real CI regressions until
traced:

| Step | What happens on Forgejo | Why |
|---|---|---|
| `uses: actions/github-script@vN` | Job fails at setup: `repository ... not found: exit status 128` | Forgejo resolves bare `actions/*` references against its own mirror (`data.forgejo.org` by default, or the instance's `DEFAULT_ACTIONS_URL`), which has no `github-script`. It wraps Octokit (`@actions/github`), and there is no Forgejo-API equivalent. |
| `run: gh ...` (GitHub CLI) | `gh: command not found` (exit 127) on every PR/push | Stock Forgejo runner images (and `node:*`/`debian:*` job containers) do not ship `gh`. Installing it does not help: `gh` talks to the GitHub API, not Forgejo's. |

A failing non-required job still leaves a red check on every PR. On a repo
where SGE reads CI state (`fpr_checks` / `fpr_check_is_failing`), that red
check reads as failing, and a PR can be held back by noise from a step that
could never have worked.

## What to use instead

- **Labels, comments, PR metadata:** `curl` against the Forgejo REST API
  (`$GITHUB_SERVER_URL/api/v1/repos/$GITHUB_REPOSITORY/...`, authenticated
  with the job token or a scoped secret), or an action from the Forgejo
  catalogue (`https://data.forgejo.org/actions/*`, or a fully-qualified
  `uses: https://code.forgejo.org/...` reference).
- **Scripted logic you'd have put in `github-script`:** a plain shell or
  `node` step calling the REST API directly.
- **Steps that genuinely target GitHub** (e.g. a mirror push): install `gh`
  explicitly in that job and pass a GitHub token. Never assume it is present.

## Detection

`/sge:env-health` Component C2 scans `.forgejo/workflows/*.yml` when the repo's
host is Forgejo/Gitea (`scripts/with-repo-cwd.sh host` -> `forgejo`; declare a
self-hosted instance in `SGE_FORGEJO_HOSTS`), and `azure-pipelines.yml` plus
`.azure-pipelines/**` when the host is Azure DevOps (`azdo`). It prints a
`CI_PORTABILITY_WARN` line (file:line, with a one-line fix) for each
`actions/github-script` use (Forgejo), each `actions/*` or `GitHub*@N` task
(Azure Pipelines) and each bare `gh <subcommand>` call. It is skipped on a
GitHub host, is advisory and never gates fan-out. Grep-based, so it can miss a
`gh` call built dynamically, and it can flag a `gh` step you deliberately
installed. Treat each hit as something to check.

## Portable replacements

Placeholders only: `<host>`, `<owner>`, `<repo>`, `<n>`, `<token>` are yours to
supply, from a masked CI secret. Never inline a real token.

### Forgejo / Gitea (`/api/v1`, PRs are issues for labels and comments)

```bash
API="https://<host>/api/v1/repos/<owner>/<repo>"
# apply a label (labels are addressed by numeric id: list them first)
curl -fsS -H "Authorization: token <token>" "$API/labels"
curl -fsS -X POST -H "Authorization: token <token>" -H "Content-Type: application/json"   -d '{"labels":[<label-id>]}' "$API/issues/<n>/labels"
# post a PR comment
curl -fsS -X POST -H "Authorization: token <token>" -H "Content-Type: application/json"   -d '{"body":"comment text"}' "$API/issues/<n>/comments"
```

### Azure DevOps (`dev.azure.com`; labels are PR labels, comments are threads)

```bash
API="https://dev.azure.com/<org>/<project>/_apis/git/repositories/<repo>/pullRequests/<n>"
AUTH="Authorization: Bearer $SYSTEM_ACCESSTOKEN"   # or: -u ":<pat>"
# apply a label
curl -fsS -X POST -H "$AUTH" -H "Content-Type: application/json"   -d '{"name":"label-name"}' "$API/labels?api-version=7.1"
# post a PR comment (a new thread with one comment)
curl -fsS -X POST -H "$AUTH" -H "Content-Type: application/json"   -d '{"comments":[{"parentCommentId":0,"content":"comment text","commentType":1}],"status":1}'   "$API/threads?api-version=7.1"
```

In a pipeline step, map the token explicitly:
`env: { SYSTEM_ACCESSTOKEN: $(System.AccessToken) }`.

## SGE's own templates

SGE's shipped workflows (`.github/workflows/`) target GitHub and use
`actions/github-script` and `gh` freely. **Do not copy them into
`.forgejo/workflows/` unchanged.** Port each GitHub-only step as described
above.
