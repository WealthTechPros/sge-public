# Non-GitHub host (Forgejo/Gitea) — read/diff phase routing

Reference for [`../SKILL.md`](../SKILL.md) — the host-adapter read routing used
by Phases 1–4 when the repo is not on GitHub. Extracted for the SKILL.md size
budget (progressive disclosure); behaviour is unchanged.

Before Phase 1, detect the host and source the PR-read shim so every read in
Phases 1–3 routes correctly without branching on the host inside each phase:

```bash
HOST_KIND="$(${CLAUDE_PLUGIN_ROOT}/scripts/with-repo-cwd.sh host)"
source "${CLAUDE_PLUGIN_ROOT}/skills/lib/forgejo-pr-read.sh"
```

| Read operation            | GitHub (`gh`)                           | Any host (`fpr_*`)    |
|---------------------------|-----------------------------------------|-----------------------|
| View PR metadata          | `gh pr view "$PR" --json ...`           | `fpr_view "$PR"`      |
| Fetch diff                | `gh pr diff "$PR"`                      | `fpr_diff "$PR"`      |
| Read CI check statuses    | `gh pr checks "$PR" --json ...`         | `fpr_checks "$PR"`    |

**Scope:** only the non-mutating read and diff phases (Phase 1 Discovery, Phase 2
agent dispatch input, Phase 3 quality gates CI read, Phase 4 issue validation) are
routed here. Everything mutating — `pr-labels.sh`, `gh pr review`, `gh pr merge`,
`gh pr ready` — remains GitHub-only until the mutating pr-review slice. On a
Forgejo repo, skip any action that requires a write and log the deferral.

**Forgejo PR fields mapping** (from Gitea JSON to the names this skill references):

| This skill uses           | Gitea JSON field                        |
|---------------------------|-----------------------------------------|
| `number`                  | `.number`                               |
| `title`                   | `.title`                                |
| `body`                    | `.body`                                 |
| `isDraft`                 | `.draft`                                |
| `headRefName`             | `.head.ref`                             |
| `headRefOid`              | `.head.sha`                             |
| `baseRefName`             | `.base.ref`                             |
| `state`                   | `.state` (`open`/`closed`)              |
| `labels[].name`           | `.labels[].name`                        |
| `additions` / `deletions` | not in Gitea schema — derive from diff  |

`fpr_view "$PR"` returns the full Gitea PR JSON object; use `jq` to project
the fields this skill needs before passing to downstream phases.
