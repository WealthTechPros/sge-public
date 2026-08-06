# Close-on-merge linkage across ALM backends (SPEC-105 S3, P8)

Progressive-disclosure reference for Phase 3's "push early, draft early" step and
Phase 6's PR-body rule. Loaded only when the repo tracks work outside GitHub
Issues; on a plain GitHub repo the default `Closes #N` flow is unchanged.

## The problem

GitHub's closing keyword (`Closes #N` / `Fixes #N` in the PR body) only closes
**GitHub issues**. On a repo whose work items live in Jira — GitHub-hosted code,
Jira-tracked backlog, the common enterprise topology behind #1150 — that keyword
closes nothing. Nothing errors; the linkage is simply absent, and the tracker
shows the item still open after the change merged.

## The seam

Route close-on-merge through the ALM write seam, `scripts/issue-write.sh`
(`$IW`), which is backend-aware:

```bash
IW="${CLAUDE_PLUGIN_ROOT:-.}/scripts/issue-write.sh"

# AFTER the PR exists — the change URL is the correlation key, so this cannot
# run before `gh pr create`.
"$IW" close-link "<issueRef>" "$(gh pr view --json url -q .url)"
```

| Backend | What `close-link` does |
|---|---|
| **github** (unset/empty) | **Declarative** — prints the `Closes #N` token for the PR body and makes **no API call**. Skip it when the body already carries the keyword; it edits nothing. |
| **jira** | Records the merge as a development-panel **remote link** on the item (`globalId` = the change URL, so a re-run upserts rather than duplicating), plus the close transition when `SGE_JIRA_CLOSE_TRANSITION_ID` is configured. A non-2xx write **fails loud** — never silently swallowed. |
| *unrecognised* | **Fails loud** naming the value (DR1) — no `gh` call, no Jira REST call. |

## Ordering rule

Run it **once the PR URL exists, never before**. Jira has no native link to an
externally-hosted PR (#1150), so the change URL *is* the correlation key: it is
the `globalId` that makes a re-run idempotent. Calling `close-link` at PR-creation
time has no URL to record.

## Why the GitHub path stays declarative

The seam deliberately does **not** edit the PR body on GitHub. Keeping the
GitHub path a pure token-printer is what makes it byte-compatible with the
pre-seam flow (SPEC-105 §3) — the PR body is still authored by this skill, and
the ALM dimension stays dark until a repo declares a non-GitHub tracker.

See also: [`../../team-pipeline/references/alm-routing.md`](../../team-pipeline/references/alm-routing.md)
for the full write-path routing table, and the note there on why `pr-monitor`'s
**PR** comments correctly stay on `gh` — they are code-host writes, not tracker
writes.
