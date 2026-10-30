# Installing SGE in your organisation

This page is for an engineer at an organisation that has been given access to
**SGE** — WealthTech Pros' AI code-governance plugin — and needs to get it
running locally. It assumes no prior knowledge of SGE or of WealthTech Pros.
Read it end to end before your first install; it is short.

SGE ships as a **plugin** for AI coding agents. Installing it adds a set of
governance commands (`/sge:sge-init`, `/sge:sge-implement`, and others) to your
agent sessions. There is no server to run, no account to create, and nothing
to configure in your CI — the plugin is fetched from a public GitHub
repository and cached on your machine.

## Prerequisites

Before installing you need:

- **An AI coding agent** — either [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
  or [GitHub Copilot CLI](https://docs.github.com/en/copilot/github-copilot-in-the-cli).
  No other agent is supported.
- **Git** — installed and on your `PATH`. The plugin marketplace uses `git clone`
  under the hood.
- **GitHub connectivity** — your machine must be able to reach
  `github.com/WealthTechPros/sge-public` over HTTPS. No GitHub account is
  required (the repository is public), but a network that blocks GitHub will
  block the install.
- **A subscription** — SGE is commercial software licensed to subscribing
  organisations. The repository being publicly readable does not grant a
  licence (see [Licence](#licence) below).

No server, no database, no API keys, no CI configuration. The plugin is
fetched once and cached locally.

## Install

Two commands, run once per machine, inside an agent session:

```
/plugin marketplace add WealthTechPros/sge-public
/plugin install sge
```

The first command registers the **marketplace** — the source SGE is
distributed from. The second installs the plugin itself. On **Claude Code
CLI** both apply at user scope on your machine, not to one project: once
installed, the SGE commands are available in every agent session you open,
whatever you happen to be working on. You do not need to repeat the install
per project, and there is nothing to commit to any of your own repositories
to make it work. On **GitHub Copilot CLI** the same two commands work, but
skill loading can additionally be gated per repository (an `enabledPlugins`
entry in a repo's `.claude/settings.json`) — see
[`copilot-cli-install.md`](copilot-cli-install.md) before assuming a one-off
machine-wide install there.

Confirm the install worked:

```
/plugin list
```

You should see `sge` listed. If you don't, see
[When something goes wrong](#when-something-goes-wrong) below.

> `WealthTechPros/sge-public` is the correct source for every organisation
> outside WealthTech Pros. If you find instructions elsewhere pointing at a
> different WealthTechPros repository, that is the internal source and you
> will not have access to it — use `sge-public`.

## Supported surfaces

SGE is supported on two command-line agents:

**Claude Code CLI** — the primary target. SGE is built and documented against
it, and everything on this page works as written with no extra steps.

**GitHub Copilot CLI** — also supported. Copilot CLI reads the same plugin
marketplace format natively, so the two install commands above are identical
there. The install *mechanics* differ in a few places, and there is one
failure mode we have hit repeatedly on locked-down corporate Windows machines
(`Access is denied. (os error 5)` during plugin install, which fails silently
and leaves you with zero usable commands). If you are on Copilot CLI, read
[`copilot-cli-install.md`](copilot-cli-install.md) — it covers the
Copilot-specific install path and two working fixes for that failure, one of
which needs no administrator rights.

Other agents and IDE integrations are not supported. The plugin may load in
them, but nothing about its behaviour there is tested or guaranteed.

### Which skills work in an external repo

The plugin ships ~50 skills. The large majority are **standalone** — they
compose via `git`, `gh`, and local file I/O only, and work in any repo
regardless of who owns it. A small cluster is scoped to WealthTech Pros'
regulated financial-services context and will not produce useful output
outside it.

| Category | Skills | Notes |
|----------|--------|-------|
| **Standalone** | `sge-init`, `sge-implement`, `sge-review`, `sge-preflight`, `sge-align` (base checks), `commit`, `pr-review`, `pr-fix`, `pr-monitor`, `tdd-workflow`, `refactor`, `decompose-issue`, `available-issues`, `team-pipeline`, `issue-loop`, `build-ready-audit`, `governance-trace`, `deep-dive`, `qa-audit`, `sge-dashboard`, `traceability`, `cost-guard`, `roi-report`, `drift-hillclimb`, `spec-validate`, `onboard`, `sge-adoption-diagnostic`, `sge-skill-audit`, `fleet-dispatch`, `dora-setup`, `atomic-audit`, `optimisation-loop`, `prod-reliability-playbook`, `tidy-worktrees`, `env-health`, `reap-orphans`, `review-daemon`, `exit-report`, `run-report`, `worktrees` | Work in any GitHub-hosted repo. No WTP infrastructure assumed. For the full list see the `skills/` directory in the distribution. |
| **WTP-internal** | `regulatory-trace`, `sge-ai-inventory`, `sge-align --dimension regulatory`, `sge-align --dimension agent-security` | Require WTP's regulated financial-services infrastructure — specific compliance artefacts and regulatory registers that are not distributed with the plugin. Present in the distribution but not useful outside a WTP-governed engagement. |

If a skill you try to run asks for something your organisation does not
have — a specific repo, an API endpoint, a compliance artefact — that is
the signal it is in the WTP-internal cluster. Nothing will break; the
skill will simply not produce the output it describes.

## Getting updates

SGE is developed continuously and published on a **rolling** basis: changes
are released to the public distribution repository as they are ready, rather
than on a fixed version cadence. There is no release calendar to track and no
migration step between updates.

Your machine does **not** update itself. You pick up new versions when you
refresh the marketplace and update the plugin:

```
/plugin update sge
```

If your agent supports it, a session-start notice will tell you when a newer
version is available. If updating appears to do nothing, re-run
`/plugin marketplace add WealthTechPros/sge-public` to refresh the marketplace
listing first, then update again.

We recommend updating at the start of a working week rather than mid-task —
governance commands can change behaviour between versions, and you want that
change to land between pieces of work, not inside one.

### Version pinning

When version tags are available on `WealthTechPros/sge-public`, you can pin
your install to a specific release rather than tracking `main`:

```
/plugin marketplace add WealthTechPros/sge-public@vX.Y.Z
```

Replace `X.Y.Z` with the version tag you want to pin to — see the tags on
`WealthTechPros/sge-public`.

**The trade-off is real.** A pinned ref does **not** auto-update. That is
the point — stability — but it has a cost: pinned installs have previously
caused silent downgrades (an older pin overwriting a newer local cache) and
broken headless skill dispatches (a skill calling a sub-skill that changed
signature between the pinned version and the version another tool expects).
Both failure modes are silent — nothing errors, the output is just wrong.

If you pin:

- **Record** which version you pinned to and why.
- **Review the changelog** before unpinning or moving the pin forward —
  governance skills can change behaviour between versions.
- **Do not mix pinned and unpinned installs** across machines in the same
  team. A team where half the engineers are on `v4.30.x` and half are on
  `main` will get different governance verdicts on the same code, which
  defeats the point of a shared methodology.

If you do not pin, you track `main` and get whatever is current when you
run `/plugin update sge`. This is the recommended default for most teams.

## Vendor independence and data custody

For client-facing architecture positioning on model-provider independence and
retained usage custody, see:

- [`vendor-independence-and-data-custody.md`](vendor-independence-and-data-custody.md)

## Deploying where Anthropic models are not permitted

Some organisations exclude Anthropic/Claude models from their network and
their data entirely. SGE supports that deployment: the parts of SGE that run
on your machines call no model of their own, and the one SGE component that
does embed Anthropic tooling never leaves WealthTech Pros' infrastructure.

**What runs client-side (and is model-agnostic):**

- **The plugin payload** — skills, agents and hooks. These are prose
  instructions plus shell/Node helper scripts. They contain no model access of
  their own and execute inside whichever agent CLI your organisation licenses
  (e.g. GitHub Copilot CLI), using whatever model that CLI is configured to
  use. WTP's skill portability audit (July 2026; available to clients on
  request) verified there are **no functional hard-coded model IDs** in any
  skill prompt body — the skills "prefer Anthropic, function on any model".
- **The memory server (`sge-memory` / sge-cortex)** — a local Node process
  over a local SQLite file. It makes no model calls and has no network
  egress.

**What is WTP-internal only (never deployed to clients):**

- **The review daemon (PR Warden)** — depends on the Claude Agent SDK and
  bakes the Claude Code CLI (`@anthropic-ai/claude-code`) into its container
  image. **It must not be deployed in an environment where Anthropic models
  are not permitted**, and it is not part of the client distribution in any
  environment: it runs only on WealthTech Pros infrastructure.
- **CI workflows and the documentation site** — WTP-internal tooling, not
  part of what you install.

**Make "no Anthropic" a policy, not a convention.** If your engineers use
GitHub Copilot, the Copilot model picker can offer Anthropic Claude models
unless an administrator disables them. We recommend your GitHub administrator
disables the Anthropic model policies: on GitHub.com, an organization owner
sets this under **Organization settings → Copilot → Models**, where each
model beyond the base models (including the Anthropic Claude family) has its
own availability policy; in an enterprise, Copilot policies are set at the
enterprise level first (the enterprise **AI controls** tab) and an
enterprise-set policy cannot be overridden at organization level. Also check
the policy that controls whether *unconfigured* generally-available models
default to enabled, so newly released Anthropic models do not appear
automatically. Verified against GitHub's documentation on 2026-10-30:
[Managing policies for Copilot in your organization](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-for-organization/manage-policies)
and [GitHub Copilot policies](https://docs.github.com/en/copilot/concepts/policies)
— the exact UI labels move occasionally, so confirm against those pages when
you apply the setting.

## Supply-chain assurance: skill security scanning

Everything the plugin distributes to your machines — the skills, the agent
definitions, the hooks, and the shipped MCP configuration — is statically
scanned for the vulnerability classes that matter in LLM-executed artefacts
(prompt-injection vectors, data-exfiltration patterns, dangerous inline code)
by **two independent scanners** before any change can merge:

- **NVIDIA SkillSpector** — run static-only over every skill and the shipped
  `.mcp.json`.
- **Cisco AI Defense Skill Scanner** — a second, independent static leg over
  the skills (including a cross-skill overlap/relay analysis) plus the agent
  and hook payloads.

Both run as **blocking CI gates** on every pull request that touches the
plugin payload: a critical- or high-severity finding fails the check, naming
the file and the finding, unless it carries an explicit, dated, authored
waiver in an audited registry — the gate is never disabled to pass a finding,
and a scan that fails to produce a report fails the check rather than letting
an unscanned change through. Both scanners are version-pinned and run only
their local static analyzers: no code from your repositories, and no scanned
content, is sent to any external service by the scanning pipeline.

This does not make the plugin "verified safe" — no static scanner can promise
that — but it does mean every distributed change has passed two independent,
fail-closed static gates with an auditable waiver trail.

## Licence

SGE is commercial software. Use is governed by the licence file published
alongside the distribution — see `LICENSE.md` in the root of
`WealthTechPros/sge-public`.

In short: **SGE is licensed to subscribing organisations only.** Your
organisation's subscription covers your use of it. The repository being
publicly readable on GitHub does not place the software in the public domain
and does not grant a licence to anyone who has not subscribed. If you are
unsure whether a particular use — a subsidiary, a contractor, a client
engagement — is covered, ask before proceeding rather than after. The licence
file is authoritative; this paragraph is a summary and does not override it.

## When something goes wrong

Before reporting a problem, two checks resolve most issues:

1. **Re-run the install command.** `/plugin install sge` is safe to run
   repeatedly. If the initial install failed silently — which is the common
   case on managed corporate machines — running it by hand surfaces the real
   error rather than leaving you with an empty command list.
2. **Confirm which agent and version you are on.** The Copilot CLI failure
   mode described above accounts for most "the commands just aren't there"
   reports on Windows.

If that doesn't fix it, raise an issue on the public distribution repository:

**https://github.com/WealthTechPros/sge-public/issues**

Please include:

- which agent you are using (Claude Code CLI or Copilot CLI) and its version;
- your operating system;
- the exact commands you ran and the output you got;
- whether `/plugin list` shows `sge`.

Do not paste source code, file contents, credentials, or anything else
confidential to your organisation into a public issue — the repository is
world-readable. A description of the failure and the command output is enough
to diagnose almost everything. If a problem genuinely cannot be described
without sharing confidential material, say so in the issue and we will move
the conversation to your organisation's usual support channel.
