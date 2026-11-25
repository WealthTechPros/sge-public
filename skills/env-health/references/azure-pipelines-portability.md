# Azure Pipelines portability

The env-health CI portability check scans Azure Pipelines definitions for GitHub-only actions, tasks and CLI commands. For operations against Azure Repos, use the corresponding REST endpoint and pipeline identity.

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
