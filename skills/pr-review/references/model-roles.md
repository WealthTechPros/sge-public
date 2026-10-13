# Reviewer model roles (provider-neutral routing, sge#3035)

Bundled specialists used to hard-pin `model: sonnet` / `model: opus`. Copilot CLI
accepts only concrete ids (`claude-sonnet-5.5`, `gpt-6-sol`, ...), so those
launches failed before using a tool. Routing is now: **role + risk -> capability
class -> concrete id the active harness offers**.

## Classes

| Class | Roles (default) | Meaning |
|---|---|---|
| `standard` | `code-reviewer`, `design-reviewer` | Diff-scoped reasoning. A `deep` model is an acceptable upward fallback. |
| `deep` | `security-auditor`; any role with `--security` or `--class deep` | The security floor. Only `deep`-class ids qualify. |
| `light` | `impl-haiku` (team-pipeline's lightweight tier) | Mechanical lanes. Prefers its own `light` ids (haiku), then `standard`, then `deep` as an upward fallback; never anything below it. `--security` still forces `deep`. |

The id lists (ordered preference, Anthropic first, OpenAI after) live only in
`skills/pr-review/model-roles.json`. Change ids there, nowhere else.

## Resolver

```bash
bash skills/pr-review/resolve-model.sh --role security-auditor --security
bash skills/pr-review/resolve-model.sh --role code-reviewer [--override <id>]
```

Inputs: catalog = `SGE_MODEL_CATALOG_JSON` or `SGE_MODEL_CATALOG_FILE` (JSON
array of ids or `{id}` objects; whatever the harness advertises); override =
`--override`, else `overrides.<role>` from `SGE_MODEL_OVERRIDES_JSON`,
`SGE_MODEL_OVERRIDES_FILE` or `.sge/model-roles.json`
(`{"overrides":{"security-auditor":"<id>"}}`). Risk signal = `--security` when
`rl_security_files "$PR"` is non-empty.

Where the catalog comes from, per harness:

| Harness | Catalog |
|---|---|
| Claude Code | Not advertised programmatically. With `CLAUDECODE=1` and no catalog supplied, the table's `claude-*` ids are used (assumed accepted by `Agent(model:)`). |
| Copilot CLI / any other | The caller exports `SGE_MODEL_CATALOG_JSON` or `SGE_MODEL_CATALOG_FILE`. With none, a `deep` lane exits 3 (not run). |

A catalog that is supplied but unreadable, unparseable or empty is exit 3, even
for a `standard` lane. The role must be in the table's `roles` (bare name,
`security-auditor`, not `@security-auditor`); an unknown role is exit 2. An
override must be a single id (`[A-Za-z0-9._:/-]+`; a newline or space is exit 4).
`.sge/model-roles.json` is read from the tree under review, so it is **never
read for a `deep` lane** (a PR must not steer its own security floor); pass
`--override` or `SGE_MODEL_OVERRIDES_*` from the caller instead.

| Exit | Meaning | Lane outcome |
|---|---|---|
| 0 + id | resolved | spawn with `Agent(model: <id>)` |
| 0 + `default` | `standard` lane, no catalog available | omit `model:` (harness default) |
| 3 | no catalog for a `deep` lane, or an override that cannot be verified | **not run** |
| 4 | invalid override (malformed doc, unlisted, lower class, not in catalog) | **not run** |
| 5 | catalog has no eligible model at/above the class | **not run** |

A valid explicit override is honoured exactly; an invalid one is never replaced
by a default. An override that was *supplied* but is empty (`--override ""`, or
`overrides.<role>: ""` / a non-string value) is invalid (exit 4), never read as
absent. A `deep` requirement is never met by a `standard`-only model.

## Caller contract (fail closed)

1. `rl_reviewer_dispatch "$PR" "@<role>"` first, in the same step as the resolve.
   Resolve with `rl_reviewer_resolve_model "$PR" "@<role>" <role> [--security]`
   (prints the id and records it in the ledger as a `model` line). `pr-labels.sh
   pass` refuses (exit 5) a locally dispatched `@security-auditor` whose recorded
   model is missing or not in the table's `deep` class, because the agent file no
   longer pins a model and the lane would otherwise inherit the session model.
2. Resolver non-zero -> do not spawn; leave the id PENDING (or do that check
   inline). `pr-labels.sh pass` then refuses with exit 5; no `pr-reviewed`, no
   auto-merge. Report the lane as `incomplete`.
3. Spawn error ("Model ... is not available"), silence, or a reply with zero
   tool calls -> `rl_reviewer_attest` prints `not-run:*` and the id stays
   PENDING. Never fold it as `[]`.

## Verified vs assumed

Verified: the resolver, table, and fail-closed behaviour (mocked catalogs in
`skills/tests/pr-review-model-roles.test.sh`). **Assumed, not verified:** that
Copilot CLI exposes its catalog in the shape above (supply it via the env var),
that a subagent `model` can be set at spawn there, and that `gpt-6-sol` is a
`deep`-equivalent (listed in both classes from the ids named in sge#3035;
removing it from `deep` makes an OpenAI-only catalog fail closed for security).
The daemon's own tier table (`services/review-daemon-poc/model_routing.py`) is
unchanged and still maps tiers to its own ids.
