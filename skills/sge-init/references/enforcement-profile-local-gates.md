# Enforcement profile — local gates (SPEC-128 S1)

How the local, developer-side gates follow the repo's enforcement profile.
Contract: [`enforcement-profile.md`](enforcement-profile.md). Governing spec:
`docs/specs/SPEC-128-consumer-enforcement-profile.md`.

All three gates read the profile with the plugin's
`scripts/read-enforcement-profile.sh`. None of them copies the parser.

## `commit-msg` hook (`templates/commit-msg`)

Installed by Step 7 as `.githooks/commit-msg` (or `.husky/commit-msg`). It
carries the marker line `# sge-commit-msg: enforcement-profile-aware (SPEC-128)`,
which the CI check (`enforcement-profile-ci-check.md`) uses to tell this
variant from the older warn-only hook.

| Profile | Commit with neither `Spec:` nor `SGE-Override:` |
|---|---|
| `onboarding` (no file, or no `enforcement:` key) | warning, exit 0 |
| `enforced` | rejected (exit 1); the message names both missing trailers |
| `enforced` + live `commit-msg` exception | allowed; prints `EXCEPTION commit-msg: <reason> (<approver>, until <date>)` |
| `enforced` + expired `commit-msg` exception | rejected; the message says the exception expired |

The hook runs outside Claude, so it locates the reader itself, in this order:
`SGE_ENFORCEMENT_READER`, `$SGE_PLUGIN_ROOT/scripts/`,
`$CLAUDE_PLUGIN_ROOT/scripts/`, `scripts/` in the repo, then the Claude Code
plugin cache and marketplace directories under `~/.claude/plugins/`.

**Fail closed.** When `.sge/posture.yaml` declares an `enforcement:` key and
no reader is found, or the reader reports an error (for example
`invalid-enforcement-value`), the commit is rejected. So is a reader that
exits 0 but prints no profile line, and a `posture.yaml` that is a directory
or a dangling symlink. The hook only assumes `onboarding` when the file or
the key is absent, which the contract defines as onboarding.

Decisions (sge#2877):

- **Reader order.** A repo-local `scripts/read-enforcement-profile.sh` is used
  before the installed plugin copy. That is deliberate (in the SGE repo the
  repo copy is the plugin reader under change), and a repo-local reader is
  committed and reviewed like the hook itself. Set `SGE_ENFORCEMENT_READER`
  to pin one explicitly.
- **Skipped subjects.** A subject starting `Merge `, `Revert `, `fixup! ` or
  `squash! ` skips the trailer check, here and in `require-commit-trailer.yml`
  alike, so git's generated merge and revert commits pass. An ordinary commit
  titled that way also skips in both places. Accepted: the skip is keyed on
  git's own subject format, and such a title is visible in review.
- **Trailer content is not validated.** Any `Spec: SPEC-NNN` passes; whether
  the spec exists is the job of the spec-ref gates, not this hook.

## `.sge/test-map.yml` mode

When sge-init (Step 7c) scaffolds `.sge/test-map.yml` from
`templates/test-map.yml`:

- Profile `onboarding` (every new repo): keep `mode: advisory`.
- Profile `enforced` (an existing repo that has already promoted): write
  `mode: blocking`. An enforced repo with an advisory test map fails the CI
  check, so seeding advisory there would only create a failing PR.

Read the profile first with
`"${CLAUDE_PLUGIN_ROOT}/scripts/read-enforcement-profile.sh" .` and pick the
mode from its `enforcement` line. Both modes are documented in the template
header.

## `hooks/tdd-guard.sh`

Ships with the plugin; no install step. Its PreToolUse pass blocks an edit to
a production path with no test evidence this session when either:

- `SGE_ENFORCE` lists `tdd`. It is a comma list: `SGE_ENFORCE=tdd`,
  `SGE_ENFORCE=tdd,lint` and `SGE_ENFORCE=" lint , tdd"` all enable it.
  Unknown entries are ignored with a warning on stderr. A single value
  behaves as before.
- `.sge/posture.yaml` declares `enforcement: enforced`.

A live `tdd-guard` entry under `enforcement_exceptions:` lets the edit through
and puts `EXCEPTION tdd-guard: <reason> (<approver>, until <date>)` in the
hook output as audit evidence. An expired entry counts as absent. A reader
error fails closed: the guard blocks and names the error.

The profile is read only when `.sge/posture.yaml` exists, so a repo with no
posture file and no `SGE_ENFORCE` keeps the zero-cost PreToolUse exit (#895).

Decisions (sge#2877):

- **No jq.** With blocking on and no jq, a PreToolUse Edit/Write is denied
  (fail closed), except that a live `tdd-guard` exception still lets it
  through and is named in the output. Exempt paths are not recognised in
  that case: without jq the payload is not parsed, so there is no path to
  classify. Install jq.
- **The exception covers the gate, whatever turned it on.** A live
  `tdd-guard` exception is honoured when blocking comes from `SGE_ENFORCE=tdd`
  too, because the exception is the repo's reviewed decision about this gate.
- **Unknown `SGE_ENFORCE` entries** warn on stderr on every invocation. That
  is cheap and only shows in hook debug output; fix the variable to silence it.
- **The repo-root walk is lexical.** It looks upward from the session
  directory for the first `.sge/posture.yaml` or `.git`, by path string, not
  by resolving symlinks. A symlinked session root, a nested `.git` (a vendored
  checkout or submodule) or a nearer `posture.yaml` set to onboarding decides
  for that subtree. That is the intended rule: the nearest repo owns its
  profile. Open sessions at the repository root.
- **Only Edit and Write are gated.** Other tools that write files (Bash
  redirection, NotebookEdit) are not checked in-session; the
  `require-test-evidence` CI gate is the diff-based backstop.
