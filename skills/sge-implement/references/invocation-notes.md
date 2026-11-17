# sge-implement — invocation notes (target repo, orchestrator dispatch, pod-gate mode)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

> **Target repo — cross-repo / control-session invocation.** Apply the shared [`gh-repo`](../../gh-repo/SKILL.md) convention first: this skill acts on the repo in the **current working directory** (issue context, every `gh` call, the Phase 3 worktree). From a non-target directory, resolve + `cd` via `cd "$("$SGE_ROOT/scripts/with-repo-cwd.sh" resolve owner/repo)" || exit 1` (`cd` required — Phase 3 writes in a worktree; a bare `export GH_REPO` is not enough). **`$SGE_ROOT` here is NOT already resolved** — run `bash scripts/resolve-sge-root.sh` (or `"${CLAUDE_PLUGIN_ROOT}/scripts/resolve-sge-root.sh"`, same as the "Issue context" step below) first; never a bare `${CLAUDE_PLUGIN_ROOT}`, empty whenever unset. Same-repo: leave `GH_REPO` unset. Backend routing: [issue-read routing](alm-issue-read-routing.md) — self-hosted Forgejo/Gitea needs `SGE_FORGEJO_HOSTS` declared (ADR-0010) or it fails loud.

> **Orchestrator dispatch — do not duplicate the review.** When dispatched (Tier-0 fan-out, `/sge:team-pipeline`, one-off `Agent()`), this skill's Phase 7 already drives the PR through `/sge:pr-review` — the orchestrator must **not** independently invoke `/sge:pr-review` on the same PR while this skill runs (a second reviewer races its fix commits). Wait for it to report back. Rationale: [`orchestration.md`](orchestration.md).

> **Pod-gate mode (issue #1374).** When `SGE_GATE_OWNER=pod` (dispatch env) or `.claude/sge.json` → `gateOwner: "pod"` is set, an Autopilot pod owns the `pr-reviewed` gate: Phase 6 posts a handoff comment and **Phases 7/8 are skipped entirely** — never race the pod's label mutex. Default: self-drive. Config surface + rationale: [`pod-gate-mode.md`](pod-gate-mode.md).

## Pipeline overview

Pipeline: current issue/readiness checks → fresh governance-trace (0.5) → entry criteria (`/sge:sge-preflight`) → complexity sizing → TDD (`/sge:tdd-workflow`) → verify → forked review (`/sge:sge-review`) → commit + PR (`/sge:commit`) → PR-review + fix loop to `pr-reviewed` + auto-merge → post-merge L6 UPDATE. Each external action retains its normal authority boundary.

## Tool sequencing

Moved verbatim from `SKILL.md` (issues #3515-#3517 and #3522, 24 KB size budget).

| Situation | Tool |
|---|---|
| Check Cortex cache for named entity before reading | `search_nodes` (sge-memory, if available) |
| Populate Cortex after a cache miss | `create_entities` (sge-memory, if available) |
| Read issue body, spec files, CLAUDE.md | Read / Grep / Glob |
| Pick the context depth tier for the change (Phase 2.5, Step A) | Bash via `node "$SGE_ROOT/scripts/resolve-context-depth.mjs"` |
| Resolve which specs/ADRs govern the touched paths (Phase 2.5, `standard` tier) | Bash via `node "$SGE_ROOT/scripts/resolve-context-scope.mjs"` |
| Register a dispatched governance-trace fork handle (Phase 0.5) | Bash via `node "$SGE_ROOT/skills/lib/fork-util.mjs" register` |
| Join a pending fork at the Edit/Write gate (Phase 3, before Step 2) | Bash via `node "$SGE_ROOT/skills/lib/fork-util.mjs" join` |
| Run shell commands, quality suite, git | Bash |
| GitHub API (issues, PRs, labels) | Bash via `gh` |
| Edit existing files | Edit |
| Create new files | Write |
| Spawn forked review, preflight, or the governance-trace gate | Agent (fork) |

> **Dispatch tool: `Agent`, never `Skill(args=)` (#2452).** The governance-trace gate, forked review and preflight rows above mean an `Agent({...})` fork: `Skill` inlines the skill body into this context instead of forking, so its `args` are never received. **Fork result contract (#2452).** For the governance-trace fork only (preflight and review forks return their own result shapes): reject a result with no verdict JSON (a narrative report is not a verdict), a `NO_TARGET_ISSUE` refusal, a missing `issue` echo, or an issue/repo mismatch; treat any of these as blocking. Detail and the call shape: [`orchestration.md`](orchestration.md#dispatch-tool--agent-never-skillargs-issue-2452).
