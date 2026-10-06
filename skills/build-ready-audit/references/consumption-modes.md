# Consumption modes

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

It is consumed two ways:

1. **Standalone** — a human runs it over a backlog (or one issue) to see what is
   ready and what needs sharpening before work starts.
2. **Dispatched** — `/sge:available-issues` and `/sge:team-pipeline`'s
   [Duration Mode](../../team-pipeline/SKILL.md#duration-mode---duration--the-time-boxed-swarm)
   front end call it headlessly, **once per candidate, before any worktree is
   claimed**, to keep the queue clean. In that mode return only the structured verdict —
   no questions, no comment.

## Position in the funnel

It is the cheap
front-of-funnel gate that sits **upstream of `/sge:sge-preflight`** — preflight is
a deep per-spec entry check that runs once an issue is already claimed; this audit
is a quick go/no-go applied across a *set* of candidates so under-specified or
ungoverned issues never reach a worktree.

- The `/sge:sge-implement` Phase 0.5 governance gate is a **separate** fold
  (issue #949); this audit is the batch build-ready front end, not the
  per-issue implement gate. Both reuse the same `/sge:governance-trace`
  classifier.
