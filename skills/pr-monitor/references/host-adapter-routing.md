# Non-GitHub host (Forgejo/Gitea) — PR routing (read + mutating)

Reference for [`../SKILL.md`](../SKILL.md) — how the pr-monitor lane routes its
read-only PR queries through the host adapter on a Forgejo/Gitea repo. Extracted
for the SKILL.md size budget (progressive disclosure); behaviour is unchanged.

When the repo's `origin` is a Forgejo or Gitea instance, `gh pr list/view/checks` all
fail because `gh` only speaks to GitHub. Use the host-agnostic routing shim instead:

```bash
SGE_ROOT="$(bash ./scripts/resolve-sge-root.sh 2>/dev/null || bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-sge-root.sh")" || exit 1

# Detect the host kind once per Startup.
HOST_KIND="$("$SGE_ROOT/scripts/with-repo-cwd.sh" host)"

# Source the routing shim — it exposes fpr_list / fpr_view / fpr_diff / fpr_checks
# that transparently route to gh (GitHub) or forgejo-adapter.sh (Forgejo/Gitea).
source "$SGE_ROOT/skills/lib/forgejo-pr-read.sh"
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
**Auth:** ensure `FORGEJO_API_TOKEN` (or `GITEA_TOKEN`) is set before sourcing the
shim for a Forgejo repo; the adapter fails loud (never silently unauthenticated).
Add the host to `SGE_FORGEJO_HOSTS` (`;`-separated) or `SGE_FORGEJO_DEFAULT_HOST`
so the adapter's allow-list validation passes (ADR-0010).

## Mutating ops (rerun / merge / label) — issue #2582

The mutating slice deferred above has shipped: `skills/lib/forgejo-pr-mutate.sh`
gives the same `fpr_*` seam for rerun, merge, and label add/remove. Source it
(it sources `forgejo-pr-read.sh` itself, so one `source` is enough):

```bash
source "$SGE_ROOT/skills/lib/forgejo-pr-mutate.sh"
```

| Loop action                 | GitHub (`gh`)                        | Any host (`fpr_*`)                |
|------------------------------|--------------------------------------|------------------------------------|
| Re-run CI                    | `gh run rerun --failed`              | `fpr_rerun "$pr" "<reason>"`       |
| Check merge readiness        | (`pr_ready_for_merge` in monitor-lib.sh) | `fpr_merge_ready "$pr"`       |
| Merge                         | `gh pr merge --squash --auto`        | `fpr_merge "$pr"`                  |
| Add / remove a label         | `gh pr edit --add-label` / `--remove-label` | `fpr_add_label` / `fpr_remove_label` |

**Use the `fpr_*` merge/readiness rows on Forgejo only, for now.** On GitHub keep
using `monitor-lib.sh`'s `pr_ready_for_merge` and `gh`: the GitHub branch of
`fpr_checks` requests `gh pr checks --json` fields real `gh` rejects, and
`fpr_merge_ready` never consults `$MERGE_GATE_LABEL` there (tracked in #2650).
Also note **`fpr_merge` on Forgejo merges immediately** — unlike GitHub's
`--auto`, nothing waits for CI server-side — which is why `fpr_merge_ready`
demands a positive green signal (at least one status, none pending) rather than
just "no red check", and why the merge is pinned to the head SHA resolved
*before* that check.

**Rerun asymmetry (read before wiring into the loop):** GitHub's row above
reruns only the FAILED jobs. Forgejo has **no equivalent lever** — nothing
surfaced via `mcp__forgejo__*` in the getmy#16460 worked example, and no Gitea
REST endpoint, reruns failed-jobs-only. `fpr_rerun`'s Forgejo path instead
pushes an empty `ci: retrigger — <reason>` commit to the PR branch, which
reruns **everything**. It also requires the caller's cwd to already be a
checkout **of the PR's head** (same convention as pr-fix's `git push origin
HEAD` — see `skills/pr-fix/SKILL.md` Loop step 7) and refuses, rather than
guessing, when: the current branch isn't the PR's head branch; local `HEAD`
isn't the PR's current head commit (unpushed/foreign commits would be
published under the retrigger message); the PR comes from a fork (`origin` is
the base repo, so the push would target the wrong repo's branch); or the index
has staged changes.

**Merge-gate degrade:** `fpr_merge_ready` runs the same linked-issue and
CI-green checks on every host (CI-green = ≥1 status, all green), but the **reviewed-label gate only applies when
the repo has opted in** via `SGE_FORGEJO_REVIEWED_LABEL=<label-name>`. Unlike
GitHub (where `pr-labels.sh`'s state machine is the universal SGE convention
and `$MERGE_GATE_LABEL` is always resolved), a Forgejo repo may run CI-green
as its sole merge gate — the validation target named in #2582's governance
decision, `git.feaw.co.uk/FEAW/homelab-infra`, has no reviewed-label
convention per its own CLAUDE.md. Absence of the env var is the explicit
degrade signal, not a guess. **Out of scope:** the full `pr-labels.sh` state
machine (claim mutex, stale-claim takeover, `changes-requested`, `hold`,
sync-check, heartbeats, `sge-verdict` tracking) is NOT ported to Forgejo — only
the bare add/remove-label primitive exists there.

**Open question — cancelled vs. failed:** GitHub's CANCELLED row
(`is_cancelled_run`, monitor-lib.sh, #1665) has no Forgejo counterpart here.
Gitea's CommitStatus schema has no dedicated "cancelled" state; whether a
cancelled Forgejo Actions run reports as `error`, `failure`, or something else
is **unverified** — checking this needs a real cancelled run on a live
instance. Until checked, `fpr_check_is_failing`/`fpr_merge_ready` will treat a
cancelled Forgejo run as a hard CI failure (fail-closed is the safe default,
but it means a cancelled run gets CODE-FAIL treatment instead of the
retry-via-fresh-run treatment GitHub gets).

**Not live-validated (#2582):** this slice was built without `git.feaw.co.uk`
credentials or an `mcp__forgejo__*` MCP server in the implementing lane (that
tooling is scoped to a different repo's CLAUDE.md, `getmy`). It is validated
here only against mocked `curl`/`gh`/`git`
(`skills/tests/forgejo-pr-mutate-routing.test.sh`) — a manual pass against the
live target repo by whoever has `mcp__forgejo__*` access is a required
follow-up before relying on it in an unattended pr-monitor/pr-fix run.
