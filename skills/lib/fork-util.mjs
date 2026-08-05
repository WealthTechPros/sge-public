#!/usr/bin/env node
/**
 * fork-util.mjs — async governance-trace fork dispatch helpers (#1264).
 *
 * Used by sge-implement Phase 0.5 and the Phase 3 JOIN gate to dispatch the
 * /sge:governance-trace fork asynchronously (without blocking on the verdict)
 * and then join the verdict at the Edit/Write gate before any production code
 * is written.
 *
 * Pattern:
 *   Phase 0.5 — dispatch the fork, immediately register its handle and output
 *               path, then proceed with worktree creation + Phase 2.5 reads.
 *   Phase 3, before Step 2 — join the handle: if the verdict is already
 *               written (fast fork), read it immediately; otherwise poll until
 *               it appears or the timeout lapses (slow fork).
 *
 * Commands
 * --------
 *   node fork-util.mjs register --handle-id <id> --output-file <path>
 *     Record that a fork was dispatched and will write its verdict JSON
 *     (governance-trace Step-7 shape) to <output-file>.
 *     Writes /tmp/sge-fork-<id>.json with { outputFile, registeredAt }.
 *     Stdout: JSON { ok: true, handleId, outputFile }
 *     Exit 0 on success, 1 on bad args.
 *
 *   node fork-util.mjs join --handle-id <id> [--timeout-ms <ms>]
 *     Await the fork verdict. Polls <output-file> until it appears or
 *     <timeout-ms> elapses (default: 900_000 ms / 15 min).
 *     Stdout: the verdict JSON (governance-trace Step-7 shape), with an added
 *       `joinedAt` field (ISO timestamp of when join resolved).
 *     Exit 0 on success (verdict read), 1 on timeout, 2 on invalid handle.
 *
 *   node fork-util.mjs status --handle-id <id>
 *     Check whether a fork has resolved without blocking.
 *     Stdout: JSON { handleId, resolved: bool, outputFile, registeredAt }
 *     Exit 0 (even when not yet resolved; exit 2 if handle is unknown).
 *
 * Handle records live at /tmp/sge-fork-<id>.json and are ephemeral —
 * processes that restart won't see them, which is expected: a session restart
 * means re-running the skill from the beginning anyway.
 *
 * Pure dependency-free ESM (Node >= 18). No external npm packages.
 */

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { tmpdir } from "node:os";
import { join as pathJoin, resolve, sep } from "node:path";

// ─── Constants ───────────────────────────────────────────────────────────────

const POLL_INTERVAL_MS = 2_000; // check output file every 2 s
const DEFAULT_TIMEOUT_MS = 900_000; // 15 min — ample for a governance-trace fork

// The callers (SKILL.md / orchestration.md bash) write these paths as
// `/tmp/…`. On Linux (fleet + CI) `os.tmpdir()` IS `/tmp`, so this is a no-op.
// On Windows, MSYS/Git-Bash `/tmp` resolves to `%LOCALAPPDATA%\Temp` — which is
// exactly what `os.tmpdir()` returns — while Node's own `/tmp` would resolve to
// `C:\tmp`. Resolving through `os.tmpdir()` keeps Node in the SAME directory the
// bash caller used, so register/join agree cross-platform (a hardcoded "/tmp"
// made every Windows join time out and re-fork). Any incoming `/tmp/<name>` path
// is re-homed under os.tmpdir(); already-absolute non-/tmp paths pass through.
const HANDLE_DIR = tmpdir(); // ephemeral; intentional

/**
 * Re-home a caller-supplied `/tmp/<name>` path under the real temp dir, and
 * refuse a re-homed path that escapes it (traversal guard). Already-absolute
 * non-`/tmp` paths pass through untouched (the caller owns their own absolute
 * locations); only the `/tmp/…` rewrite is bounds-checked, since that segment
 * is the one this function fabricates from caller input.
 */
function resolveTmpPath(p) {
  const m = /^\/tmp\/(.+)$/.exec(p);
  if (!m) return p;
  const base = resolve(tmpdir());
  const resolved = resolve(base, m[1]);
  // `resolved` must be `base` itself or a child of it — else the suffix used
  // `..` to climb out of the temp dir.
  if (resolved !== base && !resolved.startsWith(base + sep)) {
    die(1, `refusing path that escapes the temp dir: ${p}`);
  }
  return resolved;
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/** Resolve the path for the handle record file. */
function handlePath(id) {
  return pathJoin(HANDLE_DIR, `sge-fork-${id}.json`);
}

/** Parse CLI args into { command, flags }. Flags with a value use --key val. */
function parseArgs(argv) {
  const [, , command, ...rest] = argv;
  const flags = {};
  for (let i = 0; i < rest.length; i++) {
    if (rest[i].startsWith("--")) {
      const key = rest[i].slice(2);
      const val = rest[i + 1] && !rest[i + 1].startsWith("--") ? rest[++i] : true;
      flags[key] = val;
    }
  }
  return { command, flags };
}

function die(code, msg) {
  process.stderr.write(`fork-util: ${msg}\n`);
  process.exit(code);
}

function out(obj) {
  process.stdout.write(JSON.stringify(obj, null, 2) + "\n");
}

// ─── Commands ────────────────────────────────────────────────────────────────

/**
 * register — record a dispatched fork handle.
 */
function cmdRegister(flags) {
  const id = flags["handle-id"];
  if (!id) die(1, "--handle-id is required");
  if (!flags["output-file"]) die(1, "--output-file is required");
  // Re-home a `/tmp/…` output path so Node and the bash caller agree on Windows.
  const outputFile = resolveTmpPath(flags["output-file"]);
  // Bind the handle to its issue number. join() rejects a verdict whose own
  // `issue` field disagrees — the contamination guard against a fork output
  // (or a PID-recycled handle file) belonging to a sibling lane's issue.
  const issue = flags["issue"] != null ? String(flags["issue"]) : null;

  const record = { outputFile, issue, registeredAt: new Date().toISOString() };
  writeFileSync(handlePath(id), JSON.stringify(record, null, 2) + "\n", "utf8");
  out({ ok: true, handleId: id, outputFile, issue });
}

/**
 * status — non-blocking check of whether the fork has resolved.
 */
function cmdStatus(flags) {
  const id = flags["handle-id"];
  if (!id) die(1, "--handle-id is required");

  const hp = handlePath(id);
  if (!existsSync(hp)) die(2, `unknown handle: ${id}`);

  const record = JSON.parse(readFileSync(hp, "utf8"));
  const resolved = existsSync(record.outputFile);
  out({ handleId: id, resolved, outputFile: record.outputFile, registeredAt: record.registeredAt });
}

/**
 * join — await the fork verdict, polling until the output file appears or
 * timeout elapses. The verdict must be a valid governance-trace Step-7 JSON
 * object (has a `verdict` field); otherwise we treat the output as malformed
 * and exit 1 so the caller falls back to a fresh fork.
 */
async function cmdJoin(flags) {
  const id = flags["handle-id"];
  const timeoutMs = flags["timeout-ms"] ? parseInt(flags["timeout-ms"], 10) : DEFAULT_TIMEOUT_MS;
  if (!id) die(1, "--handle-id is required");

  const hp = handlePath(id);
  if (!existsSync(hp)) die(2, `unknown handle: ${id}`);

  const { outputFile, registeredAt, issue: expectedIssue } = JSON.parse(readFileSync(hp, "utf8"));

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (existsSync(outputFile)) {
      let raw;
      try {
        raw = readFileSync(outputFile, "utf8");
      } catch {
        // File appeared but isn't readable yet — try again next poll.
        await sleep(POLL_INTERVAL_MS);
        continue;
      }

      let verdict;
      try {
        verdict = JSON.parse(raw);
      } catch {
        die(1, `output file at ${outputFile} is not valid JSON — fork may have failed`);
      }

      if (!verdict || typeof verdict.verdict !== "string") {
        die(1, `output file at ${outputFile} has no "verdict" field — fork may have failed`);
      }

      // Contamination guard: if the handle is bound to an issue and the verdict
      // carries its own `issue`, they MUST agree. A mismatch means this output
      // belongs to a different lane (PID-recycled handle, shared tmpdir) — never
      // adopt it to gate this issue against the wrong classification. Exit 1 so
      // the caller falls back to a fresh, correctly-scoped fork.
      if (expectedIssue != null && verdict.issue != null && String(verdict.issue) !== expectedIssue) {
        die(
          1,
          `verdict issue ${verdict.issue} does not match handle issue ${expectedIssue} — refusing cross-lane verdict`
        );
      }

      out({ ...verdict, joinedAt: new Date().toISOString(), handleId: id, registeredAt });
      return;
    }
    await sleep(POLL_INTERVAL_MS);
  }

  die(1, `timed out after ${timeoutMs} ms waiting for fork ${id} (output: ${outputFile})`);
}

// ─── Entry point ─────────────────────────────────────────────────────────────

const { command, flags } = parseArgs(process.argv);

switch (command) {
  case "register":
    cmdRegister(flags);
    break;
  case "status":
    cmdStatus(flags);
    break;
  case "join":
    await cmdJoin(flags);
    break;
  default:
    die(
      1,
      `unknown command: ${command ?? "(none)"}\n` +
        "Usage: fork-util.mjs <register|status|join> [--handle-id <id>] [--output-file <path>] [--timeout-ms <ms>]"
    );
}
