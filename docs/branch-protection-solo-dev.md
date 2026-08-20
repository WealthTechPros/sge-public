# Branch protection as code — solo-dev reference module

Surfaced by `/sge:sge-init` at onboarding. See [sge#2186](https://github.com/WealthTechPros/sge/issues/2186).

## The gap this closes

Protected-branch rulesets on a consuming repo are typically GitHub-side
only — no Terraform, no Pulumi resource, no config file anywhere in the
repo. That means anyone with admin can change what gates a merge, and the
change has no PR, no diff, no review, no history a reviewer would ever see.
Representing branch protection as code turns that into a reviewable,
versioned artefact like any other infra change.

## The pattern

`WealthTechPros/wtp-org`'s `infra/github/__main__.py` already implements
and runs this live, org-wide, via the Pulumi GitHub provider
(`github.BranchProtection`, GraphQL v4 resource). Treat that file as the
working example — the snippet below is adapted from it, not a synthetic
rewrite. Read the source directly before adopting: `pulumi import` is
required for any repo that already has a live rule (creating a fresh
resource against an existing ruleset drops fields silently).

```python
import pulumi
import pulumi_github as github

# Solo-dev posture: PR required to merge main, but no required-reviewer
# gate — an approval-count control is theatre with one developer holding
# every merge button. required_approving_review_count stays 0 by explicit
# choice, not omission.
BASELINE_REVIEWS = [
    github.BranchProtectionRequiredPullRequestReviewArgs(
        dismiss_stale_reviews=False,
        require_code_owner_reviews=False,
        required_approving_review_count=0,
        require_last_push_approval=False,
    )
]


def baseline_protection(
    repo: str,
    opts: pulumi.ResourceOptions | None = None,
    enforce_admins: bool = False,
) -> github.BranchProtection:
    """Baseline main-branch protection: PR required, linear history, no force-push, no delete."""
    return github.BranchProtection(
        f"protect-{repo}-main",
        repository_id=repo,
        pattern="main",
        enforce_admins=enforce_admins,
        require_conversation_resolution=True,
        require_signed_commits=False,
        required_linear_history=True,
        allows_force_pushes=False,
        allows_deletions=False,
        required_pull_request_reviews=BASELINE_REVIEWS,
        opts=opts,
    )
```

## Posture encoded

- PR required to merge `main`.
- `required_approving_review_count: 0` — **no required-reviewer gate.**
  This is a solo-dev-team decision, not a general SGE recommendation — see
  the `REVERSED 2026-08-12` comment above `BASELINE_REVIEWS` in wtp-org's
  `infra/github/__main__.py` for the source rationale. A multi-reviewer
  team should raise `required_approving_review_count` instead of taking
  this pattern verbatim.
- No force-push, no branch deletion, linear history required.
- `enforce_admins=True` on for code/product repos so admins/automation
  can't bypass the gate either; leave it `False` for docs/static/mirror
  repos as a low-blast-radius emergency escape hatch.

## Required status checks

**Default list — start here, don't hand-type check names from scratch.**
The `required_status_checks` context string is the GitHub check's **display
name** (the workflow `name:` or job name GitHub renders in the PR checks
list), not the workflow filename or job id. Seed with whichever of the
following gates this repo has actually adopted (from `sge-init` Steps 7 /
7c):

```python
DEFAULT_REQUIRED_CHECKS = [
    "Require pr-reviewed label",   # require-pr-reviewed-label.yml — always, once /sge:pr-review is adopted
    "Require commit trailer",      # require-commit-trailer.yml — always, once Step 7's CI backstop is adopted (issue #2256)
    "Require test evidence",       # require-test-evidence.yml — only if Step 7c's TDD gate was adopted
]
```

```python
github.BranchProtectionRequiredStatusChecksArgs(
    strict=False,
    contexts=DEFAULT_REQUIRED_CHECKS,
)
```

Verified live against this framework repo's own branch protection
(`gh api repos/WealthTechPros/sge/branches/main/protection`), which requires
`"Require pr-reviewed label"`, `"Require commit trailer"`, and
`"Require test evidence"` among its contexts — these are the actual,
currently-enforced context strings, not illustrative names.

**Always re-verify before writing the resource** — a repo's exact set of
adopted gates varies (7c/7d/7e are each independently skippable), and check
display names can be renamed in the owning workflow file. Capture the live
truth with `gh api repos/<org>/<repo>/branches/main/protection` and diff it
against the default list above before adopting the Pulumi resource; re-verify
with `pulumi preview` that adopting the resource doesn't silently drop any
context the repo already relies on (e.g. a CI matrix summary check, or a
third-party app check with no SGE-owned workflow file).

## Explicitly out of scope here

- Watching the full config surface for drift (thread-resolution, bypass
  actors, etc.) — that's a detection-guard concern, not this module.
- A reusable drift-check script for other repos to consume.

Both are separate, not-yet-filed issues if still wanted.

