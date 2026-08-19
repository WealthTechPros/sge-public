# Target repo — resolve + assert FIRST

Issues #1558, #2207. Loaded by [`../SKILL.md`](../SKILL.md) before any read or write.

## Why this exists

Classification is only correct when every `gh` call **and** the artefact reads (`Read`/`Grep`/`Glob`) resolve against the *issue's* repo. `with-repo-cwd.sh` states the governing rule (SPEC-057, issue #817): a wrong-repo read/write is worse than a blocked skill, so this never falls through to "whatever cwd happens to be".

## The preload is advisory, never authoritative

The `!`-preload in `SKILL.md` runs at **skill-load time**, before any instruction in the body — so it can never be the authority on the target repo. It honours `--repo`/`GH_REPO` (issue #2207) and so no longer *silently* ignores an explicit target, but with neither set it still resolves against the session cwd and can load a *same-numbered issue in the wrong repo*. A matching issue *number* does not prove the *repo*.

Treat the preload as a convenience. The resolve + assert below is what makes the target correct.

## Do this as your first action

```bash
TARGET="${REPO_ARG:-${GH_REPO:-owner/repo}}"   # --repo wins, then GH_REPO, then the ambient repo
cd "$(${CLAUDE_PLUGIN_ROOT}/scripts/with-repo-cwd.sh resolve "$TARGET")" || exit 1
"${CLAUDE_PLUGIN_ROOT}/scripts/with-repo-cwd.sh" assert-repo "$TARGET" || exit 1
export GH_REPO="$TARGET"
```

`cd` (not a bare `GH_REPO`) is required — `GH_REPO` covers only `gh`, not the artefact reads. `assert-repo` confirms a bare `gh` write would hit the target; no-op same-repo, `NO_TARGET_ISSUE` refusal if unreachable. See [`gh-repo`](../../gh-repo/SKILL.md).

## Precedence (issue #2207)

| Source | Meaning | Wins over |
|---|---|---|
| `--repo <owner/repo>` | explicit caller intent | everything |
| `GH_REPO` | inherited dispatch context | ambient checkout |
| ambient checkout | last resort | — |

`--repo` takes precedence over `GH_REPO`, which takes precedence over the ambient checkout.

A `--repo` that resolves to no local checkout is a **hard `NO_TARGET_ISSUE` refusal** — never a silent fall-through to cwd, which is the whole defect this precedence exists to close.

Export `GH_REPO` after resolving so the preload's own fallback and any nested dispatch inherit the same target.

### The observed failure (issue #2207)

A `wtp-org` control session dispatched a classification into `WealthTechPros/sge` with `--repo`. The flag was not in `argument-hint`, not in Usage, and the preload passed no repo to `gh issue view` at all — so the run resolved against the session cwd and classified a same-numbered issue in the wrong repo, with the audit-trail comment posted under the operator's own identity. SPEC-057 already carries a regression scenario for this class (`sgd#656 reproduction`), which makes it a regression rather than new behaviour.

Guarded by [`../../tests/governance-trace-repo-flag.test.sh`](../../tests/governance-trace-repo-flag.test.sh).
