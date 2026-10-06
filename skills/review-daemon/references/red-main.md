# Red default branch -> fix lane

| Variable | Default | Meaning |
|---|---|---|
| `REVIEW_DAEMON_RED_MAIN_FIX` | on | `0` disables the red-main lane (below); also off when `REVIEW_DAEMON_FIX_LANE=0`. |
| `REVIEW_DAEMON_RED_MAIN_MAX_ATTEMPTS` | `2` | Red-main runs per repo per window (never twice for the same red tip). |
| `REVIEW_DAEMON_RED_MAIN_WINDOW_SECONDS` | `86400` | Rolling window for the red-main cap. |
| `REVIEW_DAEMON_RED_MAIN_CHECK_SECONDS` | `600` | Per-repo interval between default-branch reads (`0` = every cycle). A green tip costs one depth-1 GraphQL read; the history and protection reads run only for a red tip. |

**Red default branch**. Each cycle, for every fleet repo
whose default-branch tip fails a REQUIRED check (branch protection + rulesets;
pending, non-required and ignore-listed checks never count; an unreadable
required set never counts), the fix lane dispatches one run that opens a fix PR
off the red tip -- or, when the fix is not obvious, a PR reverting the culprit
from the last-green..tip range -- titled `fix(main): ...` and labelled
`pr-warden-red-main`. It never pushes to the default branch, never force-pushes
and never merges; the PR goes through normal review. Loop safety: once per red
tip, at most N per repo per window (same ledger file, `main:` keys), never while
an open `pr-warden-red-main` PR exists (unreadable = skip), never in shadow mode
or under a global pause. Red-main runs go first and share the concurrency cap. The run's system prompt carries only SHAs, never commit headlines (author-steerable).
Success is "a `pr-warden-red-main` PR is open afterwards"; runs.jsonl records it
as `kind: fix`, `pr: 0`, `decision.action: red-main-fix`.
