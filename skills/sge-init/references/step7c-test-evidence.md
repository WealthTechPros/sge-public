# sge-init — Step 7c: TDD test-evidence gate (#784)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Propose adding the test-evidence gate alongside the change-protocol guardrails (AI proposes, human disposes — write only after approval):

- `.sge/test-map.yml` — from `${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/sge-init/templates/test-map.yml`. Tailor the commented-out `production_paths`/`test_paths` globs to the repo's actual languages and layout before uncommenting them; leave `mode: advisory` — never seed a new repo straight into blocking (Step 9 proposes a concrete graduation criterion — don't leave "Phase 2" undefined).
- The CI workflow, copied from this framework repo's own `.github/workflows/require-test-evidence.yml` (it has no repo-specific content — same install mechanism as any other CI file: copy it into the onboarded repo's `.github/workflows/`).

The gate reads `.sge/test-map.yml` for its production/test path classification, or falls back to built-in language-aware defaults if the file is absent or left with no uncommented lists — so it produces *some* signal even before this file is tailored. The in-session companion (`hooks/tdd-guard.sh`, ships with the plugin, no per-repo install needed) reads the same file for its warn-by-default nudge.

Skip this step and note it in the Review Package if the repo has no CI, or is a docs-only/ideation-stage repo with no runtime code to gate (see `org-context.md`'s "SGE ideation only" repos).
