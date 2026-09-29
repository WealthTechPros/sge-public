# Non-GitHub host (Forgejo/Gitea) — read/diff phase routing

Reference for [`../SKILL.md`](../SKILL.md) — the host-adapter read routing used
by Phases 1–4 when the repo is not on GitHub. Extracted for the SKILL.md size
budget (progressive disclosure); behaviour is unchanged.

Before Phase 1, detect the host and source the PR-read shim so every read in
Phases 1–3 routes correctly without branching on the host inside each phase:

```bash
SGE_ROOT="$(bash ./scripts/resolve-sge-root.sh 2>/dev/null || bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-sge-root.sh")" || exit 1
HOST_KIND="$("$SGE_ROOT/scripts/with-repo-cwd.sh" host)"
source "$SGE_ROOT/skills/lib/forgejo-pr-read.sh"
```

| Read operation            | GitHub (`gh`)                           | Any host (`fpr_*`)    |
|---------------------------|-----------------------------------------|-----------------------|
| View PR metadata          | `gh pr view "$PR" --json ...`           | `fpr_view "$PR"`      |
| Fetch diff                | `gh pr diff "$PR"`                      | `fpr_diff "$PR"`      |
| Read CI check statuses    | `gh pr checks "$PR" --json ...`         | `fpr_checks "$PR"`    |

**Scope:** only the non-mutating read and diff phases (Phase 1 Discovery, Phase 2
agent dispatch input, Phase 3 quality gates CI read, Phase 4 issue validation) are
routed here.

**Mutating ops — partially deferred still (issue #2582).** `pr-labels.sh`'s full
review-gate STATE MACHINE (`start-review` claim mutex, stale-claim takeover,
`pr-reviewing`/`pr-reviewed`/`changes-requested`/`hold` transitions, heartbeats,
`sync-check`, `sge-verdict` coverage tracking, follow-up preservation gate, `gh pr
review`, `gh pr ready`) is **NOT ported to Forgejo** — that is a materially larger
slice than #2582's budget covered and remains GitHub-only. On a Forgejo repo, skip
any action that needs that state machine and log the deferral, exactly as before.

What #2582 **did** ship, reusable by a simplified Forgejo review flow if one is
built later: `skills/lib/forgejo-pr-mutate.sh` gives bare `fpr_add_label` /
`fpr_remove_label` (direct label add/remove, no claim semantics), `fpr_merge_ready`
(a degrading linked/reviewed-label/CI-green check — the reviewed-label gate only
applies when `SGE_FORGEJO_REVIEWED_LABEL` is configured for the repo) and
`fpr_merge` (squash-merge, TOCTOU-pinned to the current head SHA), plus `fpr_rerun`
(CI retrigger — Forgejo has no native failed-only rerun, only a full-retrigger
empty commit). See [`pr-monitor`'s copy of this
doc](../../pr-monitor/references/host-adapter-routing.md#mutating-ops-rerun--merge--label--issue-2582)
for the full routing table and the open cancelled-vs-failed question — this file
does not duplicate it. **Not live-validated** against a real Forgejo instance
(built without `git.feaw.co.uk` credentials or `mcp__forgejo__*` access); needs a
manual pass before any Forgejo repo's pr-review flow depends on it.

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
