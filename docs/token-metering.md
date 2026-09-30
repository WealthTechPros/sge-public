# Token metering and savings evidence

This page states what the SGE plugin measures about token usage, on which
hosts, and what the numbers can and cannot prove. All metering is **local**:
nothing here sends session data or usage records to SGE services or any other
network endpoint.

## The producer

`hooks/token-meter.sh` runs on the `Stop` and `SubagentStop` hook events
(registered in `hooks/hooks.json`, which ships in both the full and the public
distribution). It reads the session transcript path from the hook payload,
takes the `usage` block of each assistant message (input, output, cache-read,
cache-creation tokens), and appends one `TokenUsageRecord` per assistant turn
to the consumer repo's `memory/token-usage.jsonl`. `memory/` is git-ignored.

It makes no network calls. On any missing input (no `jq`, no transcript path,
an unreadable transcript) it exits silently and writes nothing — a hook never
breaks session stop. Records are idempotent per transcript: a re-fired `Stop`
does not double-count.

`/sge:cost-guard` and `/sge:roi-report` read that file. Neither writes it.

## Host support

| Host | Metering | Why |
|---|---|---|
| Claude Code | Supported | The `Stop` payload carries `transcript_path`, and the transcript records per-message `usage`. |
| GitHub Copilot CLI | **Not supported** | The producer depends on a Claude Code-format transcript with per-message `usage` blocks. That contract has not been validated against Copilot CLI hook payloads, and SGE ships no Copilot-specific producer. Treat any Copilot CLI token figures from this hook as unverified. |
| Other hosts | Not supported | Same dependency. |

**Absent is not zero.** If `memory/token-usage.jsonl` does not exist, no
producer ran in that repo. `/sge:cost-guard` then reports *metering
unavailable* (`meteringUnavailable: true`, `usagePercent: null`) and
`/sge:roi-report` reports *token metering unavailable*. Neither reports zero
usage or zero cost. A file that exists but has no rows for the requested spec
or session is a genuine "no usage recorded". A file that exists does not
prove the *current* host is metered: it may hold rows from earlier Claude
Code sessions in the same repo. Check the `sessionId` and `timestamp` of the
rows before treating them as covering a session.

Counts on supported hosts are a floor: turns the transcript does not record
(for example some sub-agent traffic) are not metered, and internal
comparisons have found these counts well below provider-billed usage. Use
provider billing or an API usage export as the authoritative total.

## Measuring Cortex savings

A falling daily token total does not show that Cortex memory saved tokens.
Workload, model, task mix, and prompt length all move that number. A savings
claim needs all of the following:

1. **Matched workload baseline.** Run the same task set twice, same model and
   settings, once with the `sge-memory` server disabled and once enabled.
   Compare per-task totals from `memory/token-usage.jsonl`, not daily sums.
   Repeat enough runs to see the variance between identical runs; a
   difference smaller than that variance is not a saving.
2. **Retrieval linkage.** Each `search_nodes` call and each
   `memory_feedback` (useful yes/no) is written to the Cortex audit log with a
   timestamp, count-only (`audit_read` returns it; no memory content). On
   Claude Code, audit rows also store a hashed session reference in the local
   DB. No shipped tool joins audit rows to token records yet; link them by
   session and time window, and report tasks where retrieval was marked
   useful separately from those where it was not.
3. **Stated method.** Report the task set, run count, model, host, and the
   metering caveats above with the result.

On a host without validated metering (Copilot CLI today), Cortex savings
cannot be measured from SGE's own records. Use the host's or provider's own usage
reporting for both arms of the comparison instead.
