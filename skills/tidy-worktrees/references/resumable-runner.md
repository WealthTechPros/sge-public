# Resumable fleet runner

`fleet.mjs` automates queue bookkeeping, bounded audit preparation and exact
cleanup-plan assembly. The skill remains the coordinator for value assessment,
code completion, owning checks and publication. Approved execution is an explicit
single-target command delegating to the existing executor. This is
not an unattended coding service, automatic merge, deletion scheduler or
installed lifecycle hook.

Requires Node.js 22.13+ (built-in SQLite) plus the existing audit's Git Bash, Git, jq and host
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

Use a bounded Cortex lookup for the existing non-secret ledger pointer and
handoff before discovery; memory is a lead, not the ledger, shared backup,
current safety evidence or approval. Keep the actual state in a durable,
protected local task store, not only an expiring session directory. A missing
or unreadable ledger blocks resume: locate or recover the original, never
re-import or silently start a replacement scan.

`audit` skips targets with existing reviews or audit results and refused
probes; it does not fetch or write when no target needs an audit. Reopen an
affected target only with `invalidate --path ... --reason ...` after new
evidence. Use `audit --path <target>` to select one ledger target. An unchanged
repository audit artifact can supply subsequent packets; a missing, altered or
refused artifact retains affected targets until an explicit invalidation.
These artifacts are dated metadata, not current deletion evidence.
This optimisation does not affect the fresh checks for `plan`,
`verify-plan` or `execute`. Those currently use the repository-wide audit
helper; do not claim they are target-only or bypass required safety gates.

One packet has at most five targets and a ten-minute wall-clock budget.
For an explicitly requested batch, `--limit 10` combines repository packets,
with at most five targets per repository. The runner audits
at most two distinct repositories in parallel, once per selected repository;
work within each repository and all approved removals remain serial.
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
No command commits, pushes or opens a PR. `execute` removes only one explicitly
approved, freshly revalidated target; it never chooses targets or grants consent.

Use `record --blocker <local-json>` for an unresolved gate. The object requires
`kind` (`owner`, `preservation`, `permission`, `host-evidence`, `acceptance` or
`approval`), `owner`, `nextAction` and `unblockEvidence`. `blocked` lists those
targets; `next` skips them until `invalidate --reason <new-evidence>` explicitly
reopens the target. Legacy rows remain readable; migrate their blockers from
existing evidence, not by guessing. Classification is not resolution.
Instruction loading is not source coverage: an instruction-only collector
result is partial with zero target reads, never an accepted assessment.

`preserved --path <target> --evidence <receipt>` verifies the exact remote branch
SHA with `ls-remote` and records committed-source preservation only. Dirty,
ignored, stash and buffer coverage and full acceptance remain separate.
`status` distinguishes removed, remotely preserved source, blocked, remaining
and classified-only rows; preservation can overlap remaining work. These are
ledger snapshots, not a physical census or acceptance counts.

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

Each plan binds the target's assessment revision. Recording a new disposition
or invalidating the target voids an earlier plan even if its Git SHA is
unchanged. Older plans without this binding require a new plan and consent.
An invalidated recovery target keeps its existing handoff after re-audit.

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

## Durable approval and interruption recovery

After actual human confirmation, write a local receipt with `fingerprint`,
`confirmedBy`, `confirmedAt`, `noWritersToolsOrUnsavedWork: true`, exact `paths`,
and `ignoredFiles: [{"path":"<worktree>","name":"<relative ignored filename>"}]`.
An empty ignored list is explicit. Never generate an affirmative receipt from
silence, an automated reviewer, a directory grant or general cleanup intent.
This receipt records consent; it does not prove it or replace native tool
confirmation, managed policy or the engineer's interactive approval.

```bash
node "$S" approve --state /local/task/fleet.json --plan /local/task/plan.json \
  --fingerprint <reviewed-plan-sha256> --evidence /local/task/human-receipt.json \
  --approval /local/task/approved.json
node "$S" execute --state /local/task/fleet.json --plan /local/task/plan.json \
  --fingerprint <reviewed-plan-sha256> --approval /local/task/approved.json --path /repo/worktree
```

Approval creation is exclusive. Execution rechecks source/base identity,
ignored names, claims, files and empty collateral-prune preview, then journals
intent/native refs/registry/stashes before calling the unchanged executor.
SQLite serialises cooperating executor calls and releases its transaction
after process failure. Output streams to an exclusive per-target receipt.
Afterward exact DONE/recovery and native collateral comparisons must pass.
Any change/denial stops that target; do not loop or switch tools. Separately
approved unrelated targets can continue serially after permission allows.

An existing operation journal forbids replay, even after interruption. Run
`reconcile` with the same arguments instead of `execute`: it performs no
deletion, checks existing DONE/full-SHA/native evidence and records a completed
removal only when all checks pass. Partial or missing receipts remain blocked.
It never settles a leftover branch, repairs a lock or fabricates DONE evidence.
An unresolved ledger write lock also requires supervised reconciliation.
Reusing unchanged approval never waives fresh checks; changed source/base or
ignored files requires a new plan and applicable consent.
