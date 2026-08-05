# Installing SGE in your organisation

This page is for an engineer at an organisation that has been given access to
**SGE** — WealthTech Pros' AI code-governance plugin — and needs to get it
running locally. It assumes no prior knowledge of SGE or of WealthTech Pros.
Read it end to end before your first install; it is short.

SGE ships as a **plugin** for AI coding agents. Installing it adds a set of
governance commands (`/sge:init`, `/sge:sgd-implement`, and others) to your
agent sessions. There is no server to run, no account to create, and nothing
to configure in your CI — the plugin is fetched from a public GitHub
repository and cached on your machine.

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
