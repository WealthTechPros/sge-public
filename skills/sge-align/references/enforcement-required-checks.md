# Enforcement profile: required-check verification (SPEC-128 S3)

`assets/check-enforcement-required-checks.sh` answers one question for a repo
whose `.sge/posture.yaml` declares an enforcement profile: are the
enforced-profile gate checks *required* status checks on the default branch?
`check-gate-coverage.sh` proves from files that a gate is installed; this
script asks the GitHub API whether merging actually waits for it. The profile
contract is in `skills/sge-init/references/enforcement-profile.md`.

It is read-only, reports outside the composite Audit Score (like
`gateCoverage`), and leaves the platform's governance-posture evaluator
untouched.

## Run

```bash
GH_TOKEN="<operator or App installation token>" \
  bash "${CLAUDE_PLUGIN_ROOT}/skills/sge-align/assets/check-enforcement-required-checks.sh" <repo-root> [owner/repo] [branch]
```

`owner/repo` defaults to `gh repo view` in the repo root, and the branch to
the repository's default branch. In fleet mode, pass each repo's slug.

## Credentials

Use operator credentials (an `/sge:sge-align` operator's `gh` login, or
`SGE_OPERATOR_TOKEN`) or a GitHub App installation token. Never use a consumer
repo's CI `GITHUB_TOKEN`: it usually cannot read branch protection, and a
consumer workflow must not be the thing that certifies its own protection.
Inside GitHub Actions the only accepted credential is `SGE_OPERATOR_TOKEN`,
and it must differ (ignoring surrounding whitespace) from `GITHUB_TOKEN`,
`GH_TOKEN`, `GH_ENTERPRISE_TOKEN` and `GITHUB_ENTERPRISE_TOKEN` (on GHES `gh`
prefers the enterprise variables): Actions does not export `GITHUB_TOKEN` by
default, so a `GH_TOKEN: ${{ github.token }}` step cannot be told apart from an
operator token. Pass the operator or App token as `SGE_OPERATOR_TOKEN` alone.
Otherwise the script refuses before calling the API and reports `unknown`.

**Undetectable case.** If a workflow passes its own `github.token` only as
`SGE_OPERATOR_TOKEN`, with none of the four variables above exported, nothing
in the environment shows it is the CI token, so the script accepts it. The
impact is bounded: an Actions token cannot read classic branch protection, so
that source is unreadable and any gate it alone could show reports `unknown`
(exit 3), never `not-required` or a false `pass`. The guard catches mistakes;
it is not a substitute for passing only an operator or App token.

## Gates

| Check context | Exception gate | Checked |
|---|---|---|
| `Require commit trailer` | `require-commit-trailer` | always |
| `Require test evidence` | `require-test-evidence` | always |
| `Require enforcement profile` (S2 CI check) | `branch-protection` | always |
| `Require pr-reviewed label` | `branch-protection` | only where `require-pr-reviewed-label.yml` is adopted |

## Reading the result

Each gate is `required`, `not-required`, `exception` or `unknown`.

- **Sources.** Classic branch protection and rulesets are both read. A gate
  required by either is `required`.
- **not-required** only when both sources were read and neither requires it.
  Under `enforced` it is a failing finding (exit 1). Under `onboarding` it is
  informational (`severity: info`, exit 0).
- **exception**: a live `.sge/posture.yaml` exception for the gate (or for
  `branch-protection`) covers it; the evidence carries the reason, approver
  and expiry. An expired exception counts as absent.
- **unknown**: a source returned 403 or 404, or credentials were refused, and
  the gate was not found in what could be read. The JSON `sources.reason`
  carries the error. Exit 3. Unknown is never a pass; fix the credentials and
  re-run. A 404 from classic protection can mean "not protected" or "no
  access", and the script cannot tell which, so it does not guess.
- A malformed `posture.yaml` fails closed (exit 1) with the reader's error.

Exit codes: 0 pass/info, 1 fail, 2 harness error, 3 unknown.

## Scorecard line

Add one line under the gate-coverage summary:
`Enforcement required checks: <status> (<profile>) — <n> required, <n> not required, <n> exception, <n> unknown`,
and list each `not-required` or `unknown` gate by name.
