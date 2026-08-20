# sge.framework — WealthTech Pros Claude Code Plugin

Versioned Claude Code plugin providing shared SGE methodology skills and workflow commands across all WTP repos. Install once, available everywhere.

## Repository structure

This repo is the home of **SGE** end-to-end — methodology first, platform second:

- **`skills/`, `agents/`, `commands/`, `.claude-plugin/`** — the SGE methodology Claude Code plugin (what installs into other WTP repos). Unchanged; the plugin is scoped to these and is unaffected by `platform/`.
- **`docs-site/`, `docs/`** — the SGE methodology docs (docs.sge.wealthtechpros.com).
- **`platform/`** — the **SGE Platform** (the GitHub App + dashboard UI, formerly the standalone `repo-sentry` repo, merged in here with full history and then archived). The app lives under `platform/reposentry/{frontend,backend}`, infra under `platform/infra`, product docs under `platform/docs-site`. CI/CD and the RepoSentry→SGE brand/domain rename land in follow-up steps; `platform/` keeps deploying from its existing pipeline until then.

### Naming: `sgd` → `sge` — what renames and what doesn't

The product/methodology was renamed `sgd` → `sge` (#2017, #2021, #2201). Brand
prose and user-facing slash commands rename; code-level and historical
identifiers deliberately do not. When touching a stale `sgd` reference,
check it against this list before renaming:

- **Renames:** brand prose ("SGD" → "SGE" in docs/marketing copy), and any
  `/sgd:<command>` slash-command reference (the namespace is `/sge:` now).
- **Stays `sgd`/`SGD` — do not rename:**
  - `SGD-NNN` spec IDs — historical identifiers, permanently retained (the
    forward-going convention mints `SGE-NNN` from here on; both forms are
    accepted by commit-trailer parsing).
  - The `SGD_AGENT_ID` environment variable.
  - `docs/sgd/` directory paths in seeded repos.
  - The `sgd-init` npx package name (`npx @wealthtechpros/sgd-init`).
  - Dated references to historical events (e.g. "SGD realignment",
    "SGD-seeded") describing things that happened under the old name.

See #2208 for the rename-surfaces pass that established this list.

## Skills

| Skill | Command | Purpose |
|---|---|---|
| `sge-init` | `/sge:init` | Interactive onboarding for a new product/repo — interviews the user, then proposes the SGE seed (Vision, capability model, anchor specs with Gherkin, ADR-0001, stakeholder questions) |
| `sge-implement` | `/sge:sge-implement [N]` | End-to-end SGE feature implementation — entry criteria, complexity sizing, TDD, review, PR |
| `sge-preflight` | `/sge:sge-preflight [SGD-NNN]` | Pre-implementation checklist — read spec, check deps, plan files |
| `sge-review` | `/sge:sge-review [SGD-NNN]` | Review implementation against spec — acceptance criteria, degradation, patterns, quality gates |
| `sge-align` | `/sge:align [--apply]` | Bidirectional cascade alignment: forward (Vision → Capability → Spec → Tests → Code) raises a GitHub issue per drift gap; reverse reconciles existing open issues against current scope, proposing (and with `--apply`, closing/updating) when scope moves — idempotent, advisory-first, never auto-mutates human issues |
| `atomic-audit` | `/sge:atomic-audit [path]` | Stack-agnostic atomic-design adoption audit — auto-detect the UI stack (web + mobile/native), score six dimensions (tokens, primitive layer, composition, catalog, testing, enforcement) to an L0–L3 maturity tier, and emit a remediation roadmap. Report-only, advisory |
| `tdd-workflow` | `/sge:tdd-workflow` | Strict incremental TDD — one failing test, minimum green, refactor, repeat |
| `qa-audit` | `/sge:qa-audit` | Verify PR against linked issue, post evidence comment |
| `pr-review` | `/sge:pr-review` | Parallel specialist agent PR review |
| `pr-fix` | `/sge:pr-fix [pr]` | Drive one PR's CI to green — read failures, reproduce locally, fix root cause (never suppress) |
| `pr-monitor` | `/sge:pr-monitor` | Watch the 3 oldest non-spec PRs, fix oldest-first, backfill as they merge |
| `deep-dive` | `/sge:deep-dive <N>` | Investigate an issue in depth — trace to code, weigh options, discuss, record the decision back on the issue (no implementation) |
| `implement-issue` | `/sge:implement-issue [N]` | Router — non-SGE issues now route into `/sge:sge-implement`, which handles both spec and no-spec issues |
| `refactor` | `/sge:refactor [target]` | Systematic SOLID refactoring with quality gates |
| `tidy-worktrees` | `/sge:tidy-worktrees [--force]` | **Safe** worktree/branch tidy — audits for uncommitted/unpushed work before removing anything; `--force` = audited fast sweep that executes one confirmed deletion plan |
| `commit` | `/sge:commit [--no-push]` | Quality-gated commit and push — canonical owner of the SGE trailer convention; `--no-push` for slice commits |
| `sge-ai-inventory` | `/sge:sge-ai-inventory [add\|review\|report]` | FS AI-governance register — machine-readable AI use-case inventory (risk tiering, EU AI Act, Consumer Duty, DORA fields) with vendor due-diligence template. Advisory, propose-only |
| `team-pipeline` | `/sge:team-pipeline [--agents N] [--module <name>] [--dry-run]` | Parallel multi-agent pipeline — one PR monitor agent + N implementation agents + review agents per PR; continuously works issues from the queue until exhausted |
| `prod-reliability-playbook` | `/sge:prod-reliability-playbook [note]` | **Why a "simple" fix takes all day** — the five failure modes that turn a one-line fix into a lost day (diagnosis-loop cost, silent fallbacks, prod-only feedback, no fast green path, serial debugging), their preventions, and an incident triage checklist. Advisory, stack-agnostic |
| `drift-hillclimb` | `/sge:drift-hillclimb [--target N] [--metric C..] [--dry-run]` | **Metric hill-climb loop** — the actor that *raises* the SGE Audit Score (the `/sge:sge-align` per-check governance-coherence rollup — distinct from the platform's canonical SM-2 `coherence_score`), not just measures it. Consumes `/sge:sge-align`'s scorecard, picks the highest-leverage drift gap, opens ONE bounded PR to close it, re-measures with an independent sweep, repeats until the target is hit or a bound stops it. PR-first, bounded, Governor-gated |
| `issue-loop` | `/sge:issue-loop [--repo owner/repo] [--max-issues N] [--dry-run]` | **Serial issue-drain loop** (SPEC-065) — works the backlog one issue at a time through the full SGE pipeline (pick via `/sge:available-issues --mode autonomous-next` → gate → full `/sge:sge-implement` as a stoppable sub-agent → `/sge:pr-review` gate → merge-wait) until the queue is empty. Queue-empty-bounded serial counterpart to `/sge:issue-swarm`; the only shape that drains `serialGroups`. Thrash-skips (`loop-skip`) and systemic-halts; Governor-gated |

> **Which mode runs my work?** See the **[execution-modes decision matrix](docs/execution-modes.md)** — the canonical map of when to use `sge-implement`, `team-pipeline`, `available-issues`, `fleet-dispatch`, `pr-monitor`, or Autopilot, with every skill in the plugin accounted for.

> **Commands first, automation later.** The skills above are the supported entry point — run them by hand, one at a time. On-demand pipelines (`team-pipeline`, `issue-swarm`, `pr-monitor`) and always-on **Autopilot** pods are an *optional, opt-in* evolution that runs the very same skills; nothing here is deprecated by them. See **[Autopilot — optional automation stage](docs/autopilot.md)** for the adoption ladder, pipeline diagram, label state machine, and human control points.

## Agents

Bundled, stack-agnostic specialist agents (a repo MAY override any of these with its own `.claude/agents/<name>.md`):

| Agent | Purpose |
|---|---|
| `code-reviewer` | SGE-opinionated code-quality review pass; verifies the change matches its requirements |
| `security-auditor` | OWASP-style application-security audit on sensitive paths |
| `agent-registry` | **Reference, not a runnable agent** — the task-type → lowest-safe Anthropic model tier map (opus / sonnet / haiku / fable). Defines how orchestration routes each agent to the cheapest model safe for its task; CRITICAL paths (security/auth, migrations, multi-tenant) always escalate to opus |

## Hooks

The plugin ships two hooks:

- **`SessionStart` (`hooks/session-start.sh`)** — at the start of a session it surfaces an SGE intro: on the **first session of the day** (or whenever an update is available) a framed box with the installed version/status, live skill+agent counts, and the "start here" commands; on later sessions the same day it falls back to a **one-line** summary. When the published version on `main` is newer than the installed one it nudges `/plugin update sge` so repos stay on the latest methodology skills (passive nudge by default — a hook can't mutate the version-pinned cache itself; `SGE_AUTO_UPDATE=auto` turns it into a run-now directive). The box throttle is a per-repo date stamp kept in `.git/sge-intro-state` (never committed); `SGE_INTRO_STATE` and `SGE_TODAY` override the location/date. The version check honours `SGE_REMOTE_VERSION` as an override (non-empty forces the comparison version for pinned/air-gapped installs; empty skips the check). Any failure — no network, no `curl`/`gh`, unreadable `plugin.json` — degrades to a summary-only line or a silent no-op and never blocks session start.
- **`PostToolUse` (`hooks/pr-created.sh`)** — whenever a PR is created via `gh pr create` in a session with the plugin installed, it triggers `/sge:pr-review` on the new PR so nothing misses the merge gate. Default is an in-session nudge; set `SGE_AUTO_REVIEW=headless` to launch the review as an independent background `claude -p` run instead. PRs opened outside Claude Code still need `/sge:pr-monitor` or a CI backstop.

## Memory (`sge-memory` MCP)

The plugin registers one optional MCP server, **`sge-memory`**, via a `.mcp.json` at the plugin root. It is a lightweight, persistent memory store for SGE skills — now backed by **`sge-cortex`** (SPEC-052): a WTP-owned, vendored server on Node's built-in `node:sqlite`, shipped as a single committed bundle with no runtime install. It replaced the third-party `mcp-memory-libsql`.

- The store lives in a local SQLite file under the consumer repo's git-ignored `memory/` directory; the server resolves that path via `CLAUDE_PROJECT_DIR` so memory stays **per-repo** (see [`docs/sge-memory.md`](docs/sge-memory.md)) — never committed.
- It is **optional and non-blocking**: skills degrade gracefully when it is absent. Skills that use it should always pass an explicit namespace (`sge:pipeline-state`, `sge:review-verdicts`, `sge:decisions`, `sge:conflict-map`).

See [`docs/sge-memory.md`](docs/sge-memory.md) for details. (Wiring individual skills to it is follow-up work.)

## Supply-chain governance (SGD-048)

Two scripts implement the Zero-Trust **Supply-chain** control (see [`docs-site/governance/zero-trust-ai-agents.md`](docs-site/governance/zero-trust-ai-agents.md)):

- **`scripts/generate-ai-bom.sh`** — produces an OWASP CycloneDX ML-BOM (AI Bill of Materials) at `sbom/ai-bom.cdx.json`. It discovers every Anthropic Claude model referenced in `skills/`, `agents/` and `docs-site/` (so the BOM cannot silently drift from the code), plus the `wtp-mcp` Graph API surface and third-party AI tooling. Each component records name, version/model-ID, provider, use-case and the data categories it accesses.
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

On Claude Code CLI this installs at **user scope**, not per repo: the SGE commands (`/sge:init`, `/sge:sge-implement`, etc.) become available in every Claude Code session on your machine, whatever project you are working in. There is nothing to repeat per project and nothing to commit to a repo to make it work. On GitHub Copilot CLI the same command works, but skill loading can additionally be gated per repository — see [`docs/copilot-cli-install.md`](docs/copilot-cli-install.md).

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

### 2. Install and configure Doppler

WTP uses [Doppler](https://doppler.com) as the secrets manager for all staging and production secrets. CI uses a service token; local development uses your personal Doppler account.

#### Install the Doppler CLI

**macOS (Homebrew):**
```bash
brew install dopplerhq/cli/doppler
```

**Linux / WSL / GitHub Actions:**
```bash
curl -sLf --retry 3 --tlsv1.2 --proto "=https" 'https://cli.doppler.com/install.sh' | sudo sh
```

**Windows (Scoop):**
```powershell
scoop bucket add doppler https://github.com/DopplerHQ/scoop-doppler.git
scoop install doppler
```

Verify: `doppler --version`

#### Authenticate (local development)

```bash
doppler login
```

This opens a browser to authorise your account. You need to be invited to the WTP Doppler workspace first — ask Dave or Rob.

#### Select the project and environment

```bash
# For iExploreIt staging
doppler setup --project iexploreit --config stg
```

Once set up, prefix any command with `doppler run --` to inject secrets:
```bash
doppler run -- npm run start:dev
doppler run -- npx wrangler deploy --env staging
```

#### CI / CD (GitHub Actions)

CI uses a **Doppler service token** stored as a GitHub secret (`DOPPLER_TOKEN_STAGING`). The deploy workflow installs the CLI and uses the token automatically — no browser auth required. To rotate the token: Doppler dashboard → Project → Service Tokens → generate new → update the GitHub secret.

---

### 3. Enable the repo's git hooks (one-time, per clone)

`core.hooksPath` is a per-clone git config setting, not something a commit can carry — run this once per clone:

```bash
git config core.hooksPath .githooks
# or: ./scripts/install-git-hooks.sh   (bash)  /  ./scripts/install-git-hooks.ps1  (PowerShell)
```

That wires both tracked hooks (see [`.githooks/README.md`](.githooks/README.md)):

- **`commit-msg`** — every commit in this repo must carry a `Spec: SPEC-NNN`/`SGD-NNN`/`SGE-NNN` or `SGD-Override`/`SGE-Override: <STEP>; <reason>` trailer (see `skills/sge-init/templates/change-protocol.md` — the protocol template this repo authors for every onboarded repo, and, as of this workflow, also dogfoods on itself). `/sge:commit` emits this automatically, but the hook catches commits made outside it too. It warns; it does not block. The `require-commit-trailer.yml` CI workflow is the actual enforcement point — it fails the PR check if any commit lacks the trailer, so a locally-skipped warning is still caught before merge.
- **`prepare-commit-msg`** — appends an `Agent-Id: claude-code/<session>` trailer to **agent-authored** commits, so Zero-Trust control ZT-5 / C11 (wtp-org#373) is verifiable from git history. No-op for human commits. **Agent sessions working in this repo must enable the hook** so their commits carry the trailer.

`agent-id-hook-check.yml` verifies the Agent-Id hook is vendored and tracked executable; it cannot see your local `core.hooksPath`, so the step above is still required per clone.

---

### 4. Test-evidence (TDD) gate

Issue #784's layered TDD process gate, dogfooded on this repo (`.sge/test-map.yml`, `mode: advisory`):

- **`hooks/tdd-guard.sh`** (in-session, ships with the plugin, no install step) — warns after an Edit/Write on a production-path file with no test evidence recorded this session; set `SGE_ENFORCE=tdd` to make it block instead.
- **`.githooks/commit-msg` / `/sge:commit`** — a staged implementation-only slice needs an `SGD-Override`/`SGE-Override: TDD; <reason>` trailer to commit (reuses the same trailer convention as above).
- **`require-test-evidence.yml`** — the CI backstop. Fails (once `mode: blocking`) a PR whose diff touches a production path with no test-path change, unless a commit carries the `TDD` override.

All three read `.sge/test-map.yml` for this repo's production/test/exempt path globs; see that file's header for the schema. `/sge:sge-align`'s **C14** check trends the resulting TDD-evidence rate and override count over time.

---

## Update

```
/plugin update sge
```

## Versioning

Version is set in `.claude-plugin/plugin.json`. Bump it on every breaking change to a skill. Non-breaking additions can share a version increment.

## What stays in each repo's `.claude/commands/`

Only commands that are genuinely specific to that repo — e.g. `docker-dev-start`, `cloudflare-tunnel`, `contract-audit` in `repo-sentry`. The shared methodology lives here.
