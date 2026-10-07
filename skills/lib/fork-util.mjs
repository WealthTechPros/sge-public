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
 *                               [--issue <N>] [--repo <owner/repo>] [--fresh]
 *     Record that a fork was dispatched and will write its verdict JSON
 *     (governance-trace Step-7 shape) to <output-file>.
 *     Writes /tmp/sge-fork-<id>.json with { outputFile, resultFile, registeredAt }.
 *     `resultFile` is a native absolute path the caller may write a
 *     foreground fork's raw result text to (with its file-Write tool) for
 *     `ingest --input-file` — no shell ever sees that untrusted text.
 *     --fresh: delete any stale outputFile/resultFile left by an earlier run
 *     under the same handle id, so a later failed ingest can never let `join`
 *     adopt the previous run's verdict (PR #2710 review). Only for callers
 *     that register BEFORE dispatching (build-ready-audit); the async
 *     sge-implement path registers after dispatch and uses a random id.
 *     Stdout: JSON { ok: true, handleId, outputFile, resultFile, issue, repo }
 *     Exit 0 on success, 1 on bad args.
 *
 *   node fork-util.mjs join --handle-id <id> [--timeout-ms <ms>]
 *     Await the fork verdict. Polls <output-file> until it appears or
 *     <timeout-ms> elapses (default: 900_000 ms / 15 min).
 *     Stdout: the verdict JSON (governance-trace Step-7 shape), with an added
 *       `joinedAt` field (ISO timestamp of when join resolved).
 *     Exit 0 on success (verdict read), 1 on timeout, 2 on invalid handle.
 *
 *   node fork-util.mjs ingest --handle-id <id> --input-file <path>
 *     Record a FOREGROUND fork's returned text as the handle's verdict file
 *     (#2452 repro #3: build-ready-audit's Agent forks return their Step-7
 *     JSON as the tool result, not a file). The text is read ONLY from
 *     --input-file, which the caller writes with a file-Write tool — never
 *     through a shell heredoc (a result line equal to the terminator would
 *     end it early and run the rest as shell, PR #2710 review). Stdin is
 *     deliberately not accepted.
 *     Extraction is deliberately narrow: the whole text if it parses as a
 *     JSON object, else a single ```json / ```JSON / untagged fence that
 *     spans the WHOLE message. A fence embedded in prose is never adopted
 *     (it may be a quoted issue body's fence). Anything else is written
 *     verbatim so `join` rejects it ("not valid JSON") — ingest never judges
 *     the verdict; join remains the only gate.
 *     Stdout: JSON { ok: true, handleId, outputFile, extracted: whole|fenced|none }
 *     Exit 0 when recorded, 1 on missing/empty/unreadable input file or bad
 *     args, 2 on unknown handle.
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

import { readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { setTimeout as sleep } from "node:timers/promises";
import { tmpdir } from "node:os";
import { join as pathJoin, resolve, sep } from "node:path";

// ─── Constants ───────────────────────────────────────────────────────────────

const POLL_INTERVAL_MS = 2_000; // check output file every 2 s
const DEFAULT_TIMEOUT_MS = 900_000; // 15 min — ample for a governance-trace fork

// governance-trace Step-7 verdicts `join` may adopt (PR #2710 review: join must
// validate the verdict value, not just its issue/repo echo). NO_TARGET_ISSUE is
// a refusal, never an adoptable classification.
const ADOPTABLE_VERDICTS = new Set([
  "MATCHES_EXISTING",
  "MATCHES_EXISTING_MODIFIED",
  "NEEDS_NEW_SPEC",
  "NO_SPEC_WARRANTED",
  "NOT_SGE_SCOPE",
  "NOT_ONBOARDED",
]);

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
  // Handle ids become file names under the temp dir: confine them to a safe
  // charset so an id can never traverse out of it (PR #2710 re-review).
  if (typeof id !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id) || id.includes("..")) {
    die(1, `invalid --handle-id ${JSON.stringify(id)} (allowed: [A-Za-z0-9._-], no "..")`);
  }
  return pathJoin(HANDLE_DIR, `sge-fork-${id}.json`);
}

/** Resolve the path a caller writes a foreground fork's raw result text to. */
function resultPath(id) {
  return pathJoin(HANDLE_DIR, `sge-fork-${id}.result.txt`);
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
  // Bind the handle to its target repo too (#2452): a fork that resolved the
  // wrong repo (e.g. the hub/control session's own cwd) produces a verdict for
  // the right issue NUMBER in the wrong repo — join() rejects it.
  // A --repo that is present but empty/valueless (`--repo "$REPO"`, $REPO unset)
  // or not owner/repo must fail closed: silently binding null would skip the
  // repo-echo check in join. Omitting --repo entirely stays back-compat.
  if ("repo" in flags && !(typeof flags["repo"] === "string" && /^[^/\s]+\/[^/\s]+$/.test(flags["repo"]))) {
    die(1, `--repo must be owner/repo (got ${flags["repo"] === true ? "no value" : JSON.stringify(flags["repo"])})`);
  }
  const repo = typeof flags["repo"] === "string" ? flags["repo"] : null;

  const resultFile = resultPath(id);
  if (flags["fresh"] === true) {
    rmSync(outputFile, { force: true });
    rmSync(resultFile, { force: true });
  }

  const record = { outputFile, resultFile, issue, repo, registeredAt: new Date().toISOString() };
  writeFileSync(handlePath(id), JSON.stringify(record, null, 2) + "\n", "utf8");
  out({ ok: true, handleId: id, outputFile, resultFile, issue, repo });
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

  const {
    outputFile,
    registeredAt,
    issue: expectedIssue,
    repo: expectedRepo = null,
  } = JSON.parse(readFileSync(hp, "utf8"));

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
      if (!ADOPTABLE_VERDICTS.has(verdict.verdict)) {
        die(1, `verdict "${verdict.verdict}" at ${outputFile} is not an adoptable governance-trace verdict — refusing`);
      }

      // Contamination guard: if the handle is bound to an issue and the verdict
      // carries its own `issue`, they MUST agree. A mismatch means this output
      // belongs to a different lane (PID-recycled handle, shared tmpdir) — never
      // adopt it to gate this issue against the wrong classification. Exit 1 so
      // the caller falls back to a fresh, correctly-scoped fork.
      //
      // Fork result contract (#2452): when the handle is bound to an issue, the
      // verdict MUST echo it. A verdict with no `issue` at all is unverifiable —
      // a fork that "reported findings" without ever classifying the dispatched
      // target (the fabrication-risk variant) looks exactly like this, as does
      // the NO_TARGET_ISSUE refusal (`issue: null`). Neither is adoptable.
      // Echoes must be scalars: an array/object `issue` or `repo` could
      // String()-coerce into a match (PR #2710 re-review).
      for (const k of ["issue", "repo"]) {
        if (verdict[k] != null && typeof verdict[k] === "object") {
          die(1, `verdict at ${outputFile} has a non-scalar "${k}" echo — refusing`);
        }
      }
      if (expectedIssue != null) {
        if (verdict.issue == null) {
          die(
            1,
            `verdict at ${outputFile} does not echo an issue number (handle bound to ${expectedIssue}) — refusing unverifiable verdict`
          );
        }
        if (String(verdict.issue) !== expectedIssue) {
          die(
            1,
            `verdict issue ${verdict.issue} does not match handle issue ${expectedIssue} — refusing cross-lane verdict`
          );
        }
      }
      // Repo binding (#2452 wrong-repo reproduction): a verdict that echoes a
      // different repo was classified against the wrong governance artefacts.
      // Case-insensitive (GitHub owner/repo names are). When the handle is
      // bound to a repo the verdict MUST echo one — governance-trace always
      // emits `repo`, so a missing echo is as unverifiable as a missing issue.
      // Back-compat is kept only for handles registered WITHOUT --repo.
      if (expectedRepo != null) {
        if (verdict.repo == null || verdict.repo === "") {
          die(
            1,
            `verdict at ${outputFile} does not echo a repo (handle bound to ${expectedRepo}) — refusing unverifiable verdict`
          );
        }
        if (String(verdict.repo).toLowerCase() !== expectedRepo.toLowerCase()) {
          die(
            1,
            `verdict repo ${verdict.repo} does not match handle repo ${expectedRepo} — refusing wrong-repo verdict`
          );
        }
      }

      out({ ...verdict, joinedAt: new Date().toISOString(), handleId: id, registeredAt });
      return;
    }
    await sleep(POLL_INTERVAL_MS);
  }

  die(1, `timed out after ${timeoutMs} ms waiting for fork ${id} (output: ${outputFile})`);
}

/**
 * ingest — write a foreground fork's result text (stdin) to the handle's
 * output file, extracting the Step-7 JSON when the fork wrapped it in a
 * ```json fence. See the header comment for the extraction rule.
 */
function cmdIngest(flags) {
  const id = flags["handle-id"];
  if (!id) die(1, "--handle-id is required");
  const hp = handlePath(id);
  if (!existsSync(hp)) die(2, `unknown handle: ${id}`);
  const { outputFile } = JSON.parse(readFileSync(hp, "utf8"));

  // File input only (PR #2710 re-review): no stdin path, so a caller cannot
  // fall back to piping untrusted fork text through a shell heredoc.
  if (typeof flags["input-file"] !== "string") {
    die(1, "--input-file is required (write the fork result with a file-Write tool; stdin is not accepted)");
  }
  const inputFile = resolveTmpPath(flags["input-file"]);
  let raw = "";
  try {
    raw = readFileSync(inputFile, "utf8");
  } catch {
    die(1, `cannot read --input-file ${inputFile} for handle ${id}`);
  }
  const text = raw.trim();
  if (!text) die(1, `empty fork result in ${inputFile} for handle ${id} — nothing to record`);

  const parses = (t) => {
    try {
      const v = JSON.parse(t);
      return v && typeof v === "object" && !Array.isArray(v) ? v : null;
    } catch {
      return null;
    }
  };

  // Whole-message rule (PR #2710 re-review): the fork's final message must
  // BE the verdict — bare JSON, or one fence (```json / ```JSON / untagged)
  // spanning the entire message. A fence embedded in prose is never adopted:
  // prose can quote an issue body's own well-formed fence while the fork's
  // real verdict sits elsewhere in the text. Anything else is recorded
  // verbatim so join rejects it (fail closed → DISPATCH_FAILED).
  let body = text;
  let extracted = "none";
  if (parses(text)) {
    extracted = "whole";
  } else {
    const m = /^```(?:json)?[ \t]*\r?\n([\s\S]*?)\r?\n[ \t]*```$/i.exec(text);
    if (m && !m[1].includes("```") && parses(m[1].trim())) {
      body = m[1].trim();
      extracted = "fenced";
    }
  }
  writeFileSync(outputFile, body + "\n", "utf8");
  out({ ok: true, handleId: id, outputFile, extracted });
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
  case "ingest":
    cmdIngest(flags);
    break;
  case "join":
    await cmdJoin(flags);
    break;
  default:
    die(
      1,
      `unknown command: ${command ?? "(none)"}\n` +
        "Usage: fork-util.mjs <register|status|ingest|join> [--handle-id <id>] [--output-file <path>] [--timeout-ms <ms>]"
    );
}
