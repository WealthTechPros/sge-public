# Appendix A — Global-Blast-Radius Carve-Outs

Relocated here from `../SKILL.md` to keep the SKILL body within its size budget (SKILL.md size
budget gate, PR #2388). Nothing here is a new control — same rules the SKILL body carried inline.

> **Canonical definition** — this is the single source of truth for the carve-out
> list. `pr-fix` and `team-pipeline` reference this appendix; do not duplicate or
> diverge from it.

Some PRs have a **global blast radius**: they can break things far outside the
files they directly touch. A risk-based "run only affected tests" strategy is
**unsafe** for these PRs — a passing affected-test run can let a broken change
through.

### When a lane PR matches any carve-out condition — run the full suite

Detect carve-out PRs at lane-assignment time and again before declaring any
carve-out PR green with `is_blast_radius_pr <pr>` from
[`monitor-lib.sh`](../monitor-lib.sh) — it returns 0 (true) when the PR matches
any condition below, echoing a one-word reason string (`lockfile`,
`shared-config`, `ci-workflow`, `codegen-schema`, `container`, `bot-author`)
so callers can log it. The table below is the canonical condition list; the
function implements it — keep them in lockstep.

### Carve-out conditions

| Condition | Glob / pattern |
|-----------|----------------|
| Dependency manifests / lockfiles | `package.json`, `pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`, `.npmrc`, `patches/`, `pyproject.toml`, `poetry.lock`, `uv.lock`, `requirements*.txt`, `requirements/*.txt` (any depth), `setup.py`, `setup.cfg`, `Pipfile`, `Pipfile.lock` |
| Bot author | PR author login matches `*[bot]`, `dependabot*`, or `renovate*` |
| Shared config files | `tsconfig*.json`, `vite.config.*`, `vitest.config.*` |
| CI workflow files | `.github/workflows/*.yml` / `.yaml` |
| Codegen / schema / DB migrations | `*.prisma`, `migrations/` (any depth), `alembic/` + `alembic.ini` (any depth), `codegen.*` |
| Container / image definitions | `Dockerfile*` (any depth), `docker-compose*.yml` / `.yaml` |

### What "run the full suite" means

When `is_blast_radius_pr` returns true for a lane PR:

1. **Do not accept an affected-tests run as proof of green** — a partial run can
   miss failures in code the changed files influence transitively.
2. **Instruct `/sge:pr-fix`** (via the dispatch prompt) that this is a carve-out
   PR — it runs the full build + test suite, not just the failing check.
3. **Gate 3 (CI green)** is satisfied only by a completed **full-suite run**, not
   a partial subset.
4. **Log the carve-out reason** in the heartbeat line:
   ```bash
   carve_out_reason=$(is_blast_radius_pr "$pr") || true   # reason echoed to stdout
   printf '[%s] cycle %s | L%s:#%s BLAST_RADIUS(%s)\n' \
     "$(date -u +%H:%M:%S)" "$CYCLE_NUM" "$lane" "$pr" "$carve_out_reason"
   ```
