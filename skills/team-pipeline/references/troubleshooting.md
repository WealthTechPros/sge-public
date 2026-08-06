# team-pipeline — troubleshooting & global-blast-radius carve-outs

---

## Troubleshooting

**"No issues found"** — Check label filters. Run `gh issue list` directly.

**"Worktree already exists"** — Stale from a previous run:

```bash
git worktree list
git worktree remove .worktrees/issue-<N> --force
gh issue edit <N> --remove-label "agent-lock"
```

For a **cross-repo** lane (SPEC-057 #1024) the stale tree lives under the
**execution** repo's checkout, so run the `worktree list`/`remove` there
(`git -C <exec-repo-checkout> worktree …`); the `agent-lock` label is always
removed from the **tracking** issue.

**"Agent stalled"** — Health monitor recovers automatically. To inspect:

```bash
git -C .worktrees/issue-<N> log --oneline -5
gh pr list --head "${SGE_BRANCH_PREFIX:-fix/issue-}<N>"
```

**"CI gate blocking"** — Too many open PRs. Drain the queue:

```bash
gh pr list --state open --json number | jq length
```

**"PR stuck as DRAFT"** — Check review agent result:

```bash
cat /tmp/team-pipeline-review-<PR>.json
```

---

## Global-Blast-Radius Carve-Outs

> **Carve-out list is defined in one place** — see
> [`skills/pr-monitor/SKILL.md` → Appendix A](../../pr-monitor/SKILL.md#appendix-a--global-blast-radius-carve-outs).
> This section describes what `team-pipeline` must enforce; the authoritative
> condition table and detection helper live in that appendix.

When a lane PR in the pipeline is a **carve-out** (dependency manifests /
lockfiles, shared config, CI workflows, codegen / schema / migrations, or a
bot-authored PR such as Dependabot / Renovate), it has a global blast radius —
partial or affected-only test runs are not sufficient evidence of green.

**A carve-out PR must never be considered green until the full build + test
suite has passed on CI.** Concretely, for the pipeline this means:

1. **PR monitor agent** — the `pr-monitor` agent running in Phase 2 must detect
   carve-out PRs at lane-assignment time (using `is_blast_radius_pr` from
   Appendix A) and dispatch `/sge:pr-fix` with a note that the full suite must
   be run. Gate 3 (CI green) for a carve-out lane is only satisfied by a
   full-suite run, not a partial one.

2. **Health monitor (Phase 4)** — when reading a completion file
   (`/tmp/team-pipeline-agent-<N>.json`) for a carve-out PR, check that
   `carve_out: true` appears in the associated `pr-fix-report`. If it is absent,
   do **not** treat the PR as green — re-dispatch `/sge:pr-fix` and note the
   requirement.

3. **Review agent (Phase 3d)** — carve-out PRs carry higher risk. The review
   agent must note the carve-out in its review comment so the human reader knows
   full-suite verification was required and performed.

4. **CI capacity gate (Phase 3b)** — carve-out PRs count normally against
   `CI_LIMIT`; no special treatment is needed there.

This rule applies even when a partial CI run shows all *currently required*
checks as passing — a blast-radius PR may break checks that a risk-based CI
skipped entirely.
