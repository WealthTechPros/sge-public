# Issue-read backend routing (ALM port, SPEC-105 S2)

Progressive-disclosure reference for the target-repo callout at the top of
this skill.

`scripts/issue-read.sh` resolves the selected issue tracker in the target checkout:

- **GitHub** — `gh`, the default.
- **Azure Boards** — with `SGE_ALM_BACKEND=azdo`, the Azure DevOps adapter reads work items for the selected project (SPEC-110).
- **Jira** — when `SGE_ALM_BACKEND=jira`; the issue argument is the Jira
  `issueKey`, not a number.
