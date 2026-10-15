# Forgejo/Gitea review gate — live validation runbook (S6)

Reference for [`../SKILL.md`](../SKILL.md) and
[`host-adapter-routing.md`](host-adapter-routing.md). It prepares the **human**
live run of #3073 (S6 of #3029) so that the human part is about half an hour of
supplying an instance and reading a results block, not designing the pass.

The Forgejo gate (slices E1, S1-S4: claim, verdict, hold, merge) is tested
offline against a stateful curl stub and was live-validated once (2026-10-14 and
2026-10-15, below), apart from two gaps. Re-run this runbook against a real
instance and paste the results into `host-adapter-routing.md` after a change to the gate. **No agent runs this.** The driver refuses to run
without an explicit human opt-in, never runs in CI, and writes only to a
throwaway repo the operator names twice.

## Prerequisites

| Need | Detail |
|---|---|
| A Forgejo instance and its version | Preferred: a disposable container (`codeberg.org/forgejo/forgejo` image) on a private network, so a mistake costs nothing. A production instance is the higher-risk option (decision recorded on #3083). The driver reads `GET /api/v1/version` and prints it. |
| A throwaway repo | e.g. `acme/throwaway` on `git.example.invalid`. Nothing in it matters; the run applies labels, posts claim refs and comments, writes commit statuses, and (opt-in) merges one PR. |
| Branch protection on the base branch | `enable_status_check` on, `status_check_contexts` non-empty (at least `ci/build` or whatever the PRs report), `required_approvals` set (0 or 1). The merge step refuses a repo whose protection cannot enforce the gate, and the driver pre-checks it. |
| PR `clean` (required) | Open, not draft, CI context green, no unresolved review threads. **It is consumed:** with the merge step enabled it is merged, so use a fresh PR per run. |
| PR `red` (optional) | Open, not draft, a required context red (a failing status). |
| PR `threads` (optional) | Open, not draft, CI green, one or more unresolved review threads. |
| Two identities | The claim race needs two concurrent claimants. Preferred: two Forgejo accounts, two tokens (`FORGEJO_API_TOKEN` and `SGE_FORGEJO_LIVE_TOKEN_B`). One token also works: the claim keys on `SGE_AGENT_ID`, and the driver gives the two racers different ids. |
| Credentials | From your secrets manager, names only here: the Forgejo PAT(s) as `FORGEJO_API_TOKEN` (and `SGE_FORGEJO_LIVE_TOKEN_B`), injected into the command's environment. Scope: repo read/write on the throwaway repo. **Identity A (`FORGEJO_API_TOKEN`) must be a repo admin** for the branch-protection read and for step 6 (see F1 below). Never write a value into a file, a shell history line or this doc. |
| `SGE_FORGEJO_HOSTS` | `;`-separated allow-list that **must** contain the instance host (bare host or `host:port`). The driver and the adapter both refuse an unlisted host; a name that merely looks like Forgejo is routing, not trust. |
| `FORGEJO_ADAPTER_ALLOW_WRITE=1` | Explicit write consent. The driver refuses without it. |
| Tools | `bash`, `curl`, `jq`, `git`. |

## Environment

```bash
# Names and shapes only. Values come from your secrets manager or your shell, never a file.
export SGE_FORGEJO_LIVE=1
export SGE_FORGEJO_HOSTS="git.example.invalid"
export SGE_FORGEJO_LIVE_ORIGIN="https://git.example.invalid/acme/throwaway"
export SGE_FORGEJO_LIVE_CONFIRM_REPO="acme/throwaway"   # must equal the origin slug
export SGE_FORGEJO_LIVE_PR_CLEAN=<n>
export SGE_FORGEJO_LIVE_PR_RED=<n>        # optional
export SGE_FORGEJO_LIVE_PR_THREADS=<n>    # optional
export FORGEJO_ADAPTER_ALLOW_WRITE=1
# FORGEJO_API_TOKEN (and optionally SGE_FORGEJO_LIVE_TOKEN_B) come from:
#   <your secrets manager's run-with-secrets wrapper> -- <command>
# Opt in to the one destructive step (merges the clean PR):
# export SGE_FORGEJO_LIVE_ALLOW_MERGE=1
```

## Steps and expected exit codes

`scripts/forgejo-live-validate.sh` runs these in order. Every step is a real
`skills/pr-review/pr-labels.sh` call, with `FORGEJO_ORIGIN` pinned to the
throwaway repo. `pr-labels.sh` exit codes: 1 refusal, 3 claim lost, 7 claim not
held, 8 hold present, 9 not eligible / no delegation policy.

| # | Step | Command (inside the driver) | Expected |
|---|---|---|---|
| 0 | Preflight (read-only) | `get-pr`, `branch-protection`, `/api/v1/version` | PRs open and not draft; protection has `status_check_contexts`; head is 40-hex. Any failure stops the run before a write. |
| 1 | Warm-up | `pr-labels.sh start-review <clean>` then `release-review <clean>` | exit 0, exit 0. Creates `pr-reviewing` / `pr-reviewed` / `changes-requested` once, so the race below does not race label creation. |
| 2 | Claim race | two concurrent `start-review <clean>`, identities A and B | **exactly one exit 0 and one exit 3** (`claim lost`). The lane is then force-released. |
| 3-pre | No claim held | `pass <clean> --expect-head <head>` before any `start-review` | exit 7 (claim not held). |
| 3-pre | No `--expect-head` | `start-review <clean>`; `pass <clean>` | exit 1. |
| 3a | Moved head | `start-review <clean>`; `pass <clean> --expect-head 000…0` | exit 1, "head moved"; `pr-reviewed` absent. |
| 3b | CI red | `start-review <red>`; `pass <red> --expect-head <head>` | exit 1, "CI at … is …"; `pr-reviewed` absent. Skipped (and flagged) without `PR_RED`. |
| 3c | Unresolved threads | `start-review <threads>`; `pass <threads> --expect-head <head>` | exit 1, "unresolved review thread"; `pr-reviewed` absent. Skipped (and flagged) without `PR_THREADS`. |
| 4 | Verdict | `start-review <clean>`; `pass <clean> --expect-head <head>`; `stale <clean>` | exit 0, `pr-reviewed` present, commit status `sge/pr-review` = success on the head; then exit 0 and `pr-reviewed` absent. |
| 5 | Hold | `start-review`; `apply-hold <clean> --reason … --head <head> …`; `pass <clean> --expect-head <head>`; `release-hold <clean> --order live-validate --head <head>` | exit 0 and `hold` present; exit 8; **exit 9** (no delegation policy is wired on Forgejo; a human removes the label) and `hold` still present. The driver then removes `hold` (the human action) and releases the claim. |
| 6 | Merge | `start-review`; `pass <clean> --auto-merge --expect-head <head>` | exit 0, pinned to the head SHA. **Needs `SGE_FORGEJO_LIVE_ALLOW_MERGE=1`; merges the clean PR.** Skipped (and flagged) otherwise. |
| 7 | Cleanup | `release-review --force`, `release-fix --force`, label removal | Always runs (trap on exit, interrupt, termination and failure). Removes the claim refs and only the gate labels this run added; a label already on the PR at preflight is left. |

Run it:

```bash
# with the token variables injected by your secrets manager:
bash scripts/forgejo-live-validate.sh 2>&1 | tee /tmp/forgejo-live-results.txt
```

Exit: `0` skipped or every executed step passed, `1` a step or the cleanup
failed, `2` refused (nothing was called).

## Live findings (S6 run on #3073, 2026-10-14, Forgejo 16.0.2)

Observed live; the expectations above were corrected to match. Claim race
(exit 0 / exit 3), verdict, hold (pass exit 8, `release-hold` exit 9, label
kept), `stale` and the refusals (exit 1 for head moved, CI red or `none`,
unresolved threads, missing `--expect-head`; exit 7 with no claim) all behaved
as listed.

- **F1 (#3122): arming needs a repo-admin identity.** `pass --auto-merge` reads
  branch protection, which Forgejo/Gitea allows only to repo admins. A
  write-collaborator token records the verdict, then the arm fails closed
  ("no readable branch protection", exit 1). Run step 6 (and the protection
  preflight) with an admin token as identity A; until #3122 is fixed, a FAIL
  there with a non-admin token is this finding, not a new bug. The non-admin arm
  stays listed as not validated in the `host-adapter-routing.md` marker.
- **F3:** a stale claim taken by one token identity needs `--force-claim` from
  another identity; the same identity with a different `SGE_AGENT_ID` takes over
  without it. Intended.
- **F4:** short claim TTLs (45 s) are unusable from Windows Git Bash (each claim
  verb takes over 10 s). Run the driver from Linux or WSL.
- **F5:** the adapter's merge path is hard-wired to squash.
- **F2:** `claim-status`, `claim-work`, `release-work` and
  `reconcile-orphaned-claim` still fall through to an inline `gh pr view` on a
  Forgejo host (fail closed, exit 1). The driver does not call them.
- Not exercised by the driver: orphan-ref takeover (needs a claimant that dies
  between the ref and record writes).

## Re-run 2026-10-15 (Forgejo 16.0.2, `git.example.invalid`, sge PR #3144 code; results on #3073)

All executed steps passed. Claim race (A exit 0, B exit 3); a 120 s claim stays live
past its TTL while heartbeats extend it, then goes stale; a different token identity
cannot take a stale claim without `--force-claim` (exit 3), the same identity with a new
`SGE_AGENT_ID` takes generation 2, and `--force-claim` takes it (exit 0). `pass`
refusals: no claim (7), no `--expect-head` (1), CI `none` (1), moved head (1), red CI
(1), unresolved thread (1). `pass` and `fail` set their labels and commit statuses. Hold:
`apply-hold` 0, `pass` 8, `release-hold` 9 with the label kept. Merge arm (#3127): with
`sge/pr-review` not among the required contexts the arm refused (exit 1, nothing merged);
with it required, an admin identity squash-merged pinned to the head. The four unported
work-lane verbs exit 2 and never call `gh` (#3123). Not exercised: orphan-ref takeover.
The non-admin arm still fails closed (HTTP 403, #3122).

## What a human must do, and look at

1. Provision the instance, repo, protection and the PRs above.
2. Export the environment and run the command above.
3. Eyeball the Forgejo UI once: the claim refs under `sge-claims/` are gone
   from the branch list, the labels are off the PRs, and (if merged) the merge
   commit is the expected head. Commit statuses `sge/pr-review` /
   `sge/pr-review-shadow` written on the PR heads **remain** (a status cannot be
   deleted); that is expected on a throwaway repo.
4. Paste the results into `host-adapter-routing.md` (below). A clean driver run does
   not remove the "live-validated, with two gaps" marker: the driver needs an admin
   identity for the merge step and never exercises orphan-ref takeover, so drop the
   marker only once both the non-admin merge arm and orphan-ref takeover have
   recorded results.

If a step FAILs, do not change the marker: file the gap on #3073 with the
results block and the Forgejo version.

## Results template

The driver prints this block ready to paste. The shape, for reference:

```markdown
### Forgejo gate live validation

- Date (UTC): YYYY-MM-DD
- Instance: git.example.invalid
- Forgejo version: <from /api/v1/version>
- Repo: acme/throwaway   PRs: clean=#<n> red=#<n|none> threads=#<n|none>
- Merge step: enabled | disabled
- Overall: PASS | PASS (incomplete: N skipped) | FAIL (N failed)

| Step | Expected | Got | Outcome |
|---|---|---|---|
| claim race (two concurrent start-review) | one exit 0, one exit 3 | exit 0 / exit 3 | PASS |
| pass refuses a moved head | exit 1 | exit 1 | PASS |
| pass refuses red CI | exit 1 | exit 1 | PASS |
| pass refuses unresolved threads | exit 1 | exit 1 | PASS |
| pass records the verdict | exit 0 | exit 0 | PASS |
| pass refuses while hold is present | exit 8 | exit 8 | PASS |
| release-hold refuses without a delegation policy | exit 9 | exit 9 | PASS |
| pass --auto-merge pinned to the head | exit 0 | exit 0 | PASS |
| cleanup (claim refs, labels) | none left | none left | PASS |
```

## Safety properties (what the guard test pins)

`skills/tests/forgejo-live-validate-guard.test.sh` runs offline with stubbed
`curl`/`gh`/`git` and pins that the driver:

- skips (exit 0, no network) unless `SGE_FORGEJO_LIVE=1`;
- refuses (exit 2, no network) an origin whose host is not in
  `SGE_FORGEJO_HOSTS`, a repo not confirmed by `SGE_FORGEJO_LIVE_CONFIRM_REPO`,
  a missing `FORGEJO_ADAPTER_ALLOW_WRITE=1`, a missing token, a non-https or
  credential-bearing origin, and any CI environment;
- refuses (exit 2, no network) when `PR_RED`, `PR_THREADS` and `PR_CLEAN` are not
  three distinct PRs;
- is not referenced by any workflow.
