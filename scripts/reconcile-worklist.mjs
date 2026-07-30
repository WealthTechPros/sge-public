#!/usr/bin/env node
/**
 * reconcile-worklist.mjs — pre-flight filter for dispatch skills.
 *
 * Takes a candidate work-list (GitHub issue numbers, file paths, or BDD spec
 * IDs) and DROPS anything that is already done:
 *
 *   • Issue already CLOSED on GitHub
 *   • Issue has a merged PR that semantically closes it
 *     (closedByPullRequestsReferences[].state === "MERGED")
 *   • File path already present on the `main` branch (or --base-branch)
 *   • BDD spec ID already claimed in more than one open PR's diff (conflict)
 *
 * Returns only genuinely-remaining work so dispatch skills never re-do
 * completed work.
 *
 * Usage (CLI):
 *   node scripts/reconcile-worklist.mjs --issues 101,102,103 [--base-branch main] [--repo owner/repo]
 *   node scripts/reconcile-worklist.mjs --files src/foo.ts,src/bar.ts [--base-branch main]
 *   node scripts/reconcile-worklist.mjs --issues 101,102 --files src/foo.ts
 *   node scripts/reconcile-worklist.mjs --issues 101,102 --json   # machine-readable output
 *   node scripts/reconcile-worklist.mjs --spec-ids SPEC-057,SPEC-069  # BDD ownership check
 *   node scripts/reconcile-worklist.mjs --spec-ids SPEC-057 --json   # JSON conflict report
 *   node scripts/reconcile-worklist.mjs --bdd-wave-manifest           # show wave manifest
 *
 * Exit codes:
 *   0 — success (remaining list printed; may be empty)
 *   1 — usage/argument error OR spec ownership conflict detected
 *   2 — gh CLI not available or not authenticated
 *
 * Output (default — human-readable):
 *   Reconcile pre-flight: 3 candidates → 2 dropped → 1 remaining
 *   DROPPED  #101  closed issue
 *   DROPPED  #102  merged PR (#456)
 *   KEEP     #103
 *   KEEP     src/bar.ts
 *   DROPPED  src/foo.ts  present on main
 *
 * Output (--json):
 *   {
 *     "keep":    [103, "src/bar.ts"],
 *     "dropped": [
 *       {"item": 101, "reason": "closed issue"},
 *       {"item": 102, "reason": "merged PR (#456)"},
 *       {"item": "src/foo.ts", "reason": "present on main"}
 *     ],
 *     "stats": { "total": 4, "dropped": 3, "remaining": 1 }
 *   }
 *
 * Output (--spec-ids SPEC-057,SPEC-069):
 *   OK        SPEC-069
 *   CONFLICT  SPEC-057  already in PR #1357 (claude/issue-1330)
 *
 * Output (--spec-ids SPEC-057,SPEC-069 --json):
 *   {
 *     "conflicts": [{"specId": "SPEC-057", "prNumber": 1357, "branch": "claude/issue-1330"}],
 *     "clean": ["SPEC-069"],
 *     "stats": {"total": 2, "conflicts": 1, "clean": 1}
 *   }
 *
 * When gh CLI is absent or unauthenticated the script exits 2 with a clear
 * message — the caller should treat this as a configuration error, not a
 * silent pass-through.
 */

// Node >= 18 guard (parseArgs requires 18.3+)
const [major] = process.versions.node.split(".").map(Number);
if (major < 18) {
  console.error("error: Node.js >= 18 is required (found " + process.versions.node + ")");
  process.exit(1);
}

import { spawnSync } from "node:child_process";
import { parseArgs } from "node:util";
import { readFileSync, existsSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------
const { values: args } = parseArgs({
  options: {
    issues:             { type: "string",  default: "" },
    files:              { type: "string",  default: "" },
    "spec-ids":         { type: "string",  default: "" },
    "bdd-wave-manifest":{ type: "boolean", default: false },
    "base-branch":      { type: "string",  default: "main" },
    repo:               { type: "string",  default: "" },
    json:               { type: "boolean", default: false },
    help:               { type: "boolean", default: false },
  },
  strict: false,
});

if (args.help) {
  console.log(`Usage: node scripts/reconcile-worklist.mjs [options]

Options:
  --issues   <n,n,...>      Comma-separated GitHub issue numbers (integers only)
  --files    <path,...>     Comma-separated file paths to check against base branch
  --spec-ids <SPEC-NNN,...> Comma-separated BDD spec IDs to check for ownership conflicts
                            across open PRs. Exits 1 if any spec appears in >1 open PR.
  --bdd-wave-manifest       Read docs/bdd-wave-manifest.yaml and report claimed
                            specs (informational only — does NOT affect exit code;
                            the authoritative conflict check is --spec-ids, which
                            scans live open-PR diffs)
  --base-branch <branch>    Branch to check file presence on (default: main)
  --repo     <owner/repo>   GitHub repository (default: auto-detected by gh)
  --json                    Emit machine-readable JSON instead of human text
  --help                    Show this help

Exit codes: 0=ok  1=usage error or conflict detected  2=gh not available

Examples:
  # Check BDD ownership before dispatching parallel agents
  node scripts/reconcile-worklist.mjs --spec-ids SPEC-057,SPEC-069 --repo WealthTechPros/sgd

  # Machine-readable conflict report
  node scripts/reconcile-worklist.mjs --spec-ids SPEC-057,SPEC-069 --json

  # Show wave manifest claimed specs
  node scripts/reconcile-worklist.mjs --bdd-wave-manifest
`);
  process.exit(0);
}

// Reject non-integer issue numbers (isNaN passes floats, so use explicit int check)
function isStrictInteger(s) {
  return /^\d+$/.test(s.trim());
}

const issueNums = args.issues
  ? args.issues.split(",").map((s) => s.trim()).filter(Boolean).map((s) => {
      if (!isStrictInteger(s)) {
        console.error(`error: --issues must be comma-separated integers, got: ${s}`);
        process.exit(1);
      }
      return Number(s);
    })
  : [];
const filePaths = args.files
  ? args.files.split(",").map((s) => s.trim()).filter(Boolean)
  : [];
const specIds = args["spec-ids"]
  ? args["spec-ids"].split(",").map((s) => s.trim().toUpperCase()).filter(Boolean)
  : [];
const waveManifestMode = Boolean(args["bdd-wave-manifest"]);
const baseBranch = args["base-branch"] || "main";
// Reject a leading-dash base branch: it would otherwise be parsed as an option
// by `git fetch` / `git cat-file` (e.g. --upload-pack=<cmd> is remote code
// execution). We also pass it after `--` at the call sites as defence in depth.
if (baseBranch.startsWith("-")) {
  console.error(`error: --base-branch must not start with '-' (got: ${baseBranch})`);
  process.exit(1);
}
const repoFlag = args.repo ? ["--repo", args.repo] : [];
const jsonMode = Boolean(args.json);

// True only when run directly as a CLI (node reconcile-worklist.mjs ...), false
// when imported by a test. Guards every process.exit / gh side-effect below so
// the pure functions above can be imported and unit-tested without the module
// parsing argv and exiting. (Node's process.argv[1] is the invoked script.)
const isMain =
  process.argv[1] &&
  fileURLToPath(import.meta.url) === resolve(process.argv[1]);

const hasWork = issueNums.length > 0 || filePaths.length > 0 || specIds.length > 0 || waveManifestMode;
if (isMain && !hasWork) {
  console.error("error: provide at least --issues, --files, --spec-ids, or --bdd-wave-manifest");
  process.exit(1);
}

// ---------------------------------------------------------------------------
// gh CLI availability check
// ---------------------------------------------------------------------------
function ghAvailable() {
  // NOTE: deliberately NO repo flag here — `gh auth status` does not accept
  // --repo/-R and exits non-zero when given one, which made every --repo
  // invocation die here with exit 2 despite an authenticated gh (issue #860).
  // The repo flag belongs on the data calls (gh issue view) only.
  const r = spawnSync("gh", ["auth", "status"], { encoding: "utf8" });
  return r.status === 0;
}

if (isMain && !ghAvailable()) {
  console.error(
    "error: gh CLI not available or not authenticated.\n" +
    "Run `gh auth login` and retry."
  );
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function gh(...ghArgs) {
  const r = spawnSync("gh", ghArgs, { encoding: "utf8" });
  if (r.status !== 0) {
    throw new Error(`gh ${ghArgs.join(" ")} failed:\n${r.stderr}`);
  }
  return r.stdout.trim();
}

function ghJson(...ghArgs) {
  return JSON.parse(gh(...ghArgs));
}

// ---------------------------------------------------------------------------
// Check a single issue: returns { keep: bool, reason: string|null }
//
// Uses the semantic closing-reference lookup instead of free-text PR search.
// gh issue view --json state,closedByPullRequestsReferences gives us the
// PRs that GitHub semantically links to this issue — not a text search that
// matches any PR body mentioning the issue number.
// ---------------------------------------------------------------------------
async function checkIssue(num) {
  let issueData;
  try {
    issueData = ghJson(
      "issue", "view", String(num),
      "--json", "state,number,title,closedByPullRequestsReferences",
      ...repoFlag
    );
  } catch {
    // If the issue doesn't exist or can't be fetched, keep it (conservative).
    return { keep: true, reason: null };
  }

  if (issueData.state === "CLOSED") {
    return { keep: false, reason: "closed issue" };
  }

  // Check semantic closing references: PRs that GitHub links as closing this issue.
  // This is NOT a free-text search — it only returns PRs with a genuine closing link.
  const closingRefs = issueData.closedByPullRequestsReferences ?? [];
  const mergedRef = closingRefs.find((pr) => pr.state === "MERGED");
  if (mergedRef) {
    return { keep: false, reason: `merged PR (#${mergedRef.number})` };
  }

  return { keep: true, reason: null };
}

// ---------------------------------------------------------------------------
// Check a file: returns { keep: bool, reason: string|null }
// Fetches origin/main first to ensure the ref is current.
// ---------------------------------------------------------------------------
function checkFile(filePath) {
  // Freshen the remote ref before checking; ignore fetch errors (offline/CI)
  // so we fall through to the stale check rather than blocking entirely.
  spawnSync("git", ["fetch", "origin", "--", baseBranch], { encoding: "utf8" });

  const r = spawnSync(
    "git", ["cat-file", "-e", `origin/${baseBranch}:${filePath}`],
    { encoding: "utf8" }
  );
  if (r.status === 0) {
    return { keep: false, reason: `present on ${baseBranch}` };
  }
  // Also try without origin/ prefix (local branch).
  const r2 = spawnSync(
    "git", ["cat-file", "-e", `${baseBranch}:${filePath}`],
    { encoding: "utf8" }
  );
  if (r2.status === 0) {
    return { keep: false, reason: `present on ${baseBranch}` };
  }
  return { keep: true, reason: null };
}

// ---------------------------------------------------------------------------
// Spec ownership conflict detection
//
// For a given SPEC-NNN, scan all open PRs and find which ones contain a file
// matching that spec ID in their diff. Returns an array of matching PRs:
//   [{ prNumber: 1357, branch: "claude/issue-1330" }, ...]
// ---------------------------------------------------------------------------
function getOpenPRs() {
  // Wrap the gh call so an auth/network failure surfaces as exit 2 (a
  // configuration error) rather than propagating an uncaught throw that the
  // top-level catch would report as exit 1 — the SAME code as "conflict
  // detected", which would make a broken gh look like a real conflict and
  // silently abort dispatch for the wrong reason.
  try {
    return ghJson(
      "pr", "list",
      "--state", "open",
      "--json", "number,headRefName",
      ...repoFlag
    ); // [{ number, headRefName }, ...]
  } catch (err) {
    console.error(`error: could not list open PRs via gh: ${err.message}`);
    process.exit(2);
  }
}

// Pure: validate a --spec-ids token and compile a boundary-anchored,
// case-insensitive matcher. Rejects anything not shaped SPEC-<digits> so a
// short/typo'd token (e.g. "SPEC-5") can never substring-match a longer id
// ("SPEC-057"), and a value with regex metacharacters can never reach the
// RegExp constructor (closes the regex-injection vector). The digits are
// matched literally and bounded on both sides by a path separator, underscore,
// hyphen, or string edge — and MUST NOT be followed by another digit.
// Throws on an invalid token; the caller turns that into a usage error.
export function specIdToMatcher(specId) {
  const m = /^SPEC-(\d+)$/i.exec(specId.trim());
  if (!m) {
    throw new Error(
      `invalid spec id "${specId}" — expected SPEC-<number> (e.g. SPEC-057)`
    );
  }
  const digits = m[1];
  // Left boundary: start or a non-alphanumeric separator. Right boundary: the
  // digits are not immediately followed by another digit.
  const pattern = new RegExp(`(^|[^0-9A-Za-z])SPEC[_-]${digits}(?![0-9])`, "i");
  return { specId: `SPEC-${digits}`, pattern };
}

// Pure: given a spec matcher and a map of prNumber -> {branch, files[]},
// return the PRs whose diff contains a file matching the spec. Separated from
// I/O so it is unit-testable without gh.
export function findSpecOwners(matcher, prDiffs) {
  const matchingPRs = [];
  for (const { prNumber, branch, files } of prDiffs) {
    if (files.some((f) => matcher.pattern.test(f))) {
      matchingPRs.push({ prNumber, branch });
    }
  }
  return matchingPRs;
}

// Fetch every open PR's changed-file list ONCE (not once per spec — that was
// N specs x M PRs gh calls, re-downloading the same diffs and burning the
// shared gh REST budget). Returns { prDiffs, warnings } where warnings names
// any PR whose diff could not be fetched (surfaced, not silently dropped).
function fetchPrDiffs(openPRs) {
  const prDiffs = [];
  const warnings = [];
  for (const pr of openPRs) {
    const out = spawnSync(
      "gh",
      ["pr", "diff", String(pr.number), "--name-only", ...repoFlag],
      { encoding: "utf8" }
    );
    if (out.status !== 0) {
      warnings.push(
        `warning: could not fetch diff for PR #${pr.number} — skipped (conflict check may be incomplete)`
      );
      continue;
    }
    const files = out.stdout.trim().split("\n").filter(Boolean);
    prDiffs.push({ prNumber: pr.number, branch: pr.headRefName, files });
  }
  return { prDiffs, warnings };
}

// ---------------------------------------------------------------------------
// Wave manifest reader
// Resolves path relative to repo root (two levels up from scripts/).
// ---------------------------------------------------------------------------
function readWaveManifest() {
  const scriptDir = dirname(fileURLToPath(import.meta.url));
  const manifestPath = join(scriptDir, "..", "docs", "bdd-wave-manifest.yaml");

  if (!existsSync(manifestPath)) {
    return null;
  }

  const raw = readFileSync(manifestPath, "utf8");
  return raw;
}

// Minimal YAML parser for the wave manifest format (no external deps).
// Handles ONLY this exact flow-style shape: "wave: N" and, under
// "assignments:", '  "#NNN": [SPEC-X, ...]' entries. It deliberately does NOT
// understand block-list style, anchors, or multi-line values — so rather than
// silently dropping an unrecognised line (which would under-report claimed
// specs and quietly weaken the very conflict check this backs), it THROWS on
// any non-blank, non-comment line under `assignments:` that is not a valid
// entry. The caller turns that into a loud exit. Exported for unit testing.
export function parseWaveManifest(raw) {
  let wave = null;
  const assignments = {};
  let inAssignments = false;

  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (trimmed.startsWith("#") || trimmed === "") continue;

    const waveMatch = trimmed.match(/^wave:\s*(\d+)/);
    if (waveMatch) {
      wave = Number(waveMatch[1]);
      continue;
    }

    if (trimmed === "assignments:") {
      inAssignments = true;
      continue;
    }

    if (inAssignments) {
      // Match: "#1330": [SPEC-052, SPEC-057, ...]  (with or without quotes)
      const entryMatch = line.match(/^\s+"?#(\d+)"?\s*:\s*\[([^\]]*)\]/);
      if (entryMatch) {
        const prNum = `#${entryMatch[1]}`;
        const specs = entryMatch[2].split(",").map((s) => s.trim()).filter(Boolean);
        assignments[prNum] = specs;
        continue;
      }
      // An unrecognised line under assignments: means the manifest uses a shape
      // this minimal parser cannot read. Fail loudly instead of under-reporting.
      throw new Error(
        `unrecognised manifest line under assignments: (this parser supports only ` +
        `'"#NNN": [SPEC-X, ...]' flow style): ${line.trim()}`
      );
    }
    // A non-blank line before `assignments:` that is not `wave:` is also
    // unexpected for this fixed format.
    throw new Error(`unrecognised manifest line: ${trimmed}`);
  }

  return { wave, assignments };
}

// Read + parse the manifest, turning a parser throw into a loud exit 1 rather
// than a silent under-count. Returns null when the file is absent so callers
// can decide whether that is fatal.
function loadWaveManifest() {
  const raw = readWaveManifest();
  if (!raw) return null;
  try {
    return parseWaveManifest(raw);
  } catch (err) {
    console.error(`error: failed to parse docs/bdd-wave-manifest.yaml: ${err.message}`);
    process.exit(1);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

// -- BDD wave manifest mode (standalone, exits early) -----------------------
if (isMain && waveManifestMode && specIds.length === 0 && issueNums.length === 0 && filePaths.length === 0) {
  const parsed = loadWaveManifest();
  if (!parsed) {
    console.error("error: docs/bdd-wave-manifest.yaml not found");
    process.exit(1);
  }

  const { wave, assignments } = parsed;
  const allClaimed = Object.values(assignments).flat();

  if (jsonMode) {
    console.log(JSON.stringify({ wave, assignments, allClaimed, stats: { total: allClaimed.length } }, null, 2));
  } else {
    console.log(`BDD wave manifest — wave ${wave ?? "?"} — ${allClaimed.length} spec(s) claimed`);
    for (const [pr, specs] of Object.entries(assignments)) {
      console.log(`  ${pr.padEnd(8)}  ${specs.join(", ")}`);
    }
  }
  process.exit(0);
}

// -- Spec-ids mode ----------------------------------------------------------
if (isMain && specIds.length > 0) {
  // Validate every token up front (before any gh call) so a malformed id fails
  // fast as a usage error rather than after network work.
  const matchers = [];
  for (const specId of specIds) {
    try {
      matchers.push(specIdToMatcher(specId));
    } catch (err) {
      console.error(`error: ${err.message}`);
      process.exit(1);
    }
  }

  const openPRs = getOpenPRs();
  const { prDiffs, warnings } = fetchPrDiffs(openPRs);
  for (const w of warnings) console.error(w);

  const conflicts = [];
  const clean = [];

  for (const matcher of matchers) {
    const matches = findSpecOwners(matcher, prDiffs);
    if (matches.length > 1) {
      // Conflict: appears in more than one open PR
      for (const m of matches) {
        conflicts.push({ specId: matcher.specId, prNumber: m.prNumber, branch: m.branch });
      }
    } else {
      clean.push(matcher.specId);
    }
  }

  const stats = {
    total: specIds.length,
    conflicts: new Set(conflicts.map((c) => c.specId)).size,
    clean: clean.length,
  };

  if (jsonMode) {
    console.log(JSON.stringify({ conflicts, clean, stats }, null, 2));
  } else {
    // Iterate the normalised matcher ids so the display key matches the
    // normalised c.specId recorded in `conflicts` (a raw "spec-057" token
    // would otherwise never equal the stored "SPEC-057").
    for (const { specId } of matchers) {
      const specConflicts = conflicts.filter((c) => c.specId === specId);
      if (specConflicts.length > 0) {
        for (const c of specConflicts) {
          console.log(`CONFLICT  ${specId}  already in PR #${c.prNumber} (${c.branch})`);
        }
      } else {
        console.log(`OK        ${specId}`);
      }
    }
  }

  // Also show manifest claims if --bdd-wave-manifest was also passed
  if (waveManifestMode) {
    const parsed = loadWaveManifest();
    if (parsed) {
      const { wave, assignments } = parsed;
      const allClaimed = Object.values(assignments).flat();
      if (!jsonMode) {
        console.log(`\nWave ${wave} manifest — ${allClaimed.length} spec(s) claimed`);
        for (const [pr, specs] of Object.entries(assignments)) {
          console.log(`  ${pr.padEnd(8)}  ${specs.join(", ")}`);
        }
      }
    }
  }

  process.exit(conflicts.length > 0 ? 1 : 0);
}

// -- Issues / files mode ----------------------------------------------------
// Guarded so importing this module for unit tests runs none of the CLI
// dispatch (the pure functions above are the only import surface).
if (isMain) {
const keepList = [];
const droppedList = [];

// Check issues
for (const num of issueNums) {
  const { keep, reason } = await checkIssue(num);
  if (keep) {
    keepList.push(num);
  } else {
    droppedList.push({ item: num, reason });
  }
}

// Check files
for (const fp of filePaths) {
  const { keep, reason } = checkFile(fp);
  if (keep) {
    keepList.push(fp);
  } else {
    droppedList.push({ item: fp, reason });
  }
}

const total = issueNums.length + filePaths.length;
const stats = {
  total,
  dropped: droppedList.length,
  remaining: keepList.length,
};

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------
if (jsonMode) {
  console.log(JSON.stringify({ keep: keepList, dropped: droppedList, stats }, null, 2));
} else {
  console.log(
    `Reconcile pre-flight: ${stats.total} candidate(s) → ` +
    `${stats.dropped} dropped → ${stats.remaining} remaining`
  );

  // Print issues first, then files, matching the original order.
  const allItems = [
    ...issueNums.map((n) => ({ item: n, type: "issue" })),
    ...filePaths.map((f) => ({ item: f, type: "file" })),
  ];

  for (const { item } of allItems) {
    const dropped = droppedList.find((d) => d.item === item);
    if (dropped) {
      console.log(`DROPPED  ${typeof item === "number" ? `#${item}` : item}  ${dropped.reason}`);
    } else {
      console.log(`KEEP     ${typeof item === "number" ? `#${item}` : item}`);
    }
  }
}
} // end if (isMain) — issues/files mode
