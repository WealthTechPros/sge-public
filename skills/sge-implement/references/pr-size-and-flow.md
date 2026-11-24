# PR size, shape and pre-PR QA (sge#3706)

On 2026-11-23 three PRs took most of a day to land, each through 4–5 review rounds (#3684): they were too large, adversarial QA ran last, a stacked draft hid the diff from CodeRabbit, builders could not run the integration tests locally, and nothing was pushed until the end. These rules remove those causes. The thresholds and the stacked-draft ban were decided on 2026-11-24.

## Size gate

Run it before the PR leaves draft (Phase 6), and before you push a commit that would grow the PR's scope:

```bash
bash "$SGE_ROOT/skills/sge-implement/pr-size-gate.sh" origin/main
```

| Changed lines (added + deleted) | Result | What to do |
|---|---|---|
| up to 1,500 | `ok` | Carry on. |
| over 1,500 | `warn` (exit 0) | Say in the PR body how big it is and why it could not be smaller. |
| over 3,000 | `split` (exit 1) | Do not open it for review. Split it into smaller PRs, each one reviewable on its own. |

The thresholds are approximate on purpose: `SGE_PR_WARN_LINES` and `SGE_PR_SPLIT_LINES` override them. A base the script cannot resolve, or a threshold override that is not a non-negative integer, exits 2, never `ok`.

**One issue per PR once it is open.** Open a new PR rather than adding a second issue to an open one. Theme bundling (the lean flow) still applies, but only within the cap, and the bundle is chosen before the PR opens.

## Ready for review against main

Every PR targets `--base main`. **Long-lived stacked drafts are banned**: never base a PR on another PR's branch and leave it as a draft waiting for that one to merge. CodeRabbit does not review drafts, so a stacked draft's findings arrive all at once, late (one PR surfaced 14 at once when it was marked ready). If the work depends on an unmerged PR, wait for it to merge, or fold the dependency into this PR and stay under the cap.

The Phase 3 draft with `hold` (hold-first, #2509) is unchanged: it is transient, lives only for this run, and is marked ready at Phase 6.5 or 7.1.

## Push each tested fix

Push each tested fix as it lands, not one batch at the end: every green TDD cycle, and every review-finding fix, is committed and pushed straight away. Reviewers and the human can then see progress, and an interrupted run loses nothing.

## Adversarial QA before the PR

If the diff touches an **auth**, **tenant**, **approval**, **retention** or **deletion** control, run `/sge:qa-audit <pr-number> --adversarial` before marking the PR ready. Fix what it finds, then link the report comment in the PR body (`Adversarial QA: <comment URL>`). The review (`/sge:pr-review` Phase 4.3a, run by PR Warden) records a BLOCKER for a control-bearing PR without a current adversarial report, so running it first saves a full review round. This is in addition to the one pre-PR adversarial review pass in Phase 5.

## Builder environment: WSL with Docker

The default builder environment is **WSL with Docker**, so integration and Postgres tests run before push, not only in CI. On a Windows host there is no Docker and App Control blocks uv/venv, so each CI-only test loop costs 10–15 minutes. Run the repo's full suite, including its Docker-backed integration tests, in WSL before every push. If WSL or Docker is not available, say so in the PR body and name which suites ran only in CI.
