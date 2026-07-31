# Installing SGD in GitHub Copilot CLI

This plugin was built and is primarily documented for Claude Code, but the
same `.claude-plugin` marketplace format is also read natively by
**GitHub Copilot CLI** (confirmed against Copilot CLI 1.0.76+ — it understands
`/plugin marketplace add`, `/plugin install`, `enabledPlugins`, and
`.claude-plugin/marketplace.json` with no translation layer needed). This
page is the Copilot-CLI-specific companion to the main
[`README.md`](../README.md#1-install-the-sgd-plugin) install instructions —
read that first for *what* the plugin does; this page is about *how the
install mechanics differ* on Copilot CLI, and how to unblock the one failure
mode we've hit repeatedly on locked-down corporate Windows machines.

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
surface the real error.

## Known failure mode: "Access is denied. (os error 5)" on managed Windows machines

On a locked-down corporate Windows laptop (confirmed on a Multrees-managed
device, Copilot CLI 1.0.76), the auto-install step can fail every single
session with:

```
Failed to auto-install plugin "sgd@wtp-plugins": Failed to install plugin: Access is denied. (os error 5)
```

This is a genuine Windows `ERROR_ACCESS_DENIED` during the install's
temp-dir → final-dir file move under `%LOCALAPPDATA%\copilot`, not an SGD or
marketplace-config problem. The same log will usually also show Copilot
CLI's own self-updater hitting an identical failure class:

```
Failed to update binary: Error: EPERM: operation not permitted, rename 'copilot.exe' -> 'copilot.exe.old'
```

Two independent Copilot CLI subsystems failing the same way (blocked
rename/move) is the signature of **endpoint security software (antivirus /
EDR) real-time-scanning and transiently locking freshly-written files** —
Copilot CLI doesn't retry past that, so a single lock-window turns into a
persistent "no skills" state across every session until the lock stops
recurring or the path is excluded.

**Fix (needs local admin / IT):**

1. Exclude these paths from real-time AV/EDR scanning:
   - `%LOCALAPPDATA%\copilot`
   - `C:\ProgramData\GitHubCLI\copilot`
2. If you manage Windows Defender yourself (elevated PowerShell):
   ```powershell
   Add-MpPreference -ExclusionPath "$env:LOCALAPPDATA\copilot"
   Add-MpPreference -ExclusionPath "C:\ProgramData\GitHubCLI\copilot"
   ```
   If a third-party EDR is also deployed (common in regulated-industry
   client networks), the same two paths need excluding there too — check
   with IT/security, since `Get-MpComputerStatus` alone won't show a
   non-Microsoft product's decision.
3. Re-run `/plugin install sgd@wtp-plugins` (or just start a new session —
   the auto-install will retry) and confirm with `/plugin list` /
   `/skills list`.

If the exclusion doesn't resolve it, capture
`~/.copilot/logs/process-*.log` around the failing timestamp and open an
issue — this is worth reporting upstream to the Copilot CLI team too, since
a plugin install silently failing every session with no retry/backoff and no
user-visible error is a rough edge independent of SGD.

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
  CI backstops need an Azure DevOps-native equivalent (tracked separately).
