# Issue fetch — why `issue-read.sh` and a real Bash call

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Use `scripts/issue-read.sh` from the target checkout so host and ALM detection use the correct origin. Setting `GH_REPO` alone does not change the working directory (#2207).

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
