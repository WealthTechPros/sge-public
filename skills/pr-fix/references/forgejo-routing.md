# Forgejo call sites and declaring green

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Forgejo call-site substitution (pr-fix loop)

`$ORIGIN` = `git remote get-url origin`; `$PR` = the PR index number.

| Step | `gh` command (github) | Adapter equivalent (forgejo) |
|---|---|---|
| **Step 0 triage** — read PR state | `gh pr view $PR --json statusCheckRollup,mergeable,isDraft,state` | `forgejo-adapter.sh get-pr "$ORIGIN" $PR` — returns Gitea PR JSON; check `.state`, `.mergeable`, `.draft` fields |
| **Loop step 1** — list CI status | `gh pr checks $PR` | `SHA=$(git rev-parse HEAD)` then `forgejo-adapter.sh pr-statuses "$ORIGIN" "$SHA"` — returns Gitea commit-status JSON array; check `.state` (`success`/`failure`/`pending`/`error`) |
| **Loop step 7** — push fixes | `git push origin HEAD` | same — `git push` works directly against the Forgejo remote |
| **Step 1.3 — rerun** | `gh run rerun --failed` | **Not available via adapter.** If CI is Gitea Actions, the rerun API exists but is not yet wrapped. Use a fresh push to trigger a new run instead of a rerun. |

> **CI model note.** GitHub Actions and Gitea Actions share a YAML syntax but
> expose different APIs. For a Forgejo repo the canonical CI signal is the
> **commit-status API** (`/repos/{owner}/{repo}/commits/{sha}/statuses`) —
> both Gitea Actions and external CI (Woodpecker, Drone) post statuses there.
> Treat a `pending` or empty status array as "checks still running" and wait
> (the [wait-for-condition loop](../../loops/SKILL.md#b-wait-for-condition-loop)
> applies: re-poll `pr-statuses` until the array is non-empty and all
> entries are `success` or at least one is `failure`/`error`).

## Forgejo: declaring the PR green

A Forgejo PR is green when:
1. `forgejo-adapter.sh get-pr "$ORIGIN" $PR` shows `.mergeable` is not `false`
   (Forgejo returns a boolean — true/false/null; null means "not computed yet").
2. `forgejo-adapter.sh pr-statuses "$ORIGIN" "$SHA"` shows all non-pending
   entries are `success` (or the array is empty and there is no required CI).
3. There are no open blocking review comments (check via
   `GET /repos/{owner}/{repo}/issues/{index}/comments` — reviewers leave
   comments on the PR's issue thread; inline comments are on the review endpoint).
