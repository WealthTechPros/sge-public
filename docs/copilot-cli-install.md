# Installing SGE in GitHub Copilot CLI

This plugin was built and is primarily documented for Claude Code, but the
same `.claude-plugin` marketplace format is also read natively by
**GitHub Copilot CLI** (confirmed against Copilot CLI 1.0.76+ — it understands
`/plugin marketplace add`, `/plugin install`, `enabledPlugins`, and
`.claude-plugin/marketplace.json` with no translation layer needed). This
page is the Copilot-CLI-specific companion to the main
[`README.md`](../README.md#1-install-the-sge-plugin) install instructions —
read that first for *what* the plugin does; this page is about *how the
install mechanics differ* on Copilot CLI, including a real fix for the one
failure mode we've hit repeatedly on locked-down corporate Windows machines.

## Quick install

Exactly the same commands as Claude Code, run inside a Copilot CLI session:

```
/plugin marketplace add WealthTechPros/sge-public
/plugin install sge@wtp-plugins
```

(Use `WealthTechPros/sge` instead of `sge-public` only if you're WTP staff
with access to the private repo — see the main README's caveat about never
collapsing that to the private ref alone.)

Confirm it worked:

```
/plugin list
```

Or non-interactively, from a shell (useful for scripting/CI or when the
interactive REPL prompt isn't rendering — see below):

```
copilot plugin marketplace add WealthTechPros/sge-public
copilot plugin install sge@wtp-plugins
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
   `.claude/settings.json` declares `enabledPlugins: {"sge@wtp-plugins": true}`
   — but if that auto-install fails for any reason, it fails **silently** (a
   one-line warning in the log, nothing in the chat UI), leaving you with a
   fully-cached plugin on disk and zero usable skills. `/skills` and
   `/plugin list` will both look empty even though the marketplace clone is
   sitting right there in
   `%LOCALAPPDATA%\copilot\marketplaces\<org>-<repo>\`.

If you're in that state, running `/plugin install sge@wtp-plugins` by hand
(per "Quick install" above) re-triggers step 2 and will either fix it or
surface the real error — check `~/.copilot/logs/process-*.log` for a line
like `Failed to auto-install plugin "sge@wtp-plugins": ...`.

## Known failure mode: "Access is denied. (os error 5)" on managed Windows machines, and the fix that needs no admin rights

On a locked-down corporate Windows laptop (confirmed on a client-managed
device, Copilot CLI 1.0.76), the auto-install step can fail **every single
session** with:

```
Failed to auto-install plugin "sge@wtp-plugins": Failed to install plugin: Access is denied. (os error 5)
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
or `copilot plugin install sge@wtp-plugins` (non-interactive, see above) —
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
SGE.

## Hooks on Windows: "Denied by preToolUse hook from sge (hook errored)"

Every SGE hook runs through `hooks/run-hook.cmd`, a launcher that finds a real Git Bash itself instead of trusting `bash` on PATH (sge#3264). Before it, a PATH whose first `bash` was `C:\Windows\System32\bash.exe` (the WSL launcher) or the WindowsApps stub made every hook exit 1, and the fail-closed PreToolUse hook then denied every edit and PowerShell call. The launcher skips those launchers and needs Git for Windows installed. If no working bash is found it still fails closed (exit 2), with stderr naming the hook script, what it tried and the remedy. Hooks stay on; a hook that cannot run is never treated as a pass.

## Worktree lifecycle hooks (SPEC-139, best-effort)

`hooks/copilot/worktree-lifecycle.sh` is a Copilot CLI adapter for the
worktree-preservation family (epic #3216, SPEC-139 — an internal spec, not
published here).
It is **best-effort and never destructive**: it registers the session's linked
worktree in the shared ownership registry, records a heartbeat and the end of
the session, calls the checkpoint hook point (`skills/lib/checkpoint.sh`, when
the #3234 slice provides it), and at the next *new* session start tells the
agent which owned worktrees earlier sessions left open, each with its shared
audit verdict. It never deletes, stashes, resets, commits, pushes, unregisters
or opens a PR, never releases another session's claim, and never writes prompt
text, file contents or secrets to its state or logs. Nothing it prints means
"backed up" or "safe to remove".

### Install (user-level hook file)

Copilot CLI loads one hook source per plugin, and the plugin's
`hooks/hooks.json` is the Claude PascalCase file, so the camelCase Copilot
definition is installed as a separate hook source (Copilot combines sources):

```
bash <plugin>/hooks/copilot/install-worktree-lifecycle-hooks.sh        # -> ~/.copilot/hooks/sge-worktree-lifecycle.json
bash <plugin>/hooks/copilot/install-worktree-lifecycle-hooks.sh --uninstall
```

The file embeds this plugin copy's absolute path: re-run the installer after a
plugin update moves the install directory. `--dest <dir>` writes it elsewhere
(for example `<repo>/.github/hooks`). Installing it from more than one source
is safe: duplicate events are deduplicated per session.

### Observed behaviour (Copilot CLI 1.0.105, Windows, headless `-p` runs)

| Situation | Observed |
|-----------|----------|
| Startup | `sessionStart` fires with `source: "new"`; payload is camelCase (`sessionId`, `cwd`, `initialPrompt`). Flat `{"additionalContext": "..."}` stdout reaches the model; `hookSpecificOutput` and plain stdout did not. |
| Resume (`--resume`) | `sessionStart` fires again with `source: "resume"` and the same `sessionId`. The adapter prints no handoff. |
| Normal completion | `agentStop` at the end of each turn (with `stopReason`, `stop_hook_active`), then `sessionEnd` with `reason: "complete"`. `-p` and piped runs fire `sessionEnd` once per completed turn. |
| Hook timeout | A hook over its `timeoutSec` is killed and Copilot logs "timed out; allowing processing to proceed". The other hooks and the session continue. |
| Forced termination | Killing the Copilot process mid-turn fires neither `agentStop` nor `sessionEnd`. The registry entry and heartbeat survive, and the next start reports the session as "interrupted: no clean end recorded" once its heartbeat is older than `SGE_LIFECYCLE_STALE_SECS` (default 1800). |
| Duplicate sources | Two hook files for the same event both run. The adapter does the work once (per-session lock and a 10 s dedupe window): one registry entry, one checkpoint call, one handoff. |
| Interactive exit and `/clear` | **Not observed.** Headless runs cannot drive them. Per the Copilot CLI changelog `/clear` runs `sessionEnd` hooks, in the background, and `sessionEnd` output is not processed; the adapter does not rely on either. |

### Known gaps (reported, not hidden)

- Without `skills/lib/checkpoint.sh` nothing is copied: the state records
  `checkpoint=unavailable` and the handoff says so. Even with it, the adapter
  records only the exit status, never coverage.
- A later session that merely reuses a worktree registered to an earlier
  session does not take ownership (a foreign claim is never overwritten), so
  its interruption is not reported under its own id; the worktree is still
  listed and audited under the owner.
- Liveness is a heartbeat heuristic. A single turn longer than
  `SGE_LIFECYCLE_STALE_SECS` can look interrupted, and a killed session looks
  active until the window passes.
- The handoff audit calls the open-PR lookup, which needs network and `gh`
  auth. On any failure the verdict is `KEEP` with the reason, never "no PRs".
- The Claude Code adapters are out of scope for this slice. The adapter
  already accepts the Claude/VS Code-style payload (`session_id`,
  `SessionStart`/`Stop`/`SessionEnd`), so wiring it from `hooks/hooks.json`
  later needs no code change there.
- The installed definition runs `bash` from PATH, not the `run-hook.cmd`
  launcher (which passes only a script path, while this adapter needs the event
  name). On a PATH whose first `bash` is the WSL launcher the hook errors and
  does nothing; Copilot continues, and no preservation or handoff happens.

## Memory (sge-memory) under Copilot CLI

Copilot CLI does not set Claude Code's `CLAUDE_PROJECT_DIR`, so the
`sge-memory` server keys its database on the git `origin` of the directory
Copilot CLI launched it from — start `copilot` from inside the repository
checkout. The DB lives at `~/.claude/sge-memory/<org>/<repo>.db`, one per
repository, and stays local.

- Confirm which DB a session uses: the server logs
  `[sge-cortex] local memory DB: <path> (resolved via <tier>)` to stderr at
  startup (visible in `~/.copilot/logs/`). No memory content is logged.
- Launched outside a git checkout with an `origin` remote, the server refuses
  to start rather than share one DB across repos. Set
  `CORTEX_TARGET_REPO=<org>/<repo>` (or `LIBSQL_URL=file:<path>`) in the MCP
  server's `env` to pin it explicitly.
- Earlier builds could write a shared `C:\memory\sge-memory.db`.
  See [`sge-memory.md`](sge-memory.md#authoritative-database-location)
  for how to import and retire it.

## Token metering under Copilot CLI

The plugin's token-metering hook reads a Claude Code session transcript;
it is not validated on Copilot CLI. If no usage sidecar is written,
`/sge:cost-guard` and `/sge:roi-report` report *metering unavailable*, not
zero usage. Use Copilot's own usage
reporting instead. See [`token-metering.md`](token-metering.md) for the
details and for how to measure Cortex savings.

## Deploying where Anthropic models are not permitted

Copilot CLI is the usual SGE surface in organisations that exclude
Anthropic/Claude models from their network and data. The component scope that
makes that work (see
[`external-install.md`](external-install.md#deploying-where-anthropic-models-are-not-permitted)
for the full statement):

- **Client-side, model-agnostic:** the plugin payload (skills/agents/hooks —
  prose + helper scripts with no model access of their own; they run on
  whatever model your Copilot CLI is configured to use) and the `sge-memory`
  server (local Node + SQLite, no model calls, no network egress). WTP's
  skill portability audit (July 2026; available to clients on request) found
  no functional hard-coded model IDs in any skill prompt body.
- **WTP-internal only, never deployed to clients:** the review daemon
  (PR Warden), which embeds the Claude Code CLI
  (`@anthropic-ai/claude-code`) in its container image and **must not be
  deployed** in a no-Anthropic environment; plus WTP's CI workflows and docs
  site.

**Disable Anthropic models in Copilot policy** so "no Anthropic" is enforced
rather than assumed — the Copilot model picker can otherwise offer Claude
models to your engineers. An organization owner sets this on GitHub.com under
**Organization settings → Copilot → Models** (each model beyond the base
models, including the Anthropic Claude family, has its own availability
policy); in an enterprise, policies are set at the enterprise level first
(the enterprise **AI controls** tab) and an enterprise-set policy cannot be
overridden by an organization. Also set the policy governing *unconfigured*
generally-available models so newly released Anthropic models do not default
to enabled. Verified against GitHub's documentation on 2026-10-30:
[Managing policies for Copilot in your organization](https://docs.github.com/en/copilot/how-tos/administer-copilot/manage-for-organization/manage-policies)
and [GitHub Copilot policies](https://docs.github.com/en/copilot/concepts/policies).

## Compatibility notes

- Everything **upstream of install** (marketplace fetch, plugin install,
  skill loading, `.claude/settings.json`) is host-agnostic — it works the
  same whether the *consuming* repo lives on GitHub or Azure DevOps.
- Everything **downstream of install** in this plugin bundle is currently
  **GitHub-only**: the `PostToolUse` PR-review hook triggers off `gh pr
  create`, `/sge:sge-align`'s drift tracking raises GitHub Issues, and CI
  workflows (`ai-supply-chain.yml`, `require-commit-trailer.yml`,
  `require-test-evidence.yml`) are GitHub Actions. If your repo is hosted on
  Azure DevOps, the skills still run locally, but hook-driven automation and
  CI backstops need an Azure DevOps-native equivalent — see the Azure DevOps
  host adapter (`services/review-daemon-poc/azdo_adapter.py`,
  `skills/lib/azdo-gh-pr.sh`) and the customer-hosted rollout runbook
  (`docs/governance/sge-azdo-customer-hosted-rollout-runbook.md`, WTP-internal —
  not part of this public doc set).
