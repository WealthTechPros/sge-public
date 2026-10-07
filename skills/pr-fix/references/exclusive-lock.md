# Exclusive lock (--exclusive)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Step 0.5: Exclusive lock (opt-in, `--exclusive`)

When a parallel driver (another `/sge:pr-fix`, `/sge:pr-monitor`, or `/sge:team-pipeline`) might pick up the same issue, take an exclusive lock so only one agent works it at a time. This is **opt-in** — the default single-PR flow needs no lock, and concurrent fixes on *different* PRs never conflict.

The lock is a small JSON file under `.claude/locks/issue-<n>.lock` keyed on the issue number parsed from the PR branch (e.g. `feat/issue-729-…`). On entry:

- **Lock present and held by another live agent** → stop; report who holds it and when it expires. Don't race.
- **Lock present but stale** (past its expiry) → reclaim it and proceed.
- **No lock** → if `--exclusive`, write one (record agent, command, `locked_at`, `expires_at` ~120 min out) and register a cleanup trap so it's removed on exit, interrupt, or crash. Otherwise proceed without locking.

Keep the lock advisory and self-expiring — never let a forgotten lock wedge an issue permanently.

---
