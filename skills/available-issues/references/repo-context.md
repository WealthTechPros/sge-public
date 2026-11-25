# Pre-flight — repo context detail

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

`IR` (`scripts/issue-read.sh`) returns normalized issue records. It resolves the issue tracker independently of the Git host. GitHub uses `gh`. Jira uses `SGE_ALM_BACKEND=jira`, the project in `SGE_JIRA_PROJECT`, and the Jira adapter’s host allow-list and credentials. Azure Boards uses the Azure DevOps adapter (SPEC-110). Unknown backend values fail before a query.

The helper verifies the checkout's `origin` actually matches the requested repo (a directory with the right name but the wrong origin is rejected) and refuses — with an actionable error — rather than proceeding in the ambient directory. Announce the resolved context once so the caller can catch a wrong-repo invocation immediately. Every `gh`/`git` snippet in the phases below assumes this entry sequence has just run in the same shell call.

Read the repo's `CLAUDE.md` for the **spec/feature artefact globs** (used to tell a spec-only issue's diff surface from a code change — same resolution `/sge:pr-monitor` does for spec-only PRs; do **not** hardcode a glob, fall back to `features/**`, `docs/**` only if `CLAUDE.md` is silent) and the **module-label convention** if one exists.
