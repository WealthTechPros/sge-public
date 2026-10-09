# sge.framework — WealthTech Pros Claude Code Plugin

Versioned Claude Code plugin providing shared SGE methodology skills and workflow commands across every spec-governed repo. Install once, available everywhere.

## Repository structure

This repo is the home of **SGE**: the docs, the skills and plugin, and the MCP server. There is no hosted SGE service.

- **`skills/`, `agents/`, `commands/`, `hooks/`, `.claude-plugin/`** — the SGE methodology Claude Code plugin (what installs into other repos).
- **`mcp/sge-cortex/`** — the `sge-memory` MCP server that ships with the plugin.
- **`docs-site/`, `docs/`** — the SGE methodology docs. Governance artefacts (vision, capability model, skills map, legacy `SGD-NNN` specs) live in `docs/sgd-build/`; newer `SPEC-NNN` specs in `docs/specs/`. The published docs site, `docs.sge.wealthtechpros.com`, is org-private (WealthTech Pros org members only); if you do not have access, read the same content as Markdown sources in this repo.
- **`packages/`** — npm packages the skills use: `sge-checks`, `sge-dashboard`, `sge-init`, `coverage-collector`, `mutation-collector`.
- **`services/review-daemon-poc/`** — the long-running `/sge:pr-review` daemon (PR Warden).

**The hosted SGE platform was decommissioned on 2026-10-04 (#2899).** Its code (the GitHub App backend, dashboard UI, Azure DevOps extension, Docker images, the self-hosted compose stack, the cortex broker and `@wealthtechpros/cortex-mcp`) was removed from `main`; the last commit that has it is tagged **`platform-final`**. The Azure resources were destroyed the same day and the `reposentry-infra` Pulumi stacks removed, so `platform/infra` and `pulumi-deploy.yml` are gone too.

### Naming: `sgd` → `sge` — what renames and what doesn't

The product/methodology was renamed `sgd` → `sge` (#2017, #2021, #2201). Brand
prose and user-facing slash commands rename; code-level and historical
identifiers deliberately do not. When touching a stale `sgd` reference,
check it against this list before renaming:

- **Renames:** brand prose ("SGD" → "SGE" in docs/marketing copy), and any
  `/sgd:<command>` slash-command reference (the namespace is `/sge:` now).
  As of #2319, this also includes the `sgd-init` npx package name — now
  `@wealthtechpros/sge-init` (renamed 2026-08-26; the package had never been
  published, so this was a clean rename, not a deprecation-shim migration).
- **Stays `sgd`/`SGD` — do not rename:**
  - `SGD-NNN` spec IDs — historical identifiers, permanently retained (the
    forward-going convention mints `SGE-NNN` from here on; both forms are
    accepted by commit-trailer parsing).
  - The `SGD_AGENT_ID` environment variable.
  - `docs/sgd/` directory paths in seeded repos (the *scaffolder's* generated
    workflow filenames inside that directory tree were renamed to `sge-*`,
    but the `docs/sgd/` directory name itself and `docs/sgd-build/`,
    `SGD_BUILD.md` stay `sgd`-named).
  - Dated references to historical events (e.g. "SGD realignment",
    "SGD-seeded") describing things that happened under the old name.

See #2208 for the rename-surfaces pass that established this list, and #2319
for the constant/package rename that superseded the `sgd-init` entry above.

## Skills

| Skill | Command | Purpose |
|---|---|---|
| `sge-init` | `/sge:sge-init` | Interactive onboarding for a new product/repo — interviews the user, then proposes the SGE seed (Vision, capability model, anchor specs with Gherkin, ADR-0001, stakeholder questions) |
| `sge-implement` | `/sge:sge-implement [N] [--unattended] [--sentry <ID>]` | End-to-end implementation of any issue (spec or no-spec) — intake gate, in-flight PR check, entry criteria, complexity sizing, TDD, review, PR. `--sentry` adds production-bug context; `--unattended` never stops to ask |
| `sge-preflight` | `/sge:sge-preflight [SGD-NNN]` | Pre-implementation checklist — read spec, check deps, plan files |
| `sge-review` | `/sge:sge-review [SGD-NNN]` | Review implementation against spec — acceptance criteria, degradation, patterns, quality gates |
| `sge-align` | `/sge:sge-align [--apply]` | Bidirectional cascade alignment: forward (Vision → Capability → Spec → Tests → Code) raises a GitHub issue per drift gap; reverse reconciles existing open issues against current scope, proposing (and with `--apply`, closing/updating) when scope moves — idempotent, advisory-first, never auto-mutates human issues |
| `atomic-audit` | `/sge:atomic-audit [path]` | Stack-agnostic atomic-design adoption audit — auto-detect the UI stack (web + mobile/native), score six dimensions (tokens, primitive layer, composition, catalog, testing, enforcement) to an L0–L3 maturity tier, and emit a remediation roadmap. Report-only, advisory |
| `tdd-workflow` | `/sge:tdd-workflow` | Strict incremental TDD — one failing test, minimum green, refactor, repeat |
| `qa-audit` | `/sge:qa-audit` | Verify PR against linked issue, post evidence comment |
| `pr-review` | `/sge:pr-review` | Parallel specialist agent PR review |
| `pr-fix` | `/sge:pr-fix [pr]` | Drive one PR's CI to green — read failures, reproduce locally, fix root cause (never suppress) |
| `pr-monitor` | `/sge:pr-monitor` | Watch the 3 oldest non-spec PRs, fix oldest-first, backfill as they merge |
| `deep-dive` | `/sge:deep-dive <N>` | Investigate an issue in depth — trace to code, weigh options, discuss, record the decision back on the issue (no implementation) |
| `refactor` | `/sge:refactor [target]` | Systematic SOLID refactoring with quality gates |
| `tidy-worktrees` | `/sge:tidy-worktrees [--force]` | **Safe** worktree/branch tidy — audits for uncommitted/unpushed work before removing anything; `--force` = audited fast sweep that executes one confirmed deletion plan |
| `clean-root` | `/sge:clean-root [--dry-run] [path]` | Untracked-file hygiene — removes only files provably identical to `main`'s tracked version, or matching a repo-configured throwaway-pattern allowlist; everything else is reported, never deleted. Not for worktrees (`tidy-worktrees`) or processes (`reap-orphans`) |
| `commit` | `/sge:commit [--no-push]` | Quality-gated commit and push — canonical owner of the SGE trailer convention; `--no-push` for slice commits |
| `sge-ai-inventory` | `/sge:sge-ai-inventory [add\|review\|report]` | FS AI-governance register — machine-readable AI use-case inventory (risk tiering, EU AI Act, Consumer Duty, DORA fields) with vendor due-diligence template. Advisory, propose-only |
| `team-pipeline` | `/sge:team-pipeline [--agents N] [--module <name>] [--dry-run]` | Parallel multi-agent pipeline — one PR monitor agent + N implementation agents + review agents per PR; continuously works issues from the queue until exhausted |
| `prod-reliability-playbook` | `/sge:prod-reliability-playbook [note]` | **Why a "simple" fix takes all day** — the five failure modes that turn a one-line fix into a lost day (diagnosis-loop cost, silent fallbacks, prod-only feedback, no fast green path, serial debugging), their preventions, and an incident triage checklist. Advisory, stack-agnostic |
| `drift-hillclimb` | `/sge:drift-hillclimb [--target N] [--metric C..] [--auto-dimension] [--dry-run]` | **Metric hill-climb loop** — the actor that *raises* the SGE Audit Score (the `/sge:sge-align` per-check governance-coherence rollup, which is SM-2 since ADR-0018), not just measures it. Consumes `/sge:sge-align`'s scorecard, picks the highest-leverage drift gap, opens ONE bounded PR to close it, re-measures with an independent sweep, repeats until the target is hit or a bound stops it. PR-first, bounded, Governor-gated. `--auto-dimension --max-rounds 1` is the weekly sweep: it picks the worst of three dials and runs one round |
| `issue-loop` | `/sge:issue-loop [--repo owner/repo] [--max-issues N] [--dry-run]` | **Serial issue-drain loop** (SPEC-065) — works the backlog one issue at a time through the full SGE pipeline (pick via `/sge:available-issues --mode autonomous-next` → gate → full `/sge:sge-implement` as a stoppable sub-agent → `/sge:pr-review` gate → merge-wait) until the queue is empty. Queue-empty-bounded serial counterpart to `/sge:team-pipeline --duration`; the only shape that drains `serialGroups`. Thrash-skips (`loop-skip`) and systemic-halts; Governor-gated |

> This table is a subset. The authoritative list of skills is the `skills/` directory (or the plugin's skill listing).

> **Which mode runs my work?** `sge-implement` is the entry point for one issue; `team-pipeline`, `available-issues`, `fleet-dispatch`, `pr-monitor` and Autopilot build on it to work several issues at once. Each skill's `SKILL.md` says when to use it. In the source repo, the full decision matrix, with every skill in the plugin accounted for, is `docs/execution-modes.md` (it is not part of the public distribution).

> **Commands first, automation later.** The skills above are the supported entry point — run them by hand, one at a time. On-demand pipelines (`team-pipeline`, `pr-monitor`) and always-on **Autopilot** pods are an *optional, opt-in* evolution that runs the very same skills; nothing here is deprecated by them.

## Agents

Bundled, stack-agnostic specialist agents (a repo MAY override any of these with its own `.claude/agents/<name>.md`):

| Agent | Purpose |
|---|---|
| `code-reviewer` | SGE-opinionated code-quality review pass; verifies the change matches its requirements |
| `security-auditor` | OWASP-style application-security audit on sensitive paths |

The model-routing map (task type → lowest-safe Anthropic model tier) is a reference doc, not an agent: [`docs/agent-registry.md`](docs/agent-registry.md).

## Hooks

The full plugin distribution ships the hooks below. The **public** distribution (`sge-public`) ships only the token-metering hook.

- **`Stop` / `SubagentStop` (`hooks/token-meter.sh`)** — appends one local `TokenUsageRecord` per assistant turn to the consumer repo's git-ignored `memory/token-usage.jsonl`, which `/sge:cost-guard` and `/sge:roi-report` read. Local-only, no network. It reads a Claude Code session transcript and is not validated on GitHub Copilot CLI. Where no usage sidecar is written, the skills report *metering unavailable*, never zero usage. See [`docs/token-metering.md`](docs/token-metering.md), including what counts as evidence of Cortex savings.

- **`SessionStart` (`hooks/session-start.sh`)** — at the start of a session it surfaces an SGE intro: on the **first session of the day** (or whenever an update is available) a framed box with the installed version/status, live skill+agent counts, and the "start here" commands; on later sessions the same day it falls back to a **one-line** summary. When the published version on `main` is newer than the installed one it nudges `/plugin update sge` so repos stay on the latest methodology skills (passive nudge by default — a hook can't mutate the version-pinned cache itself; `SGE_AUTO_UPDATE=auto` turns it into a run-now directive). The box throttle is a per-repo date stamp kept in `.git/sge-intro-state` (never committed); `SGE_INTRO_STATE` and `SGE_TODAY` override the location/date. The version check honours `SGE_REMOTE_VERSION` as an override (non-empty forces the comparison version for pinned/air-gapped installs; empty skips the check). Any failure — no network, no `curl`/`gh`, unreadable `plugin.json` — degrades to a summary-only line or a silent no-op and never blocks session start.
- **`PostToolUse` (`hooks/pr-created.sh`)** — whenever a PR is created via `gh pr create` in a session with the plugin installed, it triggers `/sge:pr-review` on the new PR so nothing misses the merge gate. Default is an in-session nudge; set `SGE_AUTO_REVIEW=headless` to launch the review as an independent background `claude -p` run instead. PRs opened outside Claude Code still need `/sge:pr-monitor` or a CI backstop.

## Memory (`sge-memory` MCP)

The plugin registers one optional MCP server, **`sge-memory`**, via a `.mcp.json` at the plugin root. It is a lightweight, persistent memory store for SGE skills — now backed by **`sge-cortex`** (SPEC-052): a WTP-owned, vendored server on Node's built-in `node:sqlite`, shipped as a single committed bundle with no runtime install. It replaced the third-party `mcp-memory-libsql`.

- The store is a local SQLite file keyed on the consumer repo's identity (its git `origin`), kept outside the working tree under `~/.claude/sge-memory/`, so memory stays **per-repo** and is never committed (see [`docs/sge-memory.md`](docs/sge-memory.md)).
- It is **optional and non-blocking**: skills degrade gracefully when it is absent. Skills that use it should always pass an explicit namespace (`sge:pipeline-state`, `sge:review-verdicts`, `sge:decisions`, `sge:conflict-map`).

See [`docs/sge-memory.md`](docs/sge-memory.md) for details. (Wiring individual skills to it is follow-up work.)

## Supply-chain governance (SGD-048)

Two scripts implement the Zero-Trust **Supply-chain** control:

- **`scripts/generate-ai-bom.sh`** — produces an OWASP CycloneDX ML-BOM (AI Bill of Materials) at `sbom/ai-bom.cdx.json`. It discovers every Anthropic Claude model referenced in `skills/`, `agents/` and `docs-site/` (so the BOM cannot silently drift from the code), plus the MCP Graph API surface and third-party AI tooling. Each component records name, version/model-ID, provider, use-case and the data categories it accesses.
  - `scripts/generate-ai-bom.sh` — (re)write the BOM.
  - `scripts/generate-ai-bom.sh --check` — exit non-zero if the committed BOM is stale (used by CI). Output is deterministic (no timestamp), so `--check` is a pure content comparison.
- **`scripts/check-reachability.sh`** — runs `npm audit --json` and filters advisories down to those that reach **production** paths (intersecting the advisory list with the `npm ls --omit=dev` closure), so dev/test-only advisories don't gate a merge. In a repo with no `package.json` (this plugin), it is a no-op that exits 0. Pass a target dir (`scripts/check-reachability.sh path/to/pkg`) and `--fail-on-reachable` to gate.

Both are wired into CI by **`.github/workflows/ai-supply-chain.yml`**, which fails on a stale AI-BOM and posts a reachability summary comment on each PR. To gate a connected repo's own dependency tree, point the reachability step at that repo's package directory.

## Getting started (new developer)

### 1. Install the SGE plugin

Run these commands once per machine inside Claude Code.

**Add the WTP marketplace** (one-time, per machine). Which source you use depends on whether you can clone this private repo:

```
# External / client repos — the public redacted distribution:
/plugin marketplace add WealthTechPros/sge-public

# WTP staff with access to this private repo (tracks main directly):
/plugin marketplace add WealthTechPros/sge
```

> **This README is copied verbatim into `WealthTechPros/sge-public`** by `.github/workflows/publish-public.yml` (no rewrite step), so anyone reading it there is an external adopter who **cannot** clone `WealthTechPros/sge`. Keep the public source listed first, and never reduce this block to the private ref alone — that is what made the public install instructions unusable (#1713).

**Install the plugin** (one-time, per machine):
```
/plugin install sge
```

On Claude Code CLI this installs at **user scope**, not per repo: the SGE commands (`/sge:sge-init`, `/sge:sge-implement`, etc.) become available in every Claude Code session on your machine, whatever project you are working in. There is nothing to repeat per project and nothing to commit to a repo to make it work. On GitHub Copilot CLI the same command works, but skill loading can additionally be gated per repository — see [`docs/copilot-cli-install.md`](docs/copilot-cli-install.md).

**Keep it up to date:**
```
/plugin update sge
```

The `SessionStart` hook will nudge you when a newer version is available.

> **Using GitHub Copilot CLI instead of Claude Code?** The commands above
> work identically — Copilot CLI reads the same `.claude-plugin` marketplace
> format natively. See [`docs/copilot-cli-install.md`](docs/copilot-cli-install.md)
> for Copilot-CLI-specific install mechanics and a known Windows AV/EDR
> failure mode (`Access is denied. (os error 5)`) and two working fixes,
> including one that needs no admin rights.

> **Installing SGE at an organisation outside WTP?** [`docs/external-install.md`](docs/external-install.md) is the standalone install guide for external adopters — install, supported surfaces, updates, licence, and support — and is the canonical statement of install scope.

---

### 2. Secrets

SGE never hard-codes credentials: every skill and script reads tokens from the
environment, injected by whatever secrets manager your organisation uses. Name
it once in `.claude/sge.json` (`"secretsStore": "<name>"`) so skills can refer
to it; the keys are documented in [`docs/sge-json-config.md`](docs/sge-json-config.md).
CI reads the same tokens from repository or organisation secrets.

---

### 3. Enable the repo's git hooks (one-time, per clone)

`core.hooksPath` is a per-clone git config setting, not something a commit can carry — run this once per clone:

```bash
git config core.hooksPath .githooks
# or: ./scripts/install-git-hooks.sh   (bash)  /  ./scripts/install-git-hooks.ps1  (PowerShell)
```

That wires both tracked hooks:

- **`commit-msg`** — every commit in this repo must carry a `Spec: SPEC-NNN`/`SGD-NNN`/`SGE-NNN` or `SGD-Override`/`SGE-Override: <STEP>; <reason>` trailer (see `skills/sge-init/templates/change-protocol.md` — the protocol template this repo authors for every onboarded repo, and, as of this workflow, also dogfoods on itself). `/sge:commit` emits this automatically, but the hook catches commits made outside it too. It warns; it does not block. The `require-commit-trailer.yml` CI workflow is the actual enforcement point — it fails the PR check if any commit lacks the trailer, so a locally-skipped warning is still caught before merge.
- **`prepare-commit-msg`** — appends an `Agent-Id: claude-code/<session>` trailer to **agent-authored** commits, so Zero-Trust control ZT-5 / C11 is verifiable from git history. No-op for human commits. **Agent sessions working in this repo must enable the hook** so their commits carry the trailer.

`agent-id-hook-check.yml` verifies the Agent-Id hook is vendored and tracked executable; it cannot see your local `core.hooksPath`, so the step above is still required per clone.

---

### 4. Test-evidence (TDD) gate

Issue #784's layered TDD process gate, dogfooded on this repo (`.sge/test-map.yml`, `mode: advisory`):

- **`hooks/tdd-guard.sh`** (in-session, ships with the plugin, no install step) — warns after an Edit/Write on a production-path file with no test evidence recorded this session; set `SGE_ENFORCE=tdd` (or a comma list such as `SGE_ENFORCE=tdd,lint`) to make it block instead. A repo whose `.sge/posture.yaml` declares `enforcement: enforced` (SPEC-128) makes it block for everyone.
- **`.githooks/commit-msg` / `/sge:commit`** — a staged implementation-only slice needs an `SGD-Override`/`SGE-Override: TDD; <reason>` trailer to commit (reuses the same trailer convention as above).
- **`require-test-evidence.yml`** — the CI backstop. Fails (once `mode: blocking`) a PR whose diff touches a production path with no test-path change, unless a commit carries the `TDD` override.

All three read `.sge/test-map.yml` for this repo's production/test/exempt path globs; see that file's header for the schema. `/sge:sge-align`'s **C14** check trends the resulting TDD-evidence rate and override count over time.

---

## Update

```
/plugin update sge
```

## Versioning

Version is set in `.claude-plugin/plugin.json`. Contributors do not bump it per PR: after shipped plugin content lands on `main`, `.github/workflows/plugin-release-bump.yml` opens one rolling PR that bumps the patch (sge#2844). Bump minor/major by hand, in `plugin.json` and `marketplace.json` together, for a new skill or a breaking change.

## What stays in each repo's `.claude/commands/`

Only commands that are genuinely specific to that repo — e.g. `docker-dev-start`, `cloudflare-tunnel`, `contract-audit` in `repo-sentry`. The shared methodology lives here.
