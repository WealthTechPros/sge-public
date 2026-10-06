# Issue fetch — why `issue-read.sh` and a real Bash call

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Routed via `scripts/issue-read.sh` (not a bare `gh issue view`) so this
headless, forked skill works against a Forgejo/Gitea-hosted target repo,
exactly like `/sge:available-issues` and `/sge:sge-align` already do
(ADR-0010, #1236) — a bare `gh` call here previously meant EVERY dispatch of
`/sge:sge-implement` Phase 0.5 (which forks this skill unconditionally) would
silently `NO_ISSUE_LOADED` on a non-GitHub target repo. `GH_REPO` was
exported above so this resolves and reads against the target checkout
(issue #2207) — `issue-read.sh`'s own host/ALM classification reads the
CURRENT cwd, so `GH_REPO` alone (the prior, Forgejo/Jira-broken convention)
is not enough on its own.

A `!`-preload injection line cannot safely carry `$ARGUMENTS` into this call
— the harness substitutes `$ARGUMENTS` as raw, unescaped text before any
shell parses it, so no quoting scheme is safe against an adversarial
argument (confirmed live: a bare `"` broke out of a
`bash -c '...' _ "$ARGUMENTS"` positional-passing attempt and executed
arbitrary commands; see
`no-positional-args-in-injection.test.sh` (SGE source repo: `skills/tests/no-positional-args-in-injection.test.sh`)
and upstream anthropics/claude-code#16163). Issue this as a **real Bash
tool call**, with the issue number parsed from your own invocation's
argument text and passed as a normal, safely-quoted argument:
