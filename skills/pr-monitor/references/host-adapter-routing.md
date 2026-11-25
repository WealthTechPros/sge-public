# PR monitoring on GitHub and Azure Repos

Identify the host from the target checkout before reading PRs. Source `$SGE_ROOT/skills/lib/host-pr-read.sh` for `hpr_list`, `hpr_view` and `hpr_checks`. If the host is unknown or a read fails, retain the PR in the queue and report the failure.

On GitHub, use `pr_ready_for_merge` from the monitor to apply the repository's configured review gate. For a failed workflow, rerun its failed jobs.

On Azure Repos, source `$SGE_ROOT/skills/lib/host-pr-mutate.sh`. The `fpr_merge_ready` check requires a linked work item, a trusted approval for the current commit, and passing build policy. Where the review lane authorizes completion, `fpr_merge` requests a squash merge pinned to that commit. `fpr_add_label` and `fpr_remove_label` operate on PR tags. Failed-job reruns are unavailable through this adapter.
