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
| `hooks/tdd-guard.sh` | advisory unless `SGE_ENFORCE=tdd` is set | blocks a production-path edit with no test change in the session |
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
    - "require-test-evidence | legacy importer has no harness yet | robaduncan | 2026-12-31"
  ```

  The fields are gate, reason, approver (GitHub login) and expiry
  (`YYYY-MM-DD`). The gate is one of `commit-msg`, `tdd-guard`,
  `require-commit-trailer`, `require-test-evidence`, `branch-protection`. A
  malformed entry is an error (`malformed-exception`). An expired entry counts
  as absent, so the gate blocks again. The entry is added in a reviewed PR,
  which is the audit record.

## Per-slice references

The slices that implement this contract add their own reference files:
skills/sge-init/references/enforcement-profile-local-gates.md (S1, #2834:
commit-msg hook, test-map and tdd-guard) and
skills/sge-init/references/enforcement-profile-ci-check.md (S2, #2835: the CI
check that names each missing or advisory gate).
