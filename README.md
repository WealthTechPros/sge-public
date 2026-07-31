# sgd.framework — WealthTech Pros Claude Code Plugin

Versioned Claude Code plugin providing shared SGD methodology skills and workflow commands across all WTP repos. Install once, available everywhere.

## Repository structure

This repo is the home of **SGD** end-to-end — methodology first, platform second:

- **`skills/`, `agents/`, `commands/`, `.claude-plugin/`** — the SGD methodology Claude Code plugin (what installs into other WTP repos). Unchanged; the plugin is scoped to these and is unaffected by `platform/`.
- **`docs-site/`, `docs/`** — the SGD methodology docs (docs.sgd.wealthtechpros.com).
- **`platform/`** — the **SGD Platform** (the GitHub App + dashboard UI, formerly the standalone `repo-sentry` repo, merged in here with full history and then archived). The app lives under `platform/reposentry/{frontend,backend}`, infra under `platform/infra`, product docs under `platform/docs-site`. CI/CD and the RepoSentry→SGD brand/domain rename land in follow-up steps; `platform/` keeps deploying from its existing pipeline until then.

## Skills

| Skill | Command | Purpose |
|---|---|---|
| `sgd-init` | `/sgd:init` | Interactive onboarding for a new product/repo — interviews the user, then proposes the SGD seed (Vision, capability model, anchor specs with Gherkin, ADR-0001, stakeholder questions) |
| `sgd-implement` | `/sgd:sgd-implement [N]` | End-to-end SGD feature implementation — entry criteria, complexity sizing, TDD, review, PR |
| `sgd-preflight` | `/sgd:sgd-preflight [SGD-NNN]` | Pre-implementation checklist — read spec, check deps, plan files |
| `sgd-review` | `/sgd:sgd-review [SGD-NNN]` | Review implementation against spec — acceptance criteria, degradation, patterns, quality gates |
| `sgd-align` | `/sgd:align [--apply]` | Bidirectional cascade alignment: forward (Vision → Capability → Spec → Tests → Code) raises a GitHub issue per drift gap; reverse reconciles existing open issues against current scope, proposing (and with `--apply`, closing/updating) when scope moves — idempotent, advisory-first, never auto-mutates human issues |
| `atomic-audit` | `/sgd:atomic-audit [path]` | Stack-agnostic atomic-design adoption audit — auto-detect the UI stack (web + mobile/native), score six dimensions (tokens, primitive layer, composition, catalog, testing, enforcement) to an L0–L3 maturity tier, and emit a remediation roadmap. Report-only, advisory |
| `tdd-workflow` | `/sgd:tdd-workflow` | Strict incremental TDD — one failing test, minimum green, refactor, repeat |
| `qa-audit` | `/sgd:qa-audit` | Verify PR against linked issue, post evidence comment |
| `pr-review` | `/sgd:pr-review` | Parallel specialist agent PR review |
| `pr-fix` | `/sgd:pr-fix [pr]` | Drive one PR's CI to green — read failures, reproduce locally, fix root cause (never suppress) |
| `pr-monitor` | `/sgd:pr-monitor` | Watch the 3 oldest non-spec PRs, fix oldest-first, backfill as they merge |
| `deep-dive` | `/sgd:deep-dive <N>` | Investigate an issue in depth — trace to code, weigh options, discuss, record the decision back on the issue (no implementation) |
| `implement-issue` | `/sgd:implement-issue [N]` | Router — non-SGD issues now route into `/sgd:sgd-implement`, which handles both spec and no-spec issues |
| `refactor` | `/sgd:refactor [target]` | Systematic SOLID refactoring with quality gates |
| `tidy-worktrees` | `/sgd:tidy-worktrees [--force]` | **Safe** worktree/branch tidy — audits for uncommitted/unpushed work before removing anything; `--force` = audited fast sweep that executes one confirmed deletion plan |
| `commit` | `/sgd:commit [--no-push]` | Quality-gated commit and push — canonical owner of the SGD trailer convention; `--no-push` for slice commits |
| `sgd-ai-inventory` | `/sgd:sgd-ai-inventory [add\|review\|report]` | FS AI-governance register — machine-readable AI use-case inventory (risk tiering, EU AI Act, Consumer Duty, DORA fields) with vendor due-diligence template. Advisory, propose-only |
| `team-pipeline` | `/sgd:team-pipeline [--agents N] [--module <name>] [--dry-run]` | Parallel multi-agent pipeline — one PR monitor agent + N implementation agents + review agents per PR; continuously works issues from the queue until exhausted |
| `prod-reliability-playbook` | `/sgd:prod-reliability-playbook [note]` | **Why a "simple" fix takes all day** — the five failure modes that turn a one-line fix into a lost day (diagnosis-loop cost, silent fallbacks, prod-only feedback, no fast green path, serial debugging), their preventions, and an incident triage checklist. Advisory, stack-agnostic |
| `drift-hillclimb` | `/sgd:drift-hillclimb [--target N] [--metric C..] [--dry-run]` | **Metric hill-climb loop** — the actor that *raises* the SGD Audit Score (the `/sgd:sgd-align` per-check governance-coherence rollup — distinct from the platform's canonical SM-2 `coherence_score`), not just measures it. Consumes `/sgd:sgd-align`'s scorecard, picks the highest-leverage drift gap, opens ONE bounded PR to close it, re-measures with an independent sweep, repeats until the target is hit or a bound stops it. PR-first, bounded, Governor-gated |
| `issue-loop` | `/sgd:issue-loop [--repo owner/repo] [--max-issues N] [--dry-run]` | **Serial issue-drain loop** (SPEC-065) — works the backlog one issue at a time through the full SGD pipeline (pick via `/sgd:available-issues --mode autonomous-next` → gate → full `/sgd:sgd-implement` as a stoppable sub-agent → `/sgd:pr-review` gate → merge-wait) until the queue is empty. Queue-empty-bounded serial counterpart to `/sgd:issue-swarm`; the only shape that drains `serialGroups`. Thrash-skips (`loop-skip`) and systemic-halts; Governor-gated |

> **Which mode runs my work?** See the **[execution-modes decision matrix](docs/execution-modes.md)** — the canonical map of when to use `sgd-implement`, `team-pipeline`, `available-issues`, `fleet-dispatch`, `pr-monitor`, or Autopilot, with every skill in the plugin accounted for.

> **Commands first, automation later.** The skills above are the supported entry point — run them by hand, one at a time. On-demand pipelines (`team-pipeline`, `issue-swarm`, `pr-monitor`) and always-on **Autopilot** pods are an *optional, opt-in* evolution that runs the very same skills; nothing here is deprecated by them. See **[Autopilot — optional automation stage](docs/autopilot.md)** for the adoption ladder, pipeline diagram, label state machine, and human control points.

## Agents

Bundled, stack-agnostic specialist agents (a repo MAY override any of these with its own `.claude/agents/<name>.md`):

| Agent | Purpose |
|---|---|
| `code-reviewer` | SGD-opinionated code-quality review pass; verifies the change matches its requirements |
| `security-auditor` | OWASP-style application-security audit on sensitive paths |
| `agent-registry` | **Reference, not a runnable agent** — the task-type → lowest-safe Anthropic model tier map (opus / sonnet / haiku / fable). Defines how orchestration routes each agent to the cheapest model safe for its task; CRITICAL paths (security/auth, migrations, multi-tenant) always escalate to opus |

## Hooks

The plugin ships two hooks:

- **`SessionStart` (`hooks/session-start.sh`)** — at the start of a session it surfaces an SGD intro: on the **first session of the day** (or whenever an update is available) a framed box with the installed version/status, live skill+agent counts, and the "start here" commands; on later sessions the same day it falls back to a **one-line** summary. When the published version on `main` is newer than the installed one it nudges `/plugin update sgd` so repos stay on the latest methodology skills (passive nudge by default — a hook can't mutate the version-pinned cache itself; `SGD_AUTO_UPDATE=auto` turns it into a run-now directive). The box throttle is a per-repo date stamp kept in `.git/sgd-intro-state` (never committed); `SGD_INTRO_STATE` and `SGD_TODAY` override the location/date. The version check honours `SGD_REMOTE_VERSION` as an override (non-empty forces the comparison version for pinned/air-gapped installs; empty skips the check). Any failure — no network, no `curl`/`gh`, unreadable `plugin.json` — degrades to a summary-only line or a silent no-op and never blocks session start.
- **`PostToolUse` (`hooks/pr-created.sh`)** — whenever a PR is created via `gh pr create` in a session with the plugin installed, it triggers `/sgd:pr-review` on the new PR so nothing misses the merge gate. Default is an in-session nudge; set `SGD_AUTO_REVIEW=headless` to launch the review as an independent background `claude -p` run instead. PRs opened outside Claude Code still need `/sgd:pr-monitor` or a CI backstop.

## Memory (`sgd-memory` MCP)

The plugin registers one optional MCP server, **`sgd-memory`**, via a `.mcp.json` at the plugin root. It is a lightweight, persistent memory store for SGD skills — now backed by **`sgd-cortex`** (SPEC-052): a WTP-owned, vendored server on Node's built-in `node:sqlite`, shipped as a single committed bundle with no runtime install. It replaced the third-party `mcp-memory-libsql`.

- The store lives in a local SQLite file under the consumer repo's git-ignored `memory/` directory; the server resolves that path via `CLAUDE_PROJECT_DIR` so memory stays **per-repo** (see [`docs/sgd-memory.md`](docs/sgd-memory.md)) — never committed.
- It is **optional and non-blocking**: skills degrade gracefully when it is absent. Skills that use it should always pass an explicit namespace (`sgd:pipeline-state`, `sgd:review-verdicts`, `sgd:decisions`, `sgd:conflict-map`).

See [`docs/sgd-memory.md`](docs/sgd-memory.md) for details. (Wiring individual skills to it is follow-up work.)

## Supply-chain governance (SGD-048)

Two scripts implement the Zero-Trust **Supply-chain** control (see [`docs-site/governance/zero-trust-ai-agents.md`](docs-site/governance/zero-trust-ai-agents.md)):

- **`scripts/generate-ai-bom.sh`** — produces an OWASP CycloneDX ML-BOM (AI Bill of Materials) at `sbom/ai-bom.cdx.json`. It discovers every Anthropic Claude model referenced in `skills/`, `agents/` and `docs-site/` (so the BOM cannot silently drift from the code), plus the `wtp-mcp` Graph API surface and third-party AI tooling. Each component records name, version/model-ID, provider, use-case and the data categories it accesses.
  - `scripts/generate-ai-bom.sh` — (re)write the BOM.
  - `scripts/generate-ai-bom.sh --check` — exit non-zero if the committed BOM is stale (used by CI). Output is deterministic (no timestamp), so `--check` is a pure content comparison.
- **`scripts/check-reachability.sh`** — runs `npm audit --json` and filters advisories down to those that reach **production** paths (intersecting the advisory list with the `npm ls --omit=dev` closure), so dev/test-only advisories don't gate a merge. In a repo with no `package.json` (this plugin), it is a no-op that exits 0. Pass a target dir (`scripts/check-reachability.sh path/to/pkg`) and `--fail-on-reachable` to gate.

Both are wired into CI by **`.github/workflows/ai-supply-chain.yml`**, which fails on a stale AI-BOM and posts a reachability summary comment on each PR. To gate a connected repo's own dependency tree, point the reachability step at that repo's package directory.

## Getting started (new developer)

### 1. Install the SGD plugin

The plugin is published to the WTP private marketplace. Run these commands once per machine inside Claude Code.

**Add the WTP marketplace** (one-time, per machine):
```
/plugin marketplace add WealthTechPros/sgd
```

**Install the plugin** into the current repo:
```
/plugin install sgd
```

After install, the SGD commands (`/sgd:init`, `/sgd:sgd-implement`, etc.) become available in every Claude Code session for that repo.

**Keep it up to date:**
```
/plugin update sgd
```

The `SessionStart` hook will nudge you when a newer version is available.

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

### 3. Enable the commit-msg trailer hook (one-time, per clone)

Every commit in this repo must carry a `Spec: SPEC-NNN`/`SGD-NNN` or `SGD-Override: <STEP>; <reason>` trailer (see `skills/sgd-init/templates/change-protocol.md` — the protocol template this repo authors for every onboarded repo, and, as of this workflow, also dogfoods on itself) — `/sgd:commit` emits this automatically, but a local hook catches commits made outside it too. `core.hooksPath` is a per-clone git config setting, not something a commit can carry — run this once per clone:

```bash
git config core.hooksPath .githooks
```

The hook (`.githooks/commit-msg`) warns on a missing trailer; it does not block. The `require-commit-trailer.yml` CI workflow is the actual enforcement point — it fails the PR check if any commit lacks the trailer, so a locally-skipped warning is still caught before merge.

---

### 4. Test-evidence (TDD) gate

Issue #784's layered TDD process gate, dogfooded on this repo (`.sgd/test-map.yml`, `mode: advisory`):

- **`hooks/tdd-guard.sh`** (in-session, ships with the plugin, no install step) — warns after an Edit/Write on a production-path file with no test evidence recorded this session; set `SGD_ENFORCE=tdd` to make it block instead.
- **`.githooks/commit-msg` / `/sgd:commit`** — a staged implementation-only slice needs an `SGD-Override: TDD; <reason>` trailer to commit (reuses the same trailer convention as above).
- **`require-test-evidence.yml`** — the CI backstop. Fails (once `mode: blocking`) a PR whose diff touches a production path with no test-path change, unless a commit carries the `TDD` override.

All three read `.sgd/test-map.yml` for this repo's production/test/exempt path globs; see that file's header for the schema. `/sgd:sgd-align`'s **C14** check trends the resulting TDD-evidence rate and override count over time.

---

## Update

```
/plugin update sgd
```

## Versioning

Version is set in `.claude-plugin/plugin.json`. Bump it on every breaking change to a skill. Non-breaking additions can share a version increment.

## What stays in each repo's `.claude/commands/`

Only commands that are genuinely specific to that repo — e.g. `docker-dev-start`, `cloudflare-tunnel`, `contract-audit` in `repo-sentry`. The shared methodology lives here.
