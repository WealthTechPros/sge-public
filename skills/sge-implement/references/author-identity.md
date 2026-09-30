# Author identity — who pushes the branch and opens the PR

An implementation lane is the PR's **author**. By default that is whatever `gh`/git login
the session has, often a human's personal account. That breaks any merge gate that needs a
**human approval**: GitHub blocks self-approval, so a PR opened under a human's login can
only be approved by some *other* human.

SGE distinguishes three identities and never lets them overlap:

| Role | Typical identity | Why it must be distinct |
|------|------------------|-------------------------|
| Author (this lane) | a dedicated GitHub App the org creates for agents | so any human can approve the PR |
| Reviewer (`/sge:pr-review`) | the review App (`SGE_REVIEW_APP_*`) | review-independence: a verdict from the author is rejected |
| Approver | a human | sensitive-path / required-review gates |

## Configuring it

Nothing in the skill hardcodes an identity. `gh` reads `GH_TOKEN`; git reads the commit
author and committer from `GIT_AUTHOR_*` and `GIT_COMMITTER_*`, and gets push credentials from a credential helper.
An org that wants agent PRs to have a bot author provides a wrapper that, for one command:

1. mints a short-lived installation token for its **author** App (never the review App),
2. exports `GH_TOKEN` (and unsets any ambient `GITHUB_TOKEN`, so no other tool in the
   child picks up the human's token),
3. configures https push auth for that token (`x-access-token`) and the App's
   `<app-slug>[bot]` noreply email as the commit author and committer,
4. fails closed: if the mint fails, it refuses to run. It never falls back to the ambient login.

Then every push/PR-write in Phase 3 and Phase 6 goes through it, e.g.
`"$SGE_AUTHOR_WRAPPER" git push -u origin <branch>` and
`"$SGE_AUTHOR_WRAPPER" gh pr create --draft ...`. When `SGE_AUTHOR_WRAPPER` is unset
(or the org's CLAUDE.md names no wrapper), the lane runs under the ambient login, as before.

Where the org's CLAUDE.md names an author wrapper, the org's convention wins; use it.
