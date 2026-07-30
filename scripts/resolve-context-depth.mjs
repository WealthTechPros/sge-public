#!/usr/bin/env node
/**
 * resolve-context-depth.mjs — complexity-tiered context depth for
 * `/sgd:sgd-preflight` and `/sgd:sgd-implement` (#809, epic #785 S2).
 *
 * Pure function over a change's touched paths (and optional complexity score):
 * paths in, a context-DEPTH decision out. It answers the question "how deep
 * should governance context be read for this change?" *before* the
 * path-scoped resolver (#807, `resolve-context-scope.mjs`) is even consulted,
 * so deeper context loads only for higher-complexity / higher-risk work:
 *
 *   - `trivial`  -> depth `digest`  — docs/config-only, low-complexity change.
 *                  The generated digest (#805) suffices; the scope resolver is
 *                  not needed (nothing to deep-read).
 *   - `standard` -> depth `scoped`  — a code change. Read the digest, then the
 *                  path-scoped specs/ADRs `resolve-context-scope.mjs` returns.
 *                  This is the default and the safe middle.
 *   - `critical` -> depth `full`    — the change touches a CRITICAL path
 *                  (security/auth, database migrations, or multi-tenant /
 *                  data-isolation boundaries — the *same* list
 *                  `agents/agent-registry.md` escalates to `opus`). Read the
 *                  full L0-L8 artefact stack; scoping is DELIBERATELY bypassed.
 *
 * Non-goal guard (epic #785; issue #809): CRITICAL-path context must NEVER be
 * thinned. CRITICAL classification wins over every other signal — a one-line
 * YAML tweak to an auth policy, or a "small" migration edit, still reads the
 * full stack. The mapping only ever *narrows* reads for demonstrably-trivial
 * or standard work; it can never down-depth a CRITICAL path.
 *
 * Fail toward inclusion (matching `resolve-context-scope.mjs`): an unclassified
 * or empty path set degrades to `standard`/`scoped`, never `trivial`/`digest`.
 * The mapping never under-reads governance it cannot reason about.
 *
 * CLI:
 *   node scripts/resolve-context-depth.mjs \
 *     --paths "platform/src/auth/session.ts,docs/x.md" [--score 12] [more paths...]
 *
 * Prints the result as JSON on stdout. Exit codes: 0 resolved · 2 usage error.
 * Dependency-free (Node >= 18), repo convention for scripts/*.mjs.
 */

/** Normalise a repo-relative path: `\` -> `/`, strip leading `./` and `/`,
 * collapse duplicate slashes, drop a trailing slash, lowercase for matching
 * is handled per-pattern (patterns are case-insensitive). */
function normalisePath(p) {
  let s = String(p).replace(/\\/g, "/").replace(/\/{2,}/g, "/");
  s = s.replace(/^\.\//, "").replace(/^\//, "");
  return s.replace(/\/+$/, "");
}

// CRITICAL-path patterns — kept deliberately aligned with the CRITICAL
// escalation rule in `agents/agent-registry.md`: "security/auth, database
// migrations, or multi-tenant / data-isolation boundaries". Matching is on
// path segments / filenames. Over-matching here is SAFE (it only ever reads
// *more* context); under-matching would breach the non-goal guard, so the
// terms err toward inclusion.
const CRITICAL_RE = [
  // security / auth
  /(^|\/)(auth|authn|authz|security|login|logout|signin|signup|session|sessions|credential|credentials|secret|secrets|oauth|oidc|saml|sso|rbac|password|passwords|permission|permissions)([/._-]|$)/i,
  // database migrations
  /(^|\/)migrations?(\/|$)/i,
  /(^|\/)migrate([/._-]|$)/i,
  // multi-tenant / data-isolation boundaries
  /(^|\/)(tenant|tenants|tenancy|multitenant|multi-tenant|data-isolation)([/._-]|$)/i,
];

// Trivial-path patterns — documentation, tests, and configuration. A change
// confined to these (and not otherwise CRITICAL, and not a large-complexity
// change) is covered by the digest alone.
//
// Exported as `TRIVIAL` so governance-trace and other callers can reference
// the canonical pattern set without re-deriving it.
export const TRIVIAL = [
  // documentation
  /^docs\//i,
  /^documentation\//i,
  /\.(md|mdx|markdown|rst|txt|adoc)$/i,
  // tests — *.test.*, *.spec.*, tests/ and __tests__/ directories, specs/ dir
  /\.(test|spec)\.[cm]?[jt]sx?$/i,
  /(^|\/)(tests?|__tests__|specs?)\//i,
  // configuration
  /\.(json|ya?ml|toml|ini|cfg|conf|env|properties|lock)$/i,
];

// Keep the internal alias for backward-compat within this module.
const TRIVIAL_RE = TRIVIAL;

// A trivial-tier change must also be genuinely small. A docs/config-only diff
// with a high complexity score (e.g. a large config-driven surface) is treated
// as `standard`, not `trivial`. Mirrors the sgd-implement Phase 2 rubric
// (<= 15 == Small).
const TRIVIAL_SCORE_MAX = 15;

const classifyPath = (p) => {
  if (CRITICAL_RE.some((re) => re.test(p))) return "critical";
  if (TRIVIAL_RE.some((re) => re.test(p))) return "trivial";
  return "standard";
};

/**
 * Map a change's touched paths (+ optional complexity score) to a context
 * depth.
 *
 * @param {{paths?: string[], complexityScore?: number|null}} [input]
 * @returns {{
 *   depth: "digest"|"scoped"|"full",
 *   tier: "trivial"|"standard"|"critical",
 *   reason: string,
 *   paths: string[],
 *   criticalPaths: string[],
 *   complexityScore: number|null,
 *   classifications: {path: string, class: "trivial"|"standard"|"critical"}[]
 * }}
 */
export function resolveContextDepth(input = {}) {
  const { paths = [], complexityScore = null } = input || {};
  const norm = (paths || []).map(normalisePath).filter(Boolean);
  const score =
    complexityScore === null ||
    complexityScore === undefined ||
    Number.isNaN(Number(complexityScore))
      ? null
      : Number(complexityScore);

  const classifications = norm.map((path) => ({ path, class: classifyPath(path) }));
  const criticalPaths = classifications
    .filter((c) => c.class === "critical")
    .map((c) => c.path)
    .sort();

  const base = {
    paths: norm,
    criticalPaths,
    complexityScore: score,
    classifications,
  };

  // 1. CRITICAL wins over everything — never thinned (non-goal guard).
  if (criticalPaths.length > 0) {
    return {
      ...base,
      tier: "critical",
      depth: "full",
      reason: `CRITICAL path(s) touched (${criticalPaths.join(
        ", "
      )}) — full L0-L8 read, scoping deliberately bypassed`,
    };
  }

  // 2. Empty / unknown path set — cannot classify; fail toward inclusion.
  if (norm.length === 0) {
    return {
      ...base,
      tier: "standard",
      depth: "scoped",
      reason: "no paths supplied — path-scoped read (resolver fail-safe applies)",
    };
  }

  // 3. Trivial: every path is docs/config AND the change is genuinely small.
  const allTrivial = classifications.every((c) => c.class === "trivial");
  const smallEnough = score === null || score <= TRIVIAL_SCORE_MAX;
  if (allTrivial && smallEnough) {
    return {
      ...base,
      tier: "trivial",
      depth: "digest",
      reason: "docs/config-only, low-complexity change — digest suffices",
    };
  }

  // 4. Standard: everything else.
  return {
    ...base,
    tier: "standard",
    depth: "scoped",
    reason: allTrivial
      ? `docs/config-only but complexity ${score} > ${TRIVIAL_SCORE_MAX} — digest + path-scoped specs/ADRs`
      : "code change — digest + path-scoped specs/ADRs",
  };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const USAGE = `Usage: node scripts/resolve-context-depth.mjs [--paths "a,b,c"] [--score N] [path ...]

Maps a change's touched paths (+ optional complexity score) to a context
DEPTH for /sgd:sgd-preflight and /sgd:sgd-implement:
  trivial  -> digest  (docs/config-only, low complexity)
  standard -> scoped  (code change: digest + resolve-context-scope specs/ADRs)
  critical -> full    (security/auth, DB migration, or multi-tenant path: full L0-L8, never thinned)

Prints JSON: { depth, tier, reason, paths[], criticalPaths[], classifications[] }.
Exit codes: 0 resolved · 2 usage error.`;

function main(argv) {
  const paths = [];
  let score = null;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      console.log(USAGE);
      return 0;
    } else if (arg === "--paths") {
      const v = argv[++i];
      if (v) paths.push(...v.split(",").map((s) => s.trim()).filter(Boolean));
    } else if (arg === "--score") {
      const v = argv[++i];
      if (v === undefined) {
        console.error(`Missing value for --score\n\n${USAGE}`);
        return 2;
      }
      const n = Number(v);
      if (Number.isNaN(n)) {
        console.error(`--score must be a number, got "${v}"\n\n${USAGE}`);
        return 2;
      }
      score = n;
    } else if (arg.startsWith("--")) {
      console.error(`Unknown option: ${arg}\n\n${USAGE}`);
      return 2;
    } else {
      paths.push(arg);
    }
  }
  console.log(
    JSON.stringify(resolveContextDepth({ paths, complexityScore: score }), null, 2)
  );
  return 0;
}

if (
  import.meta.url === `file://${process.argv[1]}` ||
  process.argv[1]?.endsWith("resolve-context-depth.mjs")
) {
  process.exit(main(process.argv.slice(2)));
}
