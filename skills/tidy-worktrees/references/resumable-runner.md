# Resumable fleet runner

`fleet.mjs` automates queue bookkeeping, bounded audit preparation and exact
cleanup-plan assembly. The skill remains the coordinator for value assessment,
code completion, owning checks, publication and approved execution. This is
not an unattended coding service, automatic merge, deletion scheduler or
installed lifecycle hook.

Requires Node.js 22+ plus the existing audit's Git Bash, Git, jq and host
adapter dependencies. On Windows the runner selects Git for Windows' Bash,
not a WSL shim; `SGE_BASH` may select an explicitly trusted alternative.

## Resume once, not another discovery

Use an existing metadata queue containing `cutoff`, `scope` and `rows`.
Each row carries `root`, `path`, `branch`, `recoverySha`, `state`, `evidence`
and optional `creationTimeSnapshot`. `PENDING_REVIEW` is unfinished;
other states retain their completed assessments. Removed entries stay removed,
today's entries are deferred, and unknown ages remain reviewable.

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/tidy-worktrees/fleet.mjs"
node "$S" init --state /local/task/fleet.json --queue /local/task/existing-queue.json
node "$S" status --state /local/task/fleet.json
node "$S" next --state /local/task/fleet.json --lane recovery --limit 5
node "$S" audit --state /local/task/fleet.json --limit 5
```

State and artifacts must be outside versioned source and synchronised folders.
Never re-import over an existing state file. Queue writes use an exclusive
short-lived lock, revision comparison and atomic replacement; a busy/stale
lock refuses writes, never transfers ownership by age. Retain the file and
resolve its exact writer/lock through a supervised decision. An interrupted
read-only audit has not consumed queue entries; the next invocation resumes.

One packet has at most five targets and a ten-minute wall-clock budget.
Audit preparation runs the existing repository-wide helper once per selected
repository; this is metadata, not five completed file-level reviews. It does
not invent a target-only audit. Completed unrelated assessments are retained.
Azure DevOps active and completed PR pages are loaded once per repository
per audit process. The completed index requires exact source heads, completion
dates and the actual default target branch. Failed or capped pagination keeps
affected targets; it never falls back to repeated per-branch history requests.
Existing non-runner audit invocations retain their original lookup behaviour.

## Complete valuable work, then revisit merge

`recovery` targets need file-level value assessment, a real task/owner binding,
safe preservation, reconciliation with current main and owning checks before
the coordinator creates/reuses a draft PR. Do not treat bucket B or a source
snapshot as proof of value or acceptance. Keep whole-task criteria separate
from a contributing patch.

After reviewing a target, record the disposition and an existing evidence
artifact. This is a metadata handoff, not a review-verdict or acceptance grant.

```bash
node "$S" record --state /local/task/fleet.json --path /repo/worktree \
  --status recovery --reason "finish the selected patch after owner handoff" \
  --evidence /local/task/assessment.json --priority 0
node "$S" next --state /local/task/fleet.json --lane merge
node "$S" invalidate --state /local/task/fleet.json --path /repo/worktree \
  --reason "verified PR merged; refresh this target"
```

`merge` means await actual authorised merge, not enable automatic merge.
The next audit reclassifies the target; dirty work, changed tips, claims and
locks still prevent ordinary cleanup. Phase 2b choices remain separate.
No command automatically commits, pushes, opens a PR or removes anything.

## One exact cleanup approval

```bash
node "$S" plan --state /local/task/fleet.json --limit 5 --out /local/task/plan.json
```

This refreshes selected candidates, records full recovery SHAs and all ignored
filenames with a filename-set hash, and emits exact existing-executor argument
arrays. The plan is unapproved and cannot overwrite an earlier approval file.
A SHA protects committed objects, not ignored contents or editor buffers.
Obtain exact path/tip approval, no-writer/buffer confirmation and separately
named ignored-file consent. Inspect collateral `worktree prune --dry-run`
and use the mandatory junction guard and existing executor serially. Record
its immutable execution and recovery receipts; no predicted merge or elapsed
age authorises disposal.

Immediately before **each** approved removal, verify the reviewed plan's
printed fingerprint, the fresh audit/tip and the complete live ignored-filename
set. This is not approval. Any mismatch requires a new plan and applicable
consent; never send old executor arguments after a failed verification.

```bash
node "$S" verify-plan --state /local/task/fleet.json --plan /local/task/plan.json \
  --path /repo/worktree --fingerprint <reviewed-plan-sha256>
```

Use the newly verified audit/selector with the reviewed recovery CSV path, then
execute that one target immediately. Stop if any writer resumes or intervening
change occurs. The executor retains its own immediate guards; the runner
does not create atomic exclusion against unmanaged writers.

```bash
node "$S" record --state /local/task/fleet.json --path /repo/worktree \
  --status removed --reason "approved executor completed and collateral checked" \
  --evidence /local/task/execution.txt --recovery /local/task/recovery.csv
```

Removal recording verifies an exact DONE receipt and full recovery CSV row,
the absent folder/branch/native entry and the readable recovery object.
It does not run removal or certify collateral preservation by itself.
Report removed, remotely preserved, blocked and remaining separately; the
runner's counts are the imported queue snapshot, not a fresh fleet inventory.
