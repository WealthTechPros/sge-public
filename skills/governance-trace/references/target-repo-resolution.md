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

A hub control session dispatched a classification into `WealthTechPros/sge` with `--repo`. The flag was not in `argument-hint`, not in Usage, and the preload passed no repo to `gh issue view` at all — so the run resolved against the session cwd and classified a same-numbered issue in the wrong repo, with the audit-trail comment posted under the operator's own identity. SPEC-057 already carries a regression scenario for this class (`sgd#656 reproduction`), which makes it a regression rather than new behaviour.

Guarded by `../../tests/governance-trace-repo-flag.test.sh` (SGE source repo: `skills/tests/governance-trace-repo-flag.test.sh`).

### The fork-of-fork case (issue #2597) — a caller-side gap, not this skill's own resolution

`--repo`/`GH_REPO`/ambient-cwd (above) is this skill's OWN resolution logic, and it is correct — the gap #2597 found sits one level up, in *callers*. The pattern above works cleanly when a fork is dispatched directly from the top-level control session (SPEC-057, #1558): the dispatch prompt names the repo explicitly and the fork `cd`s there as its first action, so by the time this skill's own resolve/assert block runs, the ambient checkout already matches.

It silently breaks one level deeper: a control session in repo A dispatches a subagent that resolves and `cd`s into repo B (its own execution repo), and *that subagent* forks `/sge:governance-trace` again. The second-level fork does not inherit the first subagent's cwd — a fresh `Agent()` call starts a fresh shell back at the control session's own directory (repo A), never the dispatching subagent's (repo B); see [`gh-repo`](../../gh-repo/SKILL.md)'s "Sub-agents don't inherit your cwd". If that subagent's own dispatch prompt names the repo with a bare, unbound placeholder (or lets it default to the issue's tracking repo, which may be repo A) instead of re-threading the *exact* repo/worktree value it itself was given, the nested fork's `--repo` ends up pointing at repo A — and resolves and asserts *successfully*, because repo A is a real, reachable checkout. This is worse than the #2207 failure: there is no `NO_TARGET_ISSUE` refusal to catch it, because nothing about the input looks wrong to this skill's own logic. The defect is entirely in what value the caller put in `--repo`, not in how this skill resolves it.

**The fix is caller-side, every time.** A subagent that forks `/sge:governance-trace` from within its own already-dispatched, already-cross-repo execution must re-thread the *same* repo/worktree value it itself received — never re-derive it from the issue's tracking metadata, and never leave it as a generic template placeholder a model could fill in from the wrong context. See `/sge:team-pipeline`'s impl-lane Step 3 ([`dispatch-prompts.md`](../../team-pipeline/references/dispatch-prompts.md)) for the worked fix: it binds the nested fork's `repo`/`worktree` explicitly to the same `<EXEC_REPO>`/`<EXEC_WT_BASE>` the lane itself was dispatched with, and calls out `<TRACKING_REPO>` by name as the wrong value to reach for.

Guarded by `../../tests/governance-trace-fork-of-fork-repo.test.sh` (SGE source repo: `skills/tests/governance-trace-fork-of-fork-repo.test.sh`).
