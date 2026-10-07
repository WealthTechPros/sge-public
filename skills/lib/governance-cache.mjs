#!/usr/bin/env node
/**
 * governance-cache.mjs — IO layer for the governance-trace comment-cache
 * short-circuit (issue #1337; story #1258).
 *
 * `scripts/govtrace-cache.mjs` provides the pure, IO-free primitives
 * (`parseGovtraceComment`, `isCacheFresh`). This module is the IO layer that
 * sits above them: it calls `gh` to list issue comments, calls `git` to
 * resolve per-artefact SHAs, and combines the results through the pure
 * functions into a single, actionable freshness decision.
 *
 * Why a separate module from `scripts/govtrace-cache.mjs`?
 *
 *   The script-level CLI (`govtrace-cache.mjs decide`) accepts a pre-fetched
 *   comment body via stdin and uses `stat` (mtime) for freshness. That is
 *   correct for a shell-level caller that has already fetched the comment.
 *   This module is for callers that want a single entry point that handles
 *   both the `gh` fetch AND the git SHA resolution — notably, the
 *   governance-trace SKILL.md Step 0.5 can call this module's `check-fresh`
 *   CLI instead of chaining multiple bash commands.
 *
 * Exports:
 *   - `findLatestGovtraceComment(issueNumber, { repo?, cwd? })`
 *     → `{ body, createdAt, url } | null`
 *     Fetches the issue's comments via `gh` and returns the newest one whose
 *     body opens with `## Governance trace`, or null if none exists.
 *
 *   - `resolveArtefactSha(path, { cwd? })`
 *     → `string | null`
 *     Returns the HEAD commit SHA for the given path (`git log -n1 -- <path>`),
 *     or null when the path is untracked / unreadable / not in a git repo.
 *     A null sha is treated as "changed" by `isCacheFresh`.
 *
 *   - `decideFreshness(issueNumber, artefactPaths, { repo?, cwd? })`
 *     → `{ fresh, verdict, matchedSpec, reason }`
 *     Full short-circuit decision: fetch the latest govtrace comment, resolve
 *     each artefact's current SHA, compare against the SHA embedded in the
 *     comment metadata, and return the same `{ fresh, verdict, matchedSpec,
 *     reason }` shape as `govtrace-cache.mjs decide`. Always exits without
 *     throwing — fails toward `fresh: false` on any IO error.
 *
 * CLI:
 *   node skills/lib/governance-cache.mjs check-fresh <issue>
 *     [--repo owner/repo] [--cwd <dir>]
 *     --artefact <path> [--artefact <path> ...]
 *
 *   Prints one line of JSON: { fresh, verdict, matchedSpec, reason }.
 *   Exits 0 always — the gate itself is authoritative; `fresh:false` here means
 *   "run the gate at full depth", never "block the lane".
 *
 * Dependency: `scripts/govtrace-cache.mjs` (pure primitives, same repo).
 * Node >= 18, no external dependencies. Repo convention for scripts/*.mjs /
 * skills/lib/*.mjs.
 */

import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, resolve as resolvePath } from "node:path";

// Resolve the shared pure-primitives module relative to this file.
// The canonical location is `<repo-root>/scripts/govtrace-cache.mjs`.
// When this module is called from a plugin checkout at a non-root path,
// `CLAUDE_PLUGIN_ROOT` (injected by the Claude Code harness) points to the
// repo root; otherwise we walk up from this file's own location.
function _primitivesPath() {
  const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT;
  if (pluginRoot) return resolvePath(pluginRoot, "scripts", "govtrace-cache.mjs");
  // skills/lib/governance-cache.mjs -> skills/lib -> skills -> repo root.
  // Use fileURLToPath (not URL.pathname) so Windows drive-letter paths resolve
  // correctly — .pathname yields "/C:/..." which resolvePath doubles to "C:\C:\..".
  const dir = dirname(fileURLToPath(import.meta.url));
  return resolvePath(dir, "..", "..", "scripts", "govtrace-cache.mjs");
}

const { parseGovtraceComment, isCacheFresh } = await import(
  pathToFileURL(_primitivesPath()).href
);

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/**
 * Run a command (array of args, no shell) and return stdout as a string, or
 * null on any error. Never throws.
 */
function _run(args, { cwd, input } = {}) {
  try {
    return execFileSync(args[0], args.slice(1), {
      cwd,
      input,
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

/**
 * Fetch the newest `## Governance trace` comment on a GitHub issue.
 *
 * Uses `gh issue view` — the caller must have `gh` authenticated and the repo
 * accessible. `repo` is optional; when omitted, `gh` uses the repo inferred
 * from the current working directory (the ambient repo).
 *
 * @param {number|string} issueNumber
 * @param {{ repo?: string, cwd?: string }} [opts]
 * @returns {{ body: string, createdAt: string, url: string } | null}
 */
export async function findLatestGovtraceComment(issueNumber, opts = {}) {
  const { repo, cwd } = opts;
  const ghArgs = [
    "gh", "issue", "view", String(issueNumber),
    "--json", "comments",
    "--jq",
    // Sort all comments by createdAt ascending, then pick the LAST one whose
    // body matches the `## Governance trace` heading.  The jq expression is
    // kept on one line so it can be passed as a single arg safely.
    '[.comments[] | select(.body | test("^\\s*##\\s+Governance trace";"i"))] | sort_by(.createdAt) | last // empty',
  ];
  if (repo) ghArgs.splice(2, 0, "--repo", repo);

  const raw = _run(ghArgs, { cwd });
  if (!raw || raw.trim() === "") return null;

  try {
    const obj = JSON.parse(raw.trim());
    if (!obj || typeof obj !== "object") return null;
    return {
      body: String(obj.body ?? ""),
      createdAt: String(obj.createdAt ?? ""),
      url: String(obj.url ?? ""),
    };
  } catch {
    return null;
  }
}

/**
 * Resolve the current HEAD commit SHA for a file, using `git log`.
 *
 * Returns the 40-character commit SHA, or null when the path is untracked,
 * the directory is not a git repo, or any error occurs. A null sha is treated
 * as a change by `isCacheFresh` (fail toward staleness).
 *
 * @param {string} filePath — repo-relative or absolute path to the artefact.
 * @param {{ cwd?: string }} [opts]
 * @returns {string | null}
 */
export async function resolveArtefactSha(filePath, opts = {}) {
  const { cwd } = opts;
  const raw = _run(
    ["git", "log", "--format=%H", "-n", "1", "--", filePath],
    { cwd }
  );
  if (!raw) return null;
  const sha = raw.trim();
  // A 40-char hex string is the expected output; anything else (empty, error
  // message fragments) means the file has no tracked history.
  return /^[0-9a-f]{40}$/i.test(sha) ? sha : null;
}

/**
 * Full short-circuit decision: find the latest governance-trace comment,
 * resolve artefact SHAs, and decide freshness.
 *
 * The SHA embedded in the comment metadata (the comment's `createdAt`
 * timestamp) is compared against each artefact's current `git log` SHA via
 * the `isCacheFresh` SHA-pair mode — specifically, the current SHA is compared
 * against the SHA at the time the comment was created. Because the GitHub
 * comment carries only a `createdAt` timestamp (not a stored SHA), we resolve
 * BOTH the current SHA AND the SHA as-of `createdAt` via `git log --before`.
 * If any artefact's SHA changed since `createdAt`, it is stale.
 *
 * Fails toward `fresh: false` on any IO error, missing comment, or unparseable
 * timestamp. Never throws.
 *
 * @param {number|string} issueNumber
 * @param {string[]} artefactPaths — repo-relative or absolute paths.
 * @param {{ repo?: string, cwd?: string }} [opts]
 * @returns {Promise<{ fresh: boolean, verdict: string|null, matchedSpec: string|null, reason: string }>}
 */
export async function decideFreshness(issueNumber, artefactPaths, opts = {}) {
  // `_findComment` is a test-only seam: it defaults to the real `gh`-backed
  // fetch, and lets unit tests inject a comment fixture without shelling out.
  const { repo, cwd, _findComment = findLatestGovtraceComment } = opts;
  const STALE = (reason, extra = {}) => ({
    fresh: false, verdict: null, matchedSpec: null, ...extra, reason,
  });

  // Step 1: fetch the latest governance-trace comment.
  const comment = await _findComment(issueNumber, { repo, cwd });
  if (!comment) return STALE("no prior `## Governance trace` comment on this issue");

  // Step 2: parse the comment body.
  const parsed = parseGovtraceComment(comment.body);
  if (!parsed) return STALE("comment body is not a parseable governance-trace comment");

  // Step 3: require at least one artefact to verify freshness against.
  if (!artefactPaths || artefactPaths.length === 0) {
    return STALE("no artefacts supplied to verify freshness against", {
      verdict: parsed.verdict, matchedSpec: parsed.matchedSpec,
    });
  }

  // Step 4: resolve the current SHA for each artefact and the SHA as-of the
  // comment's createdAt, then build { sha, cachedSha } pairs for isCacheFresh.
  const postedAt = comment.createdAt; // ISO-8601, e.g. "2026-07-15T12:34:56Z"

  // Validate the timestamp BEFORE it reaches `git log --before=`. An empty or
  // unparseable value makes git SILENTLY IGNORE the --before filter, so the
  // "cached" SHA would equal the current SHA and every artefact would look
  // unchanged — reporting a stale verdict as fresh and skipping the governance
  // gate. Fail toward staleness instead (the module's documented contract).
  if (Number.isNaN(Date.parse(postedAt))) {
    return STALE(
      "comment createdAt is missing or unparseable — cannot verify freshness",
      { verdict: parsed.verdict, matchedSpec: parsed.matchedSpec },
    );
  }

  const shaEntries = [];
  for (const p of artefactPaths) {
    const currentSha = await resolveArtefactSha(p, { cwd });
    // Resolve the SHA as it was at the comment's post time using `git log --before`.
    // Accepted residual risk: `--before` is second-granular and inclusive, so a
    // commit landing in the SAME second as the comment can be counted as
    // "before" it — a sub-second race that at worst treats a just-changed
    // artefact as unchanged. Not worth sub-second precision here; the gate
    // itself remains authoritative on the next invocation.
    const cachedRaw = _run(
      ["git", "log", "--format=%H", "-n", "1",
       `--before=${postedAt}`, "--", p],
      { cwd }
    );
    const cachedSha = cachedRaw && /^[0-9a-f]{40}$/i.test(cachedRaw.trim())
      ? cachedRaw.trim()
      : null;

    shaEntries.push({ sha: currentSha, cachedSha });
  }

  const fresh = isCacheFresh({ artefactMtimesOrShas: shaEntries });
  return {
    fresh,
    verdict: parsed.verdict,
    matchedSpec: parsed.matchedSpec,
    reason: fresh
      ? "cached verdict valid: no governance artefact changed since the comment"
      : "one or more governance artefacts changed since the comment was posted, or SHA resolution failed",
  };
}

// ---------------------------------------------------------------------------
// CLI entry
// ---------------------------------------------------------------------------
//
// Usage:
//   node skills/lib/governance-cache.mjs check-fresh <issue>
//     [--repo owner/repo] [--cwd <dir>]
//     --artefact <path> [--artefact <path> ...]
//
// Prints one line of JSON and exits 0.

/**
 * Parse the `check-fresh` CLI args.
 * Returns { issueNumber, repo, cwd, artefacts }.
 */
function _parseCheckFreshArgs(argv) {
  const artefacts = [];
  let repo = null;
  let cwd = null;
  let issueNumber = null;

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--artefact" || a === "-a") {
      artefacts.push(argv[++i]);
    } else if (a === "--repo" || a === "-r") {
      repo = argv[++i];
    } else if (a === "--cwd") {
      cwd = argv[++i];
    } else if (!issueNumber && /^\d+$/.test(a)) {
      issueNumber = a;
    }
  }
  return { issueNumber, repo, cwd, artefacts: artefacts.filter(Boolean) };
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const [verb, ...rest] = process.argv.slice(2);

  if (verb === "check-fresh") {
    const { issueNumber, repo, cwd, artefacts } = _parseCheckFreshArgs(rest);

    if (!issueNumber) {
      process.stderr.write(
        "usage: governance-cache.mjs check-fresh <issue> [--repo owner/repo] [--cwd <dir>] --artefact <path> [...]\n"
      );
      process.exit(0); // Advisory — never block the lane with a usage error.
    }

    const decision = await decideFreshness(issueNumber, artefacts, { repo, cwd });
    process.stdout.write(JSON.stringify(decision) + "\n");
  } else {
    process.stderr.write(
      "usage: governance-cache.mjs check-fresh <issue> [--repo owner/repo] [--cwd <dir>] --artefact <path> [...]\n" +
        "  fetches the latest `## Governance trace` comment on the issue via `gh`,\n" +
        "  resolves governance artefact SHAs via `git`, and prints\n" +
        "  { fresh, verdict, matchedSpec, reason } to stdout (exits 0 always).\n"
    );
  }
}
