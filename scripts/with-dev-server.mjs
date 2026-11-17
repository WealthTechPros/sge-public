#!/usr/bin/env node
/**
 * with-dev-server.mjs — start dev server(s), wait for HTTP, run one command,
 * always kill the servers' whole process trees (#3518).
 *
 * Runtime QA (/sge:qa-audit, /sge:design-gate, design-reviewer's static
 * evidence) used to start a dev server in the background and "stop it" at the
 * end with no saved process ID, so servers leaked (the reason
 * /sge:reap-orphans exists). This helper owns the lifecycle instead.
 *
 * Usage
 * -----
 *   node with-dev-server.mjs --server "<cmd>" --port <n>
 *        [--server "<cmd>" --port <n> ...]       repeatable, paired in order
 *        [--path /health]                        probe path (default /)
 *        [--host localhost]                      probe host (default localhost)
 *        [--timeout-ms 120000]                   per-server readiness timeout
 *        [--log-dir <dir>]                       server logs (default: a temp dir)
 *        -- <command> [args...]
 *
 *   Each --server is started through the shell (so `cd ../base && npm run dev`
 *   works, e.g. for a base-vs-head pair) with stdout+stderr written to
 *   <log-dir>/server-<i>-port-<n>.log. The helper waits until each port
 *   answers an HTTP request (any status; an open TCP port that never answers
 *   does not count), then runs <command> with inherited stdio. A single
 *   argument after `--` runs through the shell (use this for npm/npx on
 *   Windows); several arguments are executed directly.
 *
 *   Whatever happens (success, failure, timeout, Ctrl+C) every server's
 *   process tree is killed: Windows `taskkill /T /F /PID <pid>`, POSIX the
 *   server's own process group (SIGTERM, then SIGKILL after 5 s).
 *
 * Exit codes
 *   <command>'s exit code when the servers came up,
 *   2 bad arguments,
 *   3 a server did not answer HTTP before the timeout, exited before the
 *     command started, or its port already accepted TCP connections before it
 *     started (qa-audit marks every criterion `blocked`; the log tail is on stderr),
 *   130 interrupted.
 *
 * Stderr carries `with-dev-server: log <path>` per server, so the caller can
 * quote the log as evidence. Node stdlib only.
 */

import { spawn, spawnSync } from "node:child_process";
import { closeSync, mkdirSync, openSync, readFileSync } from "node:fs";
import http from "node:http";
import net from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const IS_WIN = process.platform === "win32";

/** Parse argv (after the script) into { servers[], command[], opts } or throw. */
export function parseArgs(args) {
  const servers = [];
  const ports = [];
  const opts = { path: "/", host: "localhost", timeoutMs: 120000, logDir: null, help: false };
  let command = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const val = () => {
      const v = args[++i];
      if (v === undefined) throw new Error(`${a} needs a value`);
      return v;
    };
    if (a === "--") {
      command = args.slice(i + 1);
      break;
    } else if (a === "--help" || a === "-h") opts.help = true;
    else if (a === "--server") servers.push(val());
    else if (a === "--port") {
      const p = Number(val());
      if (!Number.isInteger(p) || p < 1 || p > 65535) throw new Error(`bad --port ${args[i]}`);
      ports.push(p);
    } else if (a === "--path") opts.path = val();
    else if (a === "--host") opts.host = val();
    else if (a === "--timeout-ms") {
      opts.timeoutMs = Number(val());
      if (!Number.isFinite(opts.timeoutMs) || opts.timeoutMs <= 0) throw new Error(`bad --timeout-ms ${args[i]}`);
    } else if (a === "--log-dir") opts.logDir = val();
    else throw new Error(`unknown argument ${a}`);
  }
  if (opts.help) return { servers: [], command: [], opts };
  if (servers.length === 0) throw new Error("at least one --server is required");
  if (servers.length !== ports.length) throw new Error(`${servers.length} --server but ${ports.length} --port; pair each server with its port`);
  // Two servers on one port would both be "ready" off whichever answered
  // first, so a base-vs-head run could test one build twice (CodeRabbit, #3541).
  const dup = ports.find((p, i) => ports.indexOf(p) !== i);
  if (dup !== undefined) throw new Error(`--port ${dup} is given twice; each server needs its own port`);
  if (command.length === 0) throw new Error("no command after --");
  if (!opts.path.startsWith("/")) opts.path = "/" + opts.path;
  return { servers: servers.map((cmd, i) => ({ cmd, port: ports[i] })), command, opts };
}

/** One HTTP request; resolves to the status code, rejects on error/timeout. */
function probe(host, port, path, timeoutMs) {
  return new Promise((res, rej) => {
    const req = http.get({ host, port, path, timeout: timeoutMs }, (r) => {
      r.resume();
      res(r.statusCode);
    });
    req.on("timeout", () => req.destroy(new Error("probe timeout")));
    // The socket timeout above only measures inactivity and resets on any
    // byte received; bound the whole probe with an absolute deadline too.
    const deadline = setTimeout(() => req.destroy(new Error("probe deadline")), timeoutMs);
    req.on("close", () => clearTimeout(deadline));
    req.on("error", rej);
  });
}

/**
 * True when something already accepts TCP connections on host:port. A TCP
 * connect, not an HTTP probe: a listening server that is slow to answer HTTP
 * must still count as in use (CodeRabbit, #3541).
 */
export function portInUse(host, port, timeoutMs = 500) {
  return new Promise((res) => {
    const sock = net.connect({ host, port });
    const done = (busy) => {
      sock.destroy();
      res(busy);
    };
    sock.setTimeout(timeoutMs, () => done(false));
    sock.once("connect", () => done(true));
    sock.once("error", () => done(false));
  });
}

/**
 * Poll until the port answers HTTP. Resolves { ok: true, status } or
 * { ok: false, reason }. `exited()` returns a reason string once the server
 * process has exited (fail fast instead of waiting out the timeout).
 */
export async function waitForHttp({ host, port, path, timeoutMs, exited = () => null }) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const gone = exited();
    if (gone) return { ok: false, reason: gone };
    try {
      const status = await probe(host, port, path, Math.min(2000, Math.max(1, deadline - Date.now())));
      // The server may have exited (e.g. EADDRINUSE) while the probe was in
      // flight, and the answer then came from something else.
      const goneNow = exited();
      if (goneNow) return { ok: false, reason: goneNow };
      return { ok: true, status };
    } catch {
      await new Promise((r) => setTimeout(r, 250));
    }
  }
  return { ok: false, reason: `no HTTP response from http://${host}:${port}${path} within ${timeoutMs} ms` };
}

function groupAlive(pid) {
  try {
    process.kill(-pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** Kill a process and all its descendants. Synchronous on Windows; awaits the group on POSIX. */
export async function killTree(pid) {
  if (!pid) return;
  if (IS_WIN) {
    spawnSync("taskkill", ["/T", "/F", "/PID", String(pid)], { stdio: "ignore", windowsHide: true });
    return;
  }
  try {
    process.kill(-pid, "SIGTERM");
  } catch {
    return; // group already gone
  }
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline && groupAlive(pid)) await new Promise((r) => setTimeout(r, 100));
  if (groupAlive(pid)) {
    try {
      process.kill(-pid, "SIGKILL");
    } catch {
      /* gone */
    }
  }
}

function logTail(file, lines = 40) {
  try {
    return readFileSync(file, "utf8").split(/\r?\n/).slice(-lines).join("\n");
  } catch {
    return "(no log)";
  }
}

function startServer(cmd, logFile) {
  const fd = openSync(logFile, "a");
  // detached on POSIX = own process group, so the whole tree dies with -pid.
  // On Windows detached would open a new console; taskkill /T walks the tree instead.
  const child = spawn(cmd, { shell: true, stdio: ["ignore", fd, fd], detached: !IS_WIN, windowsHide: true });
  closeSync(fd);
  const state = { child, exit: null };
  child.on("exit", (code, signal) => (state.exit = `server exited early (code ${code}, signal ${signal})`));
  child.on("error", (e) => (state.exit = `server failed to spawn: ${e.message}`));
  return state;
}

function runCommand(command, track) {
  return new Promise((res) => {
    // Own process group on POSIX (like the servers), so a signal to the helper
    // can take the command's whole tree down too.
    const opts = { stdio: "inherit", detached: !IS_WIN, windowsHide: true };
    const child =
      command.length === 1
        ? spawn(command[0], { ...opts, shell: true })
        : spawn(command[0], command.slice(1), opts);
    track.child = child;
    child.on("exit", (code, signal) => {
      track.done = true;
      res(code ?? (signal ? 1 : 0));
    });
    child.on("error", (e) => {
      process.stderr.write(`with-dev-server: command failed to start: ${e.message}\n`);
      res(1);
    });
  });
}

export const HELP = readFileSync(fileURLToPath(import.meta.url), "utf8")
  .match(/\/\*\*([\s\S]*?)\*\//)[1]
  .split("\n")
  .map((l) => l.replace(/^ \* ?/, "").replace(/^ \*$/, ""))
  .join("\n")
  .trim();

/** Run the helper; resolves to the process exit code. */
export async function main(argv) {
  let parsed;
  try {
    parsed = parseArgs(argv);
  } catch (e) {
    process.stderr.write(`with-dev-server: ${e.message}\nRun with --help for the full contract.\n`);
    return 2;
  }
  if (parsed.opts.help) {
    process.stdout.write(HELP + "\n");
    return 0;
  }
  const { servers, command, opts } = parsed;
  const logDir = resolve(opts.logDir || join(tmpdir(), `sge-dev-server-${Date.now()}`));
  mkdirSync(logDir, { recursive: true });

  const started = [];
  const cmd = { child: null, done: false };
  let cleaned = null;
  let interrupted = false;
  const cleanup = () =>
    (cleaned ??= Promise.all([
      // the command is killed only while it still runs (no stale-PID kill on Windows)
      cmd.child && !cmd.done ? killTree(cmd.child.pid) : null,
      ...started.map((s) => killTree(s.state.child.pid)),
    ]));
  const onSignal = (sig) => {
    interrupted = true;
    process.stderr.write(`with-dev-server: ${sig} — killing the command and server tree(s)\n`);
    cleanup().then(() => process.exit(130));
  };
  const signals = IS_WIN ? ["SIGINT", "SIGBREAK"] : ["SIGINT", "SIGTERM", "SIGHUP"];
  for (const s of signals) process.on(s, onSignal);

  try {
    for (const s of servers) {
      // Something already listening on the port would be probed instead of our
      // server (often a leaked one) — refuse rather than test the wrong build.
      if (await portInUse(opts.host, s.port)) {
        process.stderr.write(`with-dev-server: port ${s.port} already in use before the server started (a leaked server? see /sge:reap-orphans)\n`);
        return 3;
      }
    }
    if (interrupted) return 130;
    for (const [i, s] of servers.entries()) {
      const log = join(logDir, `server-${i}-port-${s.port}.log`);
      process.stderr.write(`with-dev-server: log ${log}\n`);
      started.push({ log, state: startServer(s.cmd, log) });
    }
    for (const [i, s] of servers.entries()) {
      const { state, log } = started[i];
      const r = await waitForHttp({ host: opts.host, port: s.port, path: opts.path, timeoutMs: opts.timeoutMs, exited: () => state.exit });
      if (!r.ok) {
        process.stderr.write(`with-dev-server: server ${i} (${s.cmd}) not ready: ${r.reason}\n--- log tail ${log} ---\n${logTail(log)}\n---\n`);
        return 3;
      }
      process.stderr.write(`with-dev-server: http://${opts.host}:${s.port}${opts.path} answered ${r.status}\n`);
    }
    // A server can answer and then exit while a later one is still coming up;
    // never start the command with any recorded server failure.
    for (const [i, s] of servers.entries()) {
      const { state, log } = started[i];
      if (state.exit) {
        process.stderr.write(`with-dev-server: server ${i} (${s.cmd}) not ready: ${state.exit}\n--- log tail ${log} ---\n${logTail(log)}\n---\n`);
        return 3;
      }
    }
    if (interrupted) return 130;
    return await runCommand(command, cmd);
  } finally {
    await cleanup();
    for (const s of signals) process.off(s, onSignal);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exit(await main(process.argv.slice(2)));
}
