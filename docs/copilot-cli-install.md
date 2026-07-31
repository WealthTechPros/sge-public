# Installing SGD in GitHub Copilot CLI

This plugin was built and is primarily documented for Claude Code, but the
same `.claude-plugin` marketplace format is also read natively by
**GitHub Copilot CLI** (confirmed against Copilot CLI 1.0.76+ — it understands
`/plugin marketplace add`, `/plugin install`, `enabledPlugins`, and
`.claude-plugin/marketplace.json` with no translation layer needed). This
page is the Copilot-CLI-specific companion to the main
[`README.md`](../README.md#1-install-the-sgd-plugin) install instructions —
read that first for *what* the plugin does; this page is about *how the
install mechanics differ* on Copilot CLI, including a real fix for the one
failure mode we've hit repeatedly on locked-down corporate Windows machines.

## Quick install

Exactly the same commands as Claude Code, run inside a Copilot CLI session:

```
/plugin marketplace add WealthTechPros/sgd-public
/plugin install sgd@wtp-plugins
```

(Use `WealthTechPros/sgd` instead of `sgd-public` only if you're WTP staff
with access to the private repo — see the main README's caveat about never
collapsing that to the private ref alone.)

Confirm it worked:

```
/plugin list
```

Or non-interactively, from a shell (useful for scripting/CI or when the
interactive REPL prompt isn't rendering — see below):

```
copilot plugin marketplace add WealthTechPros/sgd-public
copilot plugin install sgd@wtp-plugins
copilot plugin list
```

## How enablement actually works (and where it can silently fail)

Copilot CLI keeps plugin state in two different places, and both need to
agree before skills actually load:

1. **Marketplace *source* registration** — `extraKnownMarketplaces` in either
   the repo's `.claude/settings.json` or your user-level
   `~/.copilot/settings.json`. This is enough on its own to make Copilot CLI
   *fetch and cache* the plugin repo, but **not** enough to make its skills
   discoverable.
2. **Plugin *install* registration** — an `installedPlugins` entry plus an
   `enabledPlugins` map key, which is what actually gates skill loading.
   Copilot CLI auto-attempts step 2 on every session start if a repo's
   `.claude/settings.json` declares `enabledPlugins: {"sgd@wtp-plugins": true}`
   — but if that auto-install fails for any reason, it fails **silently** (a
   one-line warning in the log, nothing in the chat UI), leaving you with a
   fully-cached plugin on disk and zero usable skills. `/skills` and
   `/plugin list` will both look empty even though the marketplace clone is
   sitting right there in
   `%LOCALAPPDATA%\copilot\marketplaces\<org>-<repo>\`.

If you're in that state, running `/plugin install sgd@wtp-plugins` by hand
(per "Quick install" above) re-triggers step 2 and will either fix it or
surface the real error — check `~/.copilot/logs/process-*.log` for a line
like `Failed to auto-install plugin "sgd@wtp-plugins": ...`.

## Known failure mode: "Access is denied. (os error 5)" on managed Windows machines, and the fix that needs no admin rights

On a locked-down corporate Windows laptop (confirmed on a client-managed
device, Copilot CLI 1.0.76), the auto-install step can fail **every single
session** with:

```
Failed to auto-install plugin "sgd@wtp-plugins": Failed to install plugin: Access is denied. (os error 5)
```

This is a genuine Windows `ERROR_ACCESS_DENIED` during the install's
temp-dir → final-dir file move under the default `%USERPROFILE%\.copilot`
(Copilot CLI's `COPILOT_HOME`). The same log will usually also show Copilot
CLI's own self-updater hitting an identical failure class:

```
Failed to update binary: Error: EPERM: operation not permitted, rename 'copilot.exe' -> 'copilot.exe.old'
```

Two independent Copilot CLI subsystems failing the same way (blocked
rename/move) is the signature of **endpoint security software (antivirus /
EDR) real-time-scanning and transiently locking freshly-written files** under
that default path — Copilot CLI doesn't retry past it, so a single lock
window turns into a persistent "no skills" state across every session.

### Fix A — no admin rights needed (confirmed working): relocate `COPILOT_HOME`

Copilot CLI honours a `COPILOT_HOME` environment variable that relocates its
*entire* config/plugin-state directory away from the default
`%USERPROFILE%\.copilot`. Pointing it at a path outside whatever the
AV/EDR is locking (e.g. a folder under your normal working directory tree)
routes the plugin-install file operations around the problem entirely —
confirmed to fix the install on the first try, with **no admin access
required**:

```powershell
# One-time: copy existing state so session history/settings aren't lost
Copy-Item "$env:USERPROFILE\.copilot" "$env:USERPROFILE\copilot-home" -Recurse -Force

# Persist for all future sessions (User-scope env var, no admin needed)
[Environment]::SetEnvironmentVariable("COPILOT_HOME", "$env:USERPROFILE\copilot-home", "User")
```

Open a **new** terminal/VS Code window (env var changes only apply to newly
started processes) and re-run the install — `/plugin install` (interactive)
or `copilot plugin install sgd@wtp-plugins` (non-interactive, see above) —
and verify with `copilot plugin list` / `/skills`.

### Fix B — needs local admin: AV/EDR path exclusion

If you'd rather fix it at the source (or `COPILOT_HOME` relocation isn't
viable for policy reasons), exclude these paths from real-time AV/EDR
scanning:

- `%LOCALAPPDATA%\copilot`
- `C:\ProgramData\GitHubCLI\copilot`

Windows Defender (elevated PowerShell):
```powershell
Add-MpPreference -ExclusionPath "$env:LOCALAPPDATA\copilot"
Add-MpPreference -ExclusionPath "C:\ProgramData\GitHubCLI\copilot"
Add-MpPreference -ExclusionProcess "C:\ProgramData\GitHubCLI\copilot\copilot.exe"
```

If a third-party EDR is also deployed (common in regulated-industry client
networks), the same two paths need excluding there too — `Get-MpPreference`
only reflects Defender's own decision, not a separate managed EDR agent.

If neither fix resolves it, capture `~/.copilot/logs/process-*.log` around
the failing timestamp and open an issue — a plugin install silently failing
every session with no retry/backoff and no user-visible error is a rough
edge worth reporting upstream to the Copilot CLI team too, independent of
SGD.

## Compatibility notes

- Everything **upstream of install** (marketplace fetch, plugin install,
  skill loading, `.claude/settings.json`) is host-agnostic — it works the
  same whether the *consuming* repo lives on GitHub or Azure DevOps.
- Everything **downstream of install** in this plugin bundle is currently
  **GitHub-only**: the `PostToolUse` PR-review hook triggers off `gh pr
  create`, `/sgd:align`'s drift tracking raises GitHub Issues, and CI
  workflows (`ai-supply-chain.yml`, `require-commit-trailer.yml`,
  `require-test-evidence.yml`) are GitHub Actions. If your repo is hosted on
  Azure DevOps, the skills still run locally, but hook-driven automation and
  CI backstops need an Azure DevOps-native equivalent — see the Azure DevOps
  extension work tracked under `platform/azdo-extension/`.
