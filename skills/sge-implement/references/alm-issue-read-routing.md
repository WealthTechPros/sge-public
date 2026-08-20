# Issue-read backend routing (ALM port, SPEC-105 S2)

Progressive-disclosure reference for the target-repo callout at the top of
this skill.

`scripts/issue-read.sh` picks its backend from the resolved host, not from a
flag:

- **GitHub** — `gh`, the default.
- **Self-hosted Forgejo/Gitea** — only for a host declared in
  `SGE_FORGEJO_HOSTS` (`;`-separated vanity domains). An undeclared host
  classifies as `unknown` and **fails loud** rather than silently falling
  back to the GitHub path (ADR-0010).
- **Jira** — when `SGE_ALM_BACKEND=jira`; the issue argument is the Jira
  `issueKey`, not a number.
