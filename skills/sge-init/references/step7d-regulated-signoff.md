# sge-init — Step 7d: regulated-output sign-off gate (SPEC-071)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Only for repos that render **regulated numbers to end users** (client valuations, cohort counts, suitability figures). Propose alongside 7c (AI proposes, human disposes):

- `.sge/regulated-paths.yml` — from `${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/sge-init/templates/regulated-paths.yml`. Tailor the commented-out `regulated_paths` globs to the files that render regulated numbers, and set the `signers:` list to the GitHub handles authorised to sign off. Leave `mode: advisory` — never seed a new repo straight into blocking (Step 9 proposes a concrete graduation criterion — don't leave "Phase 2" undefined).
- The CI workflow, copied from this framework repo's own `.github/workflows/require-regulated-signoff.yml` (no repo-specific content — same copy-in install as any other CI file).

The gate requires a PR touching a `regulated_paths` file to carry a human sign-off, in either form: a **`signed-off` label** on the PR, or a **`Regulated-Sign-Off: @handle; <what you verified, ≥10 chars>`** trailer in the PR body or a commit. When a `signers:` list is declared, the sign-off must be **authenticated** — only the GitHub actor who applied the `signed-off` label may satisfy it (a trailer's `@handle` is free text and cannot self-sign); a repo that wants the lightweight trailer form declares no `signers:`. In advisory mode it warns only; a repo that declares no `regulated_paths` gets a permanently inert check — absence is not a gap.

Skip and note it in the Review Package for repos that render no regulated numbers.
