# Enforcement profile — onboarding to enforced (SPEC-128)

The contract for which SGE gates a consumer repo enforces, referenced from
`SKILL.md`. Governing spec: `docs/specs/SPEC-128-consumer-enforcement-profile.md`
(F-ENFORCE-PROFILE under CAP-METHOD-ADOPT).

## The profile key

A repo declares its profile in `.sge/posture.yaml` (template:
`templates/posture.yaml`):

```yaml
enforcement: onboarding   # or: enforced
```

- **Absent file or absent key means `onboarding`.** sge-init never seeds
  `enforced`: every gate starts advisory.
- **`enforced` is an explicit opt-in**, made in a reviewed PR that changes this
  one key.
- **Any other value is an error.** `scripts/read-enforcement-profile.sh` exits 1
  with `invalid-enforcement-value`; no reader falls back to `onboarding`.

Read the effective profile with `scripts/read-enforcement-profile.sh <repo-root>`.

## Controls and their mode per profile

| Control | `onboarding` | `enforced` |
|---|---|---|
| `commit-msg` hook (`templates/commit-msg`) | warns on a missing `Spec:` / `SGE-Override:` trailer, exits 0 | rejects the commit, naming the missing trailer |
| `hooks/tdd-guard.sh` | advisory unless `SGE_ENFORCE` lists `tdd` | blocks a production-path edit with no test change in the session |
| `require-commit-trailer.yml` (SPEC-063) | runs; findings are advisory to the merge | a failing run blocks the merge |
| `require-test-evidence.yml` via `.sge/test-map.yml` `mode:` | `mode: advisory` | `mode: blocking` |
| Required branch-protection checks (Step 7e) | recommended | `Require commit trailer` and `Require test evidence` are required status checks on the default branch |

Under `enforced`, a control that is missing or still advisory is a failure,
not a warning: the CI check reports each one by name.

## Promotion path: onboarding to enforced

1. Meet each seeded gate's graduation criterion from Step 9 (default: two
   weeks of green advisory runs with no missing-trailer PR merged), and close
   its QD record in `docs/sge/questions.md`.
2. Install every control in the table above: the `commit-msg` hook, both
   workflows, `.sge/test-map.yml` tailored to the repo.
3. Set `.sge/test-map.yml` to `mode: blocking` and make `Require commit trailer`
   and `Require test evidence` required checks on the default branch.
4. In the same reviewed PR, set `enforcement: enforced` in `.sge/posture.yaml`.

Demotion is the same PR in reverse, with the reason in the PR description.

## Overrides and exceptions

- **One commit:** the existing `SGE-Override: <STEP>; <reason>` trailer. It is
  recorded in history and visible in review.
- **One gate for a period:** a dated entry in `.sge/posture.yaml`. Each entry
  is one quoted line, so the file stays grep/awk-parseable:

  ```yaml
  enforcement_exceptions:
    - "require-test-evidence | legacy importer has no harness yet | octocat | 2026-12-31"
  ```

  The fields are gate, reason, approver (GitHub login) and expiry
  (`YYYY-MM-DD`). The gate is one of `commit-msg`, `tdd-guard`,
  `require-commit-trailer`, `require-test-evidence`, `branch-protection`. A
  malformed entry is an error (`malformed-exception`), including a field that
  holds a control character such as a TAB, or an expiry that is not a real
  calendar date. Write the keys plainly (`enforcement: enforced`). The parser
  fails closed by class: any other non-comment line that mentions
  `enforcement` (a quoted, tagged, anchored or explicit key, a flow mapping, a
  merge key or alias, a value, even an inline comment) or holds an escape
  inside double quotes is an error (`unsupported-enforcement-syntax`), as are
  CR-only line endings (`unsupported-line-ending`) and a NUL-bearing UTF-16 or
  UTF-32 file (`unsupported-encoding`). None is ever read as onboarding.
  Whole-line `#` comments may mention it freely. An expired entry counts
  as absent, so the gate blocks again. The entry is added in a reviewed PR,
  which is the audit record.

### Parser rules and decisions (sge#2877)

- **Top-level keys only.** `enforcement:` and `enforcement_exceptions:` start
  at column 0. An indented or nested `enforcement:` (under another mapping)
  is `unsupported-enforcement-syntax`, never the profile.
- **List items** may sit at column 0 (`- "..."`) or be indented. Both are read.
- **A reason needs at least one ASCII letter or digit.** A reason made only of
  blanks, a no-break space or punctuation is `malformed-exception`.
- **Bytes, not characters.** Both parsers read the file in the C locale, so
  non-ASCII bytes (NEL U+0085, LS U+2028, a stray `0xff`) give the same answer
  in any locale and under gawk or mawk. Non-ASCII whitespace is never trimmed:
  `enforcement:` followed by U+0085 is an invalid value, not `enforced`.
- **A dangling-symlink `posture.yaml`** is `unreadable-posture` in every
  consumer (reader, CI check, commit-msg hook, tdd-guard), never onboarding.
- **Live wins over expired.** A gate with both a live and an expired entry is
  covered by the live one in every consumer; the CI check prints the expired
  one as a `NOTICE`.
- **Dates.** Expiry is compared with today's date. The CI scripts use UTC;
  the local hooks (commit-msg, tdd-guard) use the machine's local date, so
  near midnight an entry can be live locally and expired in CI for a few
  hours. Accepted: the CI check is the authority. `SGE_TODAY` overrides today
  for tests; it is honoured anywhere, which only lets someone run their own
  hook against a different date, not change what CI decides.
- **Trust model.** The CI check reads the PR's own checkout, so a PR can
  demote the profile or add an exception for itself. That is by design (the
  change is visible and reviewed, and is the audit record), but it means the
  posture file needs the same review as code: put `.sge/posture.yaml` and
  `.sge/test-map.yml` under CODEOWNERS with a required code-owner review.
- **A `branch-protection` exception is broad.** It covers every required-check
  gate the S3 script verifies, and S3 does not examine `enforce_admins` or
  ruleset bypass actors. Use a gate-specific exception where one fits; admin
  and bypass posture is out of scope for SPEC-128.

## Per-slice references

The slices that implement this contract add their own reference files:
skills/sge-init/references/enforcement-profile-local-gates.md (S1, #2834:
commit-msg hook, test-map and tdd-guard) and
skills/sge-init/references/enforcement-profile-ci-check.md (S2, #2835: the CI
check that names each missing or advisory gate).
