# Core philosophy and the stoppable-only fan-out rule

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Stoppable-Only Fan-Out Rule (when running inside team-pipeline)

When spawned by `/sge:team-pipeline` as its PR-monitor agent (one bounded pass, never an unbounded poller, #2914), this skill is launched as a **named `Task`** — never a detached background Agent or `isolation: "remote"` — so the orchestrator can `TaskStop "pr-monitor"` cleanly during Phase 6 shutdown.

Used standalone, no fan-out constraint applies — it runs as a foreground skill. The rule below is scoped to orchestrated fan-out only:

> **When dispatched as part of a fan-out, any sub-agents this skill spawns (e.g. for
> `/sge:pr-fix`) MUST also be named Tasks, never detached/remote agents.**

---

## Core philosophy

A bounded rolling window beats fanning out across every open PR:

- Watch **`LANES` lanes maximum** — the oldest eligible PRs.
- **Skip ineligible PRs** (see *Lane eligibility* below): spec-only PRs, drafts, and PRs another reviewer has claimed.
- When a lane's PR merges, pull the **next oldest eligible PR** into that lane.
- **Fix the oldest PR first** — don't start on PR N+1 until PR N is green or structurally blocked.
- **Systemic failures** (the same test broken across multiple PRs) → fix once in the oldest PR; let rebase propagate to the rest. Never fix N copies of one bug.
- **Operate autonomously.** Each cycle the monitor *acts* on its classification — rebase, rerun, `/sge:pr-review`, `/sge:pr-fix`, enable auto-merge — **without asking the human**. A review-blocked PR is a job, not a question. Escalate only when a block genuinely can't be self-resolved (an approving review the runner can't give, or any action that weakens a control).

The disciplined alternative to opening 10 concurrent fix lanes that burn CI on PRs that will conflict anyway.

---
