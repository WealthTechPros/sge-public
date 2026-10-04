# Enforcement profile — CI check (SPEC-128 S2)

The CI half of the enforcement profile: a pull-request check that fails loudly
when a repo declares `enforcement: enforced` but a gate is missing or still
advisory. Contract: [`enforcement-profile.md`](enforcement-profile.md).

## Install (copy-in, same pattern as Step 7 / 7c)

Like `require-commit-trailer.yml` (Step 7) and `require-test-evidence.yml`
(Step 7c), the check ships as framework files that a consumer repo copies
verbatim. Neither file has repo-specific content:

```bash
PLUGIN="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}"
mkdir -p .github/workflows .github/scripts
cp "$PLUGIN/.github/workflows/require-enforcement-profile.yml" .github/workflows/
cp "$PLUGIN/.github/scripts/check-enforcement-profile.sh" .github/scripts/
```

The workflow runs on `pull_request` with `contents: read` and needs no secret
or extra token. Install it in every onboarded repo, including onboarding ones:
there it only prints notices, and it is in place before the repo promotes.
Once the repo is enforced, make `Require enforcement profile` a required check
on the default branch alongside `Require commit trailer` and `Require test
evidence`.

## What it reports

| Profile | Result |
|---|---|
| `enforced`, every gate installed and blocking | passes |
| `enforced`, a gate missing | fails; one `MISSING <gate>: <what> — fix: <how>` line per gate |
| `enforced`, a gate installed but advisory | fails; one `ADVISORY <gate>: ...` line per gate |
| live exception for a gate | `EXCEPTION <gate>: <reason> (<approver>, until <date>)`; that gate does not fail |
| expired exception | `EXPIRED <gate>: ...`; fails under `enforced` |
| `onboarding` (no file, or no key) | passes; findings print as `NOTICE` lines with the promotion path |
| malformed `posture.yaml` | fails closed, naming the reader error |

Gates it can see from a checkout:

- `commit-msg`: `.githooks/commit-msg` or `.husky/commit-msg` is the
  enforcement-profile-aware template (it carries the
  `sge-commit-msg: enforcement-profile-aware` marker). The older warn-only hook
  counts as advisory.
- `require-commit-trailer`: the workflow exists and is `pull_request`-triggered.
  `pull_request` must be a direct trigger of the top-level `on:` key (inline,
  in an inline list, or a key/list item one level under `on:`); comments,
  `pull_request_target`, `pull_request_review`, branch names and nested inputs
  do not count. Only a flat inline list or mapping is parsed: an inline `on:`
  value with any nested flow form (`on: {push: {branches: [main]}}`) reports
  ADVISORY, so write such triggers as a block mapping.
- `require-test-evidence`: the workflow exists, is `pull_request`-triggered,
  and `.sge/test-map.yml` says `mode: blocking`, read exactly as that workflow
  reads it (so `mode: "blocking"`, trailing spaces or CRLF count as advisory,
  because the gate itself would only warn).

The workflow also runs on `merge_group` and passes through there, so it can be
a required check on a branch with a merge queue.

`tdd-guard` runs in-session (see `enforcement-profile-local-gates.md`). Whether
the checks are *required* in branch protection needs the GitHub API, so
`/sge:sge-align` verifies it with `check-enforcement-required-checks.sh` (S3).

## Why the parser is vendored

A consumer CI checkout has no SGE plugin, so the script carries its own small
awk copy of `scripts/read-enforcement-profile.sh`.
`check-enforcement-profile.sh --print-profile <root>` prints exactly what the
plugin reader prints. In the SGE repo, `skills/tests/check-enforcement-profile.test.sh`
runs both over the same fixtures and fails if they drift. Change the reader
and the vendored copy in the same PR.
