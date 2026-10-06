# sge-implement — invocation notes (target repo, orchestrator dispatch, pod-gate mode)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

> **Target repo — cross-repo / control-session invocation.** Apply the shared [`gh-repo`](../../gh-repo/SKILL.md) convention first: this skill acts on the repo in the **current working directory** (issue context, every `gh` call, the Phase 3 worktree). From a non-target directory, resolve + `cd` via `cd "$("$SGE_ROOT/scripts/with-repo-cwd.sh" resolve owner/repo)" || exit 1` (`cd` required — Phase 3 writes in a worktree; a bare `export GH_REPO` is not enough). **`$SGE_ROOT` here is NOT already resolved** — run `bash scripts/resolve-sge-root.sh` (or `"${CLAUDE_PLUGIN_ROOT}/scripts/resolve-sge-root.sh"`, same as the "Issue context" step below) first; never a bare `${CLAUDE_PLUGIN_ROOT}`, empty whenever unset. Same-repo: leave `GH_REPO` unset. Backend routing: [issue-read routing](alm-issue-read-routing.md) — self-hosted Forgejo/Gitea needs `SGE_FORGEJO_HOSTS` declared (ADR-0010) or it fails loud.

> **Orchestrator dispatch — do not duplicate the review.** When dispatched (Tier-0 fan-out, `/sge:team-pipeline`, one-off `Agent()`), this skill's Phase 7 already drives the PR through `/sge:pr-review` — the orchestrator must **not** independently invoke `/sge:pr-review` on the same PR while this skill runs (a second reviewer races its fix commits). Wait for it to report back. Rationale: [`orchestration.md`](orchestration.md).

> **Pod-gate mode (issue #1374).** When `SGE_GATE_OWNER=pod` (dispatch env) or `.claude/sge.json` → `gateOwner: "pod"` is set, an Autopilot pod owns the `pr-reviewed` gate: Phase 6 posts a handoff comment and **Phases 7/8 are skipped entirely** — never race the pod's label mutex. Default: self-drive. Config surface + rationale: [`pod-gate-mode.md`](pod-gate-mode.md).

## Pipeline overview

Pipeline: intake gate (−1) → governance-trace (0.5) → entry criteria (`/sge:sge-preflight`) → complexity sizing → TDD (`/sge:tdd-workflow`) → verify → forked review (`/sge:sge-review`) → commit + PR (`/sge:commit`) → PR-review + fix loop to `pr-reviewed` + auto-merge → post-merge L6 UPDATE.
