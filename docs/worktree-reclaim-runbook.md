# Runbook: reclaiming hundreds of stuck worktrees

Use this procedure when stale claims leave worktrees marked "in use by another session".

Nothing here deletes work without one typed confirmation. Every reclaimed worktree has a
recovery CSV row, and its uncommitted or unmerged work goes to a rescue ref first.

## 0. Before you start

1. **Close every agent session.** That means Claude Code, GitHub Copilot CLI and VS Code agent
   mode, on every machine that uses these clones. `reclaim.sh` refuses to run while a `claude` or
   `copilot` process is running (exit 5).
2. **Install SGE 4.39.37 or later.** Check for the reclaim script with
   `ls "$SGE/skills/tidy-worktrees/reclaim.sh"`, where `$SGE` is the plugin root.
3. **Open a plain terminal.** Use Git Bash on Windows. Do not run this from inside an agent session.
4. **Azure DevOps credential.** Export `SGE_AZDO_TOKEN`, a read-only Code PAT. Without it the
   open-PR set is unknown and nothing is reclaimed (exit 3).

```bash
SGE="<path to the sge plugin>"      # e.g. ~/.claude/plugins/marketplaces/sge
REPO="<path to the main clone>"     # a repo with many linked worktrees
export SGE_AZDO_TOKEN="<read-only Code PAT>"
```

## 1. Inspect worktrees and retire stale registrations

These only move or re-read state. None of them removes a worktree.

- **Retire the ownership registry** (sge#3726). Old registrations never expired, and they are the
  main "in use" cause. This archives them under `<git-common-dir>/sge-worktrees/retired/<ts>/` and
  touches no worktree:

  ```bash
  bash "$SGE/skills/lib/worktree-lifecycle.sh" retire-registry "$REPO"
  # archived:<n>  dir:<archive>; any busy:<path> lines -> rerun once nothing is running
  ```

- **Stale leases free themselves.** A `.sge-wt-claim` older than `SGE_WT_CLAIM_TTL_MIN` minutes
  (default 30) counts as free (sge#3701). Do not delete lease files by hand.
- **See what is open, read-only:** `bash "$SGE/skills/tidy-worktrees/audit.sh" --fetch --summary "$REPO"`.

## 2. Preview the reclaim

```bash
bash "$SGE/skills/tidy-worktrees/reclaim.sh" --dry-run "$REPO"
# or every repo under a folder:
bash "$SGE/skills/tidy-worktrees/reclaim.sh" --dry-run --multi "<parent-dir>"
```

Per repo it makes one fetch, one open-PR read and one completed-PR index read, then prints one
`CLASS` line per worktree and a `RECLAIMABLE <n>` summary. After confirmation it checks the open
PRs again, once per selected repo. A newly opened PR keeps its checkout in place. If the host
cannot verify a repo's PRs, the whole run stops before creating snapshots or parking checkouts.

| Class | Meaning | What happens |
|---|---|---|
| `RECLAIM` | Clean, and merged or the head of a completed PR | The original path is freed by moving the entire registered checkout to a sibling directory |
| `SNAPSHOT+RECLAIM` | Uncommitted changes, or commits not in the default branch | The work is committed to `refs/sge/rescue/<ts>/<branch>`, verified, then the original checkout is parked as above |
| `UNKNOWN` | Open PR or unknown PR state, live lease, created in the last 10 minutes, git-locked, detached HEAD, a stash on its branch | Listed only, never touched |

For git-locked worktrees, use `/sge:tidy-worktrees` Phase 2b. For locked dirty worktrees whose
work landed on another branch, see sge#3696.

**Required before step 3: keep secrets and client data out of the rescue refs.** A snapshot
commits every untracked, non-ignored file into a git object. A local ref is still the repository,
so a secret or real client data must never get that far. For each `SNAPSHOT+RECLAIM` worktree,
list what the snapshot would take:

```bash
git -C <path> ls-files --others --exclude-standard   # untracked files the snapshot would commit
git -C <path> status --porcelain                     # plus modified tracked files
```

If any file is a secret (keys, tokens, `.env`-style files) or real client data (exports,
downloads, statements):

1. Move it out of the worktree first. Secrets go to your approved secret store. Client data goes to the client's
   approved store. Do not copy it into another repo or worktree.
2. Until that is done, exclude the worktree from the run: `git -C "$REPO" worktree lock --reason
   "sensitive files pending" <path>`. A git-locked worktree is `UNKNOWN` and never touched.
   Unlock it (`git worktree unlock <path>`) only after the files are gone, then preview again.

Worktrees with no such files continue through step 3 as documented.

## 3. Reclaim

```bash
bash "$SGE/skills/tidy-worktrees/reclaim.sh" --recovery ~/reclaim-$(date +%Y%m%d-%H%M).csv "$REPO"
# Type RECLAIM <n> to reclaim <n> worktree(s); anything else stops:
```

The order is fixed:

1. The recovery CSV is written first. It is created exclusively and never overwritten.
2. You confirm once, typing the exact `RECLAIM <n>`.
3. The rescue snapshots are taken without changing the original checkouts.
4. The executor moves each eligible registered checkout into an exclusively created sibling
   directory on the same volume. The original path is freed. The branch remains checked out
   at the parked path, and the files retain their disk space until a separate, verified cleanup.
5. Worktrees with Windows directory reparse points are retained. Native POSIX symlinks are
   recorded in rescue snapshots as Git symlink entries. Windows can refuse a move while a file
   is open. The executor reports `parking-refused`; the checkout and its branch remain available.

Remote branches stay untouched. An eligibility check that fails reports `SKIP` with its
reason. A file written after the final scan stays with its checkout during the move. For
unattended operation, supply `--confirm "RECLAIM <n>"` matching the dry-run count.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Dry run, no eligible worktrees, or all confirmed items parked |
| 1 | Not confirmed, nothing touched |
| 2 | Usage |
| 3 | Fetch or host lookup failed, nothing done |
| 4 | Recovery CSV already exists |
| 5 | An agent process is running or its absence could not be verified |
| 6 | At least one confirmed item was skipped. Review the per-item reasons and recovery CSV before retrying. |

## 4. Restore something

Each CSV row names the original and parked paths and supplies a shell-quoted reverse move.
Run it only after reading the row and confirming the paths. It refuses an occupied original
path and moves the parked checkout back intact, including its index and ignored files.
A checkout that was never parked remains at its original location with its files intact.

If the process stopped during a move and Git cannot find a parked checkout that exists at
the recorded path, use `git worktree repair <parked-path>` from the main checkout before
retrying the reverse move. A later bulk reclaim skips parked checkouts. Do not permanently
remove a parked checkout until its contents are covered by a verified recovery or the
operator explicitly approves their deletion in a separate cleanup.

For snapshotted rows, the separate `snapshot_restore` command materializes the verified
rescue ref in a new detached sibling. Its `RECOVERED` line gives that checkout's exact path.
Use it to inspect the snapshot without changing the parked or original checkout.

Rescue refs live under `refs/sge/rescue/`, so `git gc` keeps them. List them with
`git for-each-ref refs/sge/rescue`. Delete them only when you are sure, with
`git update-ref -d <ref>`.

## 5. Not covered

- **Ignored files** (for example `node_modules`, build output) are not captured. A late ignored write remains in the parked checkout. Worktrees already found to contain ignored files stay in place.
- **Stashes** are repo-global and never dropped. A worktree whose branch has a stash stays UNKNOWN.
- **Secrets or client data** in untracked files would be committed to the local rescue ref, so
  reclaim does not judge content: the check before step 3 is mandatory. A rescue ref is never
  pushed, but once a sensitive file is in it, removing the ref and pruning the objects is a
  clean-up, not a prevention.
