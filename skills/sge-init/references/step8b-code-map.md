# sge-init — Step 8b: code map and Copilot setup

Detail for Step 8b of `SKILL.md` (SPEC-142, #3464).

## Why

The digest (Step 8) gives a session the governance context. The code map gives it the code context: what each component and directory does and where to start reading, so a tool such as GitHub Copilot does not re-scan the repo each session. For Copilot, committed files are the only way to supply that context.

## What to propose

Propose running `/sge:code-map`. Tell the user what it will write, and write nothing until they approve:

- `docs/sge-code-map.md` and `docs/sge-code-map/<COMPONENT-ID>.md`, generated from the `docs/sgd-build/architecture.yaml` this skill seeded;
- a marker-delimited block in `AGENTS.md` and `.github/copilot-instructions.md` pointing at the digest and the code map (hand-written text is kept);
- the marketplace and `enabledPlugins` entries in `.claude/settings.json` (existing keys are kept).

If the user declines, record "code map and Copilot setup: not run" in the Review Package (Step 9) and continue.

## After it runs

`/sge:code-map` prints a report of what it did and what is left for the user (for example setting `core.hooksPath`, which an agent session may not do, and confirming the plugin loads in Copilot CLI). Carry the "left for you" items into the Review Package unchanged. Do not perform them.

## Skip when

- The repo has no `architecture.yaml` (the user declined it earlier): note the code map as a follow-up.
- The team does not use GitHub Copilot and does not want `AGENTS.md`: the code map alone can still be generated with `node <sge-plugin-dir>/scripts/build-code-map.mjs --repo .`.
