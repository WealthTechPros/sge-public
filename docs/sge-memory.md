# sge-memory — lightweight persistent memory MCP

`sge-memory` is a small, optional MCP server the SGE plugin registers so SGE
skills have a **lightweight persistent memory** across sessions — without
pulling in a heavy orchestration framework.

It is backed by **`sge-cortex`**, a vendored MCP server that ships inside the
plugin and replaced the third-party `mcp-memory-libsql`. It stores an
entity/observation/relation graph in a local SQLite file via Node's built-in
`node:sqlite` (zero third-party storage dependency, no native binary, no
runtime install). No service to host, no database to provision.

> Registered MCP name stays **`sge-memory`** so existing `mcp__sge-memory__*`
> tool calls are unaffected; `sge-cortex` is the internal package name.

## Why it exists

SGE skills benefit from a small, searchable store of notes that survives
across sessions. `sge-memory` provides exactly that and nothing more: no
orchestration framework, no hosted service.

## How it's registered

The plugin ships a `.mcp.json` at its root declaring a single stdio server that
runs the **vendored bundle** — no `npx`, no runtime fetch:

```json
{
  "mcpServers": {
    "sge-memory": {
      "type": "stdio",
      "command": "node",
      "args": ["${CLAUDE_PLUGIN_ROOT}/mcp/sge-cortex/dist/sge-cortex.bundle.mjs"]
    }
  }
}
```

- `dist/sge-cortex.bundle.mjs` is a committed, single-file esbuild bundle. It
  has **zero runtime `node_modules`** (`@modelcontextprotocol/sdk` is bundled in;
  `node:sqlite` is a Node core module). It runs in any checkout with no install.
- `${CLAUDE_PLUGIN_ROOT}` is substituted in plugin context (the install case —
  including when you work in this repo with the `sge` plugin installed). Claude
  Code does **not** substitute it in a project-scoped `.mcp.json` and the
  `${VAR:-default}` modifier is not honoured for plugin variables, so a repo
  opened standalone *without* the plugin installed would need a local relative
  override (`./mcp/sge-cortex/dist/sge-cortex.bundle.mjs`).

### Authoritative database location

There is **one** DB per repo *identity*, stored outside any working tree. The
server resolves its path itself — never from unexpanded `${CLAUDE_PLUGIN_ROOT}`
and never by using the working directory as a relative-path base (the two
mechanisms that proved unreliable). Precedence:

1. `LIBSQL_URL` env override (advanced/testing);
2. `CORTEX_TARGET_REPO=<org>/<repo>` — hub-dispatch override;
3. **`CLAUDE_PROJECT_DIR` set** (Claude Code): the `origin` identity of that
   dir → `~/.claude/sge-memory/<org>/<repo>.db` (shared by every worktree of
   the repo); else, if the dir is itself a repo root with no remote,
   `<dir>/memory/sge-memory.db`; else an **isolated** per-workspace DB at
   `~/.claude/sge-memory/_unresolved/<dirname>-<hash>.db`. Resolution never
   walks above `CLAUDE_PROJECT_DIR`;
4. **`CLAUDE_PROJECT_DIR` unset** (GitHub Copilot CLI and other hosts, direct
   `node` runs): the `origin` identity of the launch directory. Only when the
   server is **not** running from an installed plugin (no
   `.claude-plugin/plugin.json` above it — i.e. a source checkout) does it
   then try the server directory's own `origin`, then the nearest repo-root
   marker above it. An installed plugin's own remote or `CLAUDE.md` never
   identifies the consumer repo;
5. nothing resolvable → the server **refuses to start** with a
   `CortexDbPathError` naming `CORTEX_TARGET_REPO` / `LIBSQL_URL`. It never
   falls back to a DB at the filesystem root (the behaviour of earlier builds, which
   produced a machine-wide `C:\memory\sge-memory.db`).

At startup the server prints the chosen location and tier to stderr (the MCP
transport is stdout), e.g.
`[sge-cortex] local memory DB: /home/u/.claude/sge-memory/acme/widget.db (resolved via cwd-git-remote)`.
Only the path and tier are printed — never memory content.

**Data stranded in a filesystem-root DB** (`C:\memory\sge-memory.db` or
`/memory/sge-memory.db`, from an earlier build): that file can hold memories
from **every** repo that ran there, and `import_local_db` imports all of it
into the current repo's DB. So there is no automatic migration:

- If only one repo ever used that machine's root DB, import it from a session
  in that repo (`import_local_db` with the root path as `sourcePath`; it is
  non-destructive and idempotent).
- If several repos may have used it, do not import it wholesale. Move it
  aside as a backup, and re-create the memories that matter per repo.

Then delete the root file and its `-wal`/`-shm` siblings.

`memory/` is git-ignored, so the database is **never committed**. Claude Code
picks up the server automatically when the plugin is installed; tools appear
under the `sge-memory` MCP namespace.

## Conventions

When skills use it, they should:

- **Always pass an explicit namespace.** Suggested namespaces:
  `sge:pipeline-state`, `sge:review-verdicts`, `sge:decisions`,
  `sge:conflict-map`.
- For semantic search, use a tight similarity **threshold (≤ ~0.2)** so only
  genuinely related entries come back.

## Optional and non-blocking

`sge-memory` is **optional**. It is a convenience store, not a hard dependency:

- If the server is not registered or fails to start, skills must **degrade
  gracefully** and continue without persisted memory.
- Nothing in the SGE workflow should fail because memory is unavailable.

> Wiring individual skills to read/write `sge-memory` is intentionally **out of
> scope** for the change that shipped this MCP — that lands as follow-up. This
> page documents the server and its conventions; skills adopt it incrementally.
