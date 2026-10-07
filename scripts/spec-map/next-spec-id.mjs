#!/usr/bin/env node
// Next free spec id, counting ids reserved at intake (sge#2951).
//
// WHY. Parallel new-spec PRs used to collide on the next id: both took
// "highest on disk + 1", and the second to merge had to renumber (#2939 ->
// SPEC-131). /sge:issue-intake now reserves the id when it records a
// NEEDS_NEW_SPEC issue's decision: it writes `reservedSpecId` into that
// issue's `sge-intake:` marker. This script computes the id to reserve:
//
//   next = max(every spec number on disk, every id reserved by an open
//              issue's newest intake marker) + 1
//
// and, with --issue N, hands back N's own reservation when it already holds one
// that has not landed on disk yet (a re-intake keeps its id).
//
// Spec homes: docs/specs/ (SPEC-NNN) and docs/sgd-build/specs/ (SGD-/SGE-NNN)
// are ONE number line (docs/spec-numbering-supersession-map.md §1), so both
// are scanned; a missing home is simply empty.
//
// Usage:
//   node scripts/spec-map/next-spec-id.mjs [--issue N] [--repo-root DIR]
//        [--issues-json FILE] [--repo owner/repo]
// Without --issues-json it reads open issues' comments through `gh`. Any
// failure to read reservations exits 2 with nothing on stdout: an id computed
// without the reservations could be one somebody already holds.
//
// Dependency-free by repo convention (Node built-ins only).

import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const SPEC_HOMES = ["docs/specs", "docs/sgd-build/specs"];
const MARKER_OPEN = "<!-- sge-intake:";
const ID_RE = /^(?:SPEC|SGD|SGE)-(\d+)$/;

/** Numbers a spec file name claims (handles NNN-to-MMM batch stubs). */
function claimedNumbers(fileName) {
  const range = fileName.match(/^(?:SGD|SGE|SPEC)-(\d+)-to-(\d+)/);
  if (range) {
    const [lo, hi] = [Number(range[1]), Number(range[2])];
    return Array.from({ length: hi - lo + 1 }, (_, i) => lo + i);
  }
  const single = fileName.match(/^(?:SGD|SGE|SPEC)-(\d+)/);
  return single ? [Number(single[1])] : [];
}

/** Every spec number claimed by a file in either spec home, sorted, unique. */
export function specNumbersOnDisk(repoRoot) {
  const nums = new Set();
  for (const home of SPEC_HOMES) {
    const dir = join(repoRoot, home);
    if (!existsSync(dir)) continue;
    for (const f of readdirSync(dir)) {
      if (!/\.md$/.test(f)) continue;
      for (const n of claimedNumbers(f)) nums.add(n);
    }
  }
  return [...nums].sort((a, b) => a - b);
}

/** Parse the JSON of the last `sge-intake:` marker in a comment body, or null. */
function parseMarker(body) {
  if (typeof body !== "string" || !body.includes(MARKER_OPEN)) return null;
  const raw = body.split(MARKER_OPEN).pop().split("-->")[0];
  try {
    const obj = JSON.parse(raw);
    return obj && typeof obj === "object" ? obj : null;
  } catch {
    return null;
  }
}

/**
 * Reservations held by issues: for each issue, its NEWEST intake marker (the one
 * intake-check.sh judges) decides; a newer marker with no reservedSpecId
 * releases an older one. A marker whose `issue` echo names a different issue,
 * or whose id is malformed, holds nothing.
 * @param {{number:number, comments:{body:string, createdAt:string}[]}[]} issues
 * @returns {{issue:number, id:number}[]}
 */
export function reservationsFromIssues(issues) {
  const out = [];
  for (const issue of issues ?? []) {
    const markers = (issue.comments ?? [])
      .map((c) => ({ at: c.createdAt ?? "", m: parseMarker(c.body) }))
      .filter((x) => x.m)
      .sort((a, b) => (a.at < b.at ? -1 : a.at > b.at ? 1 : 0));
    const newest = markers.at(-1)?.m;
    if (!newest || Number(newest.issue) !== Number(issue.number)) continue;
    const m = typeof newest.reservedSpecId === "string" ? newest.reservedSpecId.match(ID_RE) : null;
    if (m) out.push({ issue: Number(issue.number), id: Number(m[1]) });
  }
  return out;
}

/**
 * The id to reserve. With `issue`, that issue's own reservation is returned
 * when it still names a number not yet on disk.
 */
export function nextSpecId({ existing, reserved, issue }) {
  const onDisk = new Set(existing);
  if (issue != null) {
    const own = reserved.find((r) => r.issue === Number(issue) && !onDisk.has(r.id));
    if (own) return own.id;
  }
  const all = [...existing, ...reserved.map((r) => r.id)];
  return all.length ? Math.max(...all) + 1 : 1;
}

export const formatSpecId = (n) => `SPEC-${String(n).padStart(3, "0")}`;

function readIssuesViaGh(repo) {
  const args = ["issue", "list", "--state", "open", "--limit", "1000",
    "--search", "sge-intake in:comments", "--json", "number,comments"];
  if (repo) args.push("--repo", repo);
  const json = execFileSync("gh", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  return JSON.parse(json);
}

function main(argv) {
  const opts = { repoRoot: join(dirname(fileURLToPath(import.meta.url)), "..", "..") };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`${a} needs a value`);
      return v;
    };
    if (a === "--issue") opts.issue = Number(val());
    else if (a === "--repo-root") opts.repoRoot = val();
    else if (a === "--issues-json") opts.issuesJson = val();
    else if (a === "--repo") opts.repo = val();
    else throw new Error(`unknown argument: ${a}`);
  }
  if (opts.issue != null && !Number.isInteger(opts.issue)) throw new Error("--issue must be an issue number");
  let issues;
  try {
    issues = opts.issuesJson ? JSON.parse(readFileSync(opts.issuesJson, "utf8")) : readIssuesViaGh(opts.repo);
    if (!Array.isArray(issues)) throw new Error("issues source is not a JSON array");
  } catch (e) {
    throw new Error(`cannot read intake reservations: ${e.message}`);
  }
  const id = nextSpecId({
    existing: specNumbersOnDisk(opts.repoRoot),
    reserved: reservationsFromIssues(issues),
    issue: opts.issue,
  });
  process.stdout.write(formatSpecId(id) + "\n");
}

if (process.argv[1] && resolve(fileURLToPath(import.meta.url)) === resolve(process.argv[1])) {
  try {
    main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`next-spec-id: ${e.message}\n`);
    process.exit(2);
  }
}
