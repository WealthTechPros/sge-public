#!/usr/bin/env node
/**
 * resolve-context-scope.mjs — path-scoped spec/ADR selection over a WTP DAG
 * manifest (#807, epic #785 S1: cheap governance context).
 *
 * Pure function over the DAG manifest: paths in, artefact list out. Given the
 * set of repo-relative paths a change touches, resolve which specs and ADRs
 * actually govern them, so `/sgd:sgd-preflight` and `/sgd:sgd-implement` load
 * only those (plus the generated digest, #805) instead of the full L0–L8
 * artefact stack. An ADR about the payments adapter is never loaded for a
 * docs-site PR.
 *
 * Scope model (WTP DAG schema v1 + optional `scope`):
 *   - Any node MAY carry `scope: ["<glob>", ...]` — path globs the node
 *     governs. Artefact nodes are those with `type: "spec"` or `type: "adr"`
 *     (`"decision"` accepted as an alias, normalised to `adr` on output).
 *   - An artefact's EFFECTIVE scope is the union of its own `scope` and every
 *     ancestor's (walked upward via `edges`, from → to) — so a spec under a
 *     capability scoped to `platform/payments/**` inherits that scope without
 *     re-declaring it. Union (not narrowing) errs toward inclusion.
 *   - An artefact with an empty effective scope is GLOBAL: always selected.
 *     Scoping narrows deep reads; it never drops universal governance
 *     (e.g. "UK regions only").
 *
 * Fail-safe degradation (epic #785's "zero reduction in gate coverage"):
 *   - Manifest carries no scope data anywhere, or the path set is empty →
 *     the FULL artefact list is returned with `scoped: false`. The resolver
 *     never silently thins governance it cannot reason about; callers stay
 *     digest-first and follow links on demand.
 *
 * Glob subset (documented, deliberately small):
 *   `**` crosses `/`; `*` matches within a segment; `?` one non-`/` char;
 *   a pattern with no wildcard is a bare prefix (`docs-site` covers
 *   `docs-site` and everything under it, never `docs-sitex`); `dir/**` also
 *   matches `dir` itself. Input paths and patterns are normalised (`\` → `/`,
 *   leading `./` stripped) before matching.
 *
 * CLI:
 *   node scripts/resolve-context-scope.mjs --dag docs/sgd-dag.json \
 *     --paths "platform/payments/adapter.ts,docs/x.md" [more paths...]
 *
 * Prints the result as JSON on stdout. Exit codes: 0 resolved ·
 * 2 usage error or missing/unreadable/malformed manifest (fail-loud — never
 * exit 0 on a guess). Dependency-free (Node ≥ 18), repo convention for
 * scripts/*.mjs.
 */
import { readFileSync } from "node:fs";

// `decision` is accepted as an alias for `adr` (some generators emit ADR
// nodes under that name); normalised to `adr` on output.
const ARTEFACT_TYPES = { spec: "spec", adr: "adr", decision: "adr" };

/** Normalise a repo-relative path or glob: `\` → `/`, strip leading `./` and
 * `/`, collapse duplicate slashes, drop a trailing slash. */
function normalisePath(p) {
  let s = String(p).replace(/\\/g, "/").replace(/\/{2,}/g, "/");
  s = s.replace(/^\.\//, "").replace(/^\//, "");
  return s.replace(/\/+$/, "");
}

const RE_SPECIALS = /[.+^${}()|[\]]/g;
const escapeRe = (s) => s.replace(RE_SPECIALS, "\\$&");

/** Compile one scope glob (see the documented subset above) to a RegExp. */
function globToRegExp(glob) {
  const g = normalisePath(glob);
  if (!/[*?]/.test(g)) {
    // Bare prefix: the path itself, or anything under it as a directory.
    return new RegExp(`^${escapeRe(g)}(?:/.*)?$`);
  }
  let re = "";
  let i = 0;
  while (i < g.length) {
    const c = g[i];
    if (c === "*") {
      if (g[i + 1] === "*") {
        i += 2;
        if (i >= g.length && re.endsWith("/")) {
          // Trailing `dir/**` also matches `dir` itself.
          re = re.slice(0, -1) + "(?:/.*)?";
        } else if (g[i] === "/") {
          // `**/` — zero or more whole segments.
          re += "(?:.*/)?";
          i += 1;
        } else {
          re += ".*";
        }
      } else {
        re += "[^/]*";
        i += 1;
      }
    } else if (c === "?") {
      re += "[^/]";
      i += 1;
    } else {
      re += escapeRe(c);
      i += 1;
    }
  }
  return new RegExp(`^${re}$`);
}

/**
 * Resolve which spec/ADR artefacts in `dag` govern the given paths.
 *
 * @param {{nodes?: object[], edges?: object[]}} dag - WTP DAG schema v1
 *   manifest (optionally with per-node `scope` glob arrays).
 * @param {string[]} paths - repo-relative paths the change touches.
 * @returns {{scoped: boolean, paths: string[],
 *   artefacts: {id:string,type:string,name:string,path:string|null,reason:string}[],
 *   excluded: {id:string,type:string,name:string,path:string|null,reason:string}[]}}
 */
export function resolveContextScope(dag, paths) {
  // Tolerate null/non-object entries in a hand-edited manifest — a junk node
  // must degrade (be ignored), never crash the resolver mid-scope-decision.
  const nodes = (Array.isArray(dag?.nodes) ? dag.nodes : []).filter(
    (n) => n && typeof n === "object"
  );
  const edges = Array.isArray(dag?.edges) ? dag.edges : [];
  const inputPaths = (paths || []).map(normalisePath).filter(Boolean);

  // Only non-blank string globs count as scope. A whitespace-only entry
  // compiles to an unmatchable pattern that would SILENTLY exclude the
  // artefact from every resolution — exactly the fail-safe breach this
  // resolver exists to prevent — so junk entries are dropped (the node
  // stays global) rather than matched.
  const nodeScope = (n) =>
    Array.isArray(n?.scope)
      ? n.scope
          .filter((s) => typeof s === "string")
          .map((s) => s.trim())
          .filter(Boolean)
      : [];
  const hasScopeData = nodes.some((n) => nodeScope(n).length > 0);

  // parent lookup: edge.from is the parent of edge.to.
  const parentsOf = new Map();
  for (const e of edges) {
    if (!e?.from || !e?.to) continue;
    if (!parentsOf.has(e.to)) parentsOf.set(e.to, []);
    parentsOf.get(e.to).push(e.from);
  }
  const byId = new Map(nodes.map((n) => [n.id, n]));

  /** Union of the node's own scope and every ancestor's (cycle-safe). */
  function effectiveScope(node) {
    const out = new Set(nodeScope(node));
    const seen = new Set([node.id]);
    const queue = [...(parentsOf.get(node.id) || [])];
    while (queue.length) {
      const id = queue.shift();
      if (seen.has(id)) continue;
      seen.add(id);
      const parent = byId.get(id);
      if (parent) for (const s of nodeScope(parent)) out.add(s);
      queue.push(...(parentsOf.get(id) || []));
    }
    return [...out];
  }

  const artefactNodes = nodes
    .filter((n) => n?.id && ARTEFACT_TYPES[n.type])
    .map((n) => ({
      node: n,
      out: {
        id: n.id,
        type: ARTEFACT_TYPES[n.type],
        name: n.name || n.id,
        path: n.file ?? n.path ?? null,
      },
    }));

  const scoped = hasScopeData && inputPaths.length > 0;
  const artefacts = [];
  const excluded = [];

  if (!scoped) {
    const reason =
      inputPaths.length === 0
        ? "no paths supplied — full governance read"
        : "manifest carries no scope data — full governance read";
    for (const { out } of artefactNodes) artefacts.push({ ...out, reason });
  } else {
    for (const { node, out } of artefactNodes) {
      const scope = effectiveScope(node);
      if (scope.length === 0) {
        artefacts.push({ ...out, reason: "global — no scope declared" });
        continue;
      }
      const regexps = scope.map(globToRegExp);
      const hit = inputPaths.find((p) => regexps.some((re) => re.test(p)));
      if (hit) {
        artefacts.push({ ...out, reason: `scope matches ${hit}` });
      } else {
        excluded.push({
          ...out,
          reason: `scope [${scope.join(", ")}] does not intersect the changed paths`,
        });
      }
    }
  }

  const byTypeThenId = (a, b) =>
    a.type === b.type ? a.id.localeCompare(b.id) : a.type.localeCompare(b.type);
  artefacts.sort(byTypeThenId);
  excluded.sort(byTypeThenId);

  return { scoped, paths: inputPaths, artefacts, excluded };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const USAGE = `Usage: node scripts/resolve-context-scope.mjs --dag <sgd-dag.json> [--paths "a,b,c"] [path ...]

Resolves which spec/ADR artefacts in the DAG manifest govern the given
repo-relative paths. Prints JSON: { scoped, paths, artefacts[], excluded[] }.
Exit codes: 0 resolved · 2 usage/manifest error.`;

function main(argv) {
  let dagPath = null;
  const paths = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      console.log(USAGE);
      return 0;
    } else if (arg === "--dag") {
      dagPath = argv[++i];
    } else if (arg === "--paths") {
      const v = argv[++i];
      if (v) paths.push(...v.split(",").map((s) => s.trim()).filter(Boolean));
    } else if (arg.startsWith("--")) {
      console.error(`Unknown option: ${arg}\n\n${USAGE}`);
      return 2;
    } else {
      paths.push(arg);
    }
  }
  if (!dagPath) {
    console.error(`Missing required --dag <sgd-dag.json>\n\n${USAGE}`);
    return 2;
  }
  let dag;
  try {
    dag = JSON.parse(readFileSync(dagPath, "utf8"));
  } catch (err) {
    // Fail loud (repo convention): a missing or unparsable manifest must
    // never look like a successful (or empty) resolution.
    console.error(`Cannot read DAG manifest at ${dagPath}: ${err.message}`);
    return 2;
  }
  console.log(JSON.stringify(resolveContextScope(dag, paths), null, 2));
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("resolve-context-scope.mjs")) {
  process.exit(main(process.argv.slice(2)));
}
