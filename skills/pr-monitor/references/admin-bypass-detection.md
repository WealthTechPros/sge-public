# Admin-bypass detection (issue #2384, admin-bypass half of #2209)

`gh pr merge --admin` cannot be prevented at the GitHub API level — branch protection has no "except when I say so" audit hook. This is **fail-loud detection, not prevention**: per the 2026-08-19 decision recorded on #2209, a merge that landed via admin bypass on a repo with required contexts red should never be silently indistinguishable from a routine merge, regardless of *why* the verdict path was broken (App outage, missing operator credentials, #2219's independence-exclusion case). This pairs with #2219's declared-exception model — an override should always be an explicit, recorded exception, never a normalized default path.

**Mechanism** — [`scripts/detect-admin-bypass.sh`](../../../scripts/detect-admin-bypass.sh): for a merged PR, resolve the base branch's required status-check contexts, fetch check-runs (+ legacy statuses) for the PR's **head SHA** (the commit that carried the pre-merge verdicts — the merge commit itself has no check-run history), collapse to the latest conclusion per named check, and compare against the required set. `success`/`neutral`/`skipped` (e.g. a legitimately path-filtered job) count as satisfying a context, matching GitHub's own branch-protection semantics; anything else (`failure`/`cancelled`/`timed_out`/`pending`/missing) on a PR that nonetheless merged is only reachable via an admin override.

Run it every time the **MERGED** row fires:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/detect-admin-bypass.sh --pr "$pr"
```

On detection it appends an NDJSON record to the rolling log (`$ADMIN_BYPASS_LOG`, default `/tmp/admin-bypass.ndjson`) **and** posts an idempotent (head-SHA-marker-keyed) comment on the PR naming the specific context(s) that were not green at merge time — never re-posted for the same head SHA. Exit is always 0: the merge already happened, there is nothing left to block; the flagged PR comment/log line is the actionable signal, not a gate. A repo-wide sweep (`--scan [--since <ISO8601>]`, default lookback 24h) is available for a periodic audit pass outside the per-merge hook.

## Admin-bypass detection (issue #2384, admin-bypass half of #2209)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

`gh pr merge --admin` cannot be prevented, so this is fail-loud **detection, not prevention**: a merge over red required contexts must never look like a routine merge. Run it every time the **MERGED** row fires:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/detect-admin-bypass.sh --pr "$pr"
```

On detection it appends NDJSON to `$ADMIN_BYPASS_LOG` and posts an idempotent PR comment naming the non-green contexts; exit is always 0 (a signal, not a gate). Mechanism, rationale and the `--scan` sweep: the sections above.

---
