#!/usr/bin/env node
/**
 * issue-prescorer.mjs — lightweight Phase 2 sizing pre-score for
 * `/sge:sge-implement` Phase 0.5 (#1342, extends SPEC-060 / SPEC-061).
 *
 * Problem: large issues pay the full ~75k-token governance-trace fork cost
 * on the *parent*, the sizing gate then declares them Large, decomposition
 * is triggered, and each child re-classifies — the parent fork is wasted.
 * This module runs a cheap heuristic (≤ 500 tokens of inline work, no fork,
 * no preflight) over the raw issue body BEFORE any governance work, to detect
 * likely-Large issues and route them straight to decomposition.
 *
 * Applies the same rubric Phase 2 uses (signals × weights):
 *
 *   signal                           weight
 *   ─────────────────────────────────────────
 *   DB tables / data models           × 3
 *   Service / module methods          × 1
 *   API routes / endpoints            × 2
 *   Acceptance-criteria scenarios     × 1
 *
 *   score = (models×3) + (methods×1) + (routes×2) + (scenarios×1)
 *
 * Tiers (with a ±5 confidence margin around the Large threshold of 30):
 *
 *   SMALL      score ≤ 15            — clearly small
 *   MEDIUM     16 ≤ score < 25       — medium, not near Large boundary
 *   AMBIGUOUS  25 ≤ score ≤ 35       — borderline; fall back to full gate
 *   LARGE      score > 35            — confidently large; decompose first
 *
 * The AMBIGUOUS tier is intentional: when the score is near the Large/Medium
 * boundary (30 ± 5), extraction uncertainty means we cannot be confident
 * which side the true score falls on.  Falling back to the normal
 * sizing + governance sequence avoids false early decomposition.
 *
 * CLI (accepts issue body via --body flag or stdin):
 *
 *   node skills/lib/issue-prescorer.mjs --body "<issue body text>"
 *   gh issue view 123 --json body --jq .body | node skills/lib/issue-prescorer.mjs
 *
 * Prints JSON on stdout:
 *   { tier, score, signals: { models, methods, routes, scenarios }, reason }
 *
 * Exit codes: 0 success · 2 usage error.
 * Dependency-free (Node ≥ 18), repo convention for lib/*.mjs.
 */

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Phase 2 rubric weights (kept in sync with sge-implement SKILL.md Phase 2). */
const WEIGHTS = { models: 3, methods: 1, routes: 2, scenarios: 1 };

/** Phase 2 tier thresholds. */
const SMALL_MAX = 15;
const LARGE_MIN = 30;

/** Confidence margin: scores within ±MARGIN of the Large boundary are AMBIGUOUS. */
const MARGIN = 5;

/**
 * Hard cap on the body text scored (bytes/chars). Issue bodies are UNTRUSTED
 * input with no upstream size limit — a pasted stack trace or minified blob
 * must never let signal extraction dominate the pre-score gate's runtime. This
 * is a heuristic pre-scorer: the sizing signals (AC count, model/route/method
 * mentions) live in the issue's own prose, which is well within 32 KB; anything
 * beyond that is pasted noise, not sizing signal, so truncating it changes no
 * legitimate score while bounding worst-case regex cost.
 */
const MAX_BODY_CHARS = 32 * 1024;

// ---------------------------------------------------------------------------
// Signal extractors
// ---------------------------------------------------------------------------

/**
 * Count lines that are a Markdown bullet AND contain any of `keywordRe`.
 *
 * Split-then-test instead of `^[-*•]\s+.*\b(?:kw)\b` in one `.match(/…/gm)`:
 * the greedy `.*` before a `\b(?:…)\b` alternation backtracks quadratically on
 * a long bulleted line that never matches a keyword, so a single pasted line in
 * an UNTRUSTED issue body could hang the pre-score gate. Testing a bullet prefix
 * and a keyword presence separately, per line, is linear in the body length and
 * has no unbounded backtracking. An optional `prefixRe` (already anchored, no
 * `.*`) gates lines that must also open with a lead verb (e.g. add/create/new).
 *
 * @param {string} body
 * @param {RegExp} keywordRe  keyword alternation, tested with .test (no /g state)
 * @param {RegExp} [prefixRe] optional lead-verb gate applied to the bullet content
 * @returns {number}
 */
const BULLET_RE = /^[ \t]*[-*•]\s+(.*)$/;
function countBulletLines(body, keywordRe, prefixRe) {
  let n = 0;
  for (const line of body.split("\n")) {
    const m = BULLET_RE.exec(line);
    if (!m) continue;
    const content = m[1];
    if (prefixRe && !prefixRe.test(content)) continue;
    if (keywordRe.test(content)) n++;
  }
  return n;
}

/**
 * Count Gherkin-style acceptance-criteria scenarios.
 *
 * Counts each "Given" that introduces a scenario block (typically the first
 * step of a Given/When/Then triple).  Also counts Markdown checkbox ACs
 * ("- [ ] Given …" or "- [ ] …" inside an Acceptance Criteria section) and
 * bare "Scenario:" headings.
 *
 * @param {string} body
 * @returns {number}
 */
function countScenarios(body) {
  // Each "Given" at the start of a line (with optional checkbox prefix) signals
  // one scenario.  We deduplicate by assuming each "Given" is a unique scenario
  // opener; this is conservative (one scenario may have multiple Given steps).
  const givenLines = (body.match(/^[ \t]*(?:[-*]\s*\[[ xX]\]\s*)?\bGiven\b/gim) || []).length;

  // "Scenario:" or "Scenario Outline:" headers (BDD feature files / rich specs)
  const scenarioHeaders = (body.match(/^\s*Scenario(?:\s+Outline)?:/gim) || []).length;

  // Plain "- [ ]" checkboxes inside an explicit "## Acceptance Criteria" section.
  // Extract that section first to avoid counting unrelated checkboxes.
  const acSectionMatch = body.match(
    /##\s*Acceptance\s+Criteria\b([\s\S]*?)(?=\n##|\n---|\n___|\n\*\*\*|$)/i
  );
  const acSection = acSectionMatch ? acSectionMatch[1] : "";
  const acCheckboxes = (acSection.match(/^[ \t]*[-*]\s*\[[ xX]\]/gim) || []).length;

  // Return the best signal: prefer Given-line count when we found any, then
  // scenario headers, then raw AC checkboxes.
  if (givenLines > 0) return givenLines;
  if (scenarioHeaders > 0) return scenarioHeaders;
  return acCheckboxes;
}

/**
 * Count data-model signals (DB tables, ORM models, schemas, entities).
 *
 * First looks for explicit "N models/tables/…" counts in the text; if found,
 * sums them.  Falls back to counting bullet points that mention model-creating
 * keywords.
 *
 * @param {string} body
 * @returns {number}
 */
function countModels(body) {
  // Explicit "3 new tables", "2 models", etc.
  const explicitMatches = [
    ...body.matchAll(
      /\b(\d+)\s+(?:new\s+)?(?:db\s+)?(?:tables?|models?|schemas?|entities|entity|migrations?)\b/gi
    ),
  ];
  if (explicitMatches.length > 0) {
    return explicitMatches.reduce((sum, m) => sum + parseInt(m[1], 10), 0);
  }

  // Bullet / list items mentioning model-creation keywords.
  const bulletModelLines = countBulletLines(
    body,
    /\b(?:table|model|schema|entity|entities|migration|data\s+model|db\s+table|database\s+table)\b/i
  );

  return bulletModelLines;
}

/**
 * Count API-route signals.
 *
 * Looks for HTTP-verb + path patterns (most reliable), then explicit "N routes"
 * counts, then bullet items mentioning endpoint/route keywords.
 *
 * @param {string} body
 * @returns {number}
 */
function countRoutes(body) {
  // HTTP verb + path: "GET /api/users", "POST /v1/foo"
  const verbPaths = (body.match(/\b(?:GET|POST|PUT|DELETE|PATCH|HEAD)\s+\/\S+/g) || []).length;
  if (verbPaths > 0) return verbPaths;

  // Explicit "3 endpoints", "2 routes", etc.
  const explicitMatches = [
    ...body.matchAll(/\b(\d+)\s+(?:new\s+)?(?:routes?|endpoints?|APIs?)\b/gi),
  ];
  if (explicitMatches.length > 0) {
    return explicitMatches.reduce((sum, m) => sum + parseInt(m[1], 10), 0);
  }

  // Bullet items mentioning route/endpoint keywords.
  const bulletRouteLines = countBulletLines(
    body,
    /\b(?:endpoint|API\s+route|REST\s+route|HTTP\s+route)\b/i
  );

  return bulletRouteLines;
}

/**
 * Count service / module method signals.
 *
 * Least-reliable signal because "method" is a common word.  Uses explicit
 * "N methods/functions" counts first; falls back to bullet items that use
 * new/add/create alongside method-like keywords.
 *
 * @param {string} body
 * @returns {number}
 */
function countMethods(body) {
  // Explicit "3 methods", "5 functions", etc.
  const explicitMatches = [
    ...body.matchAll(/\b(\d+)\s+(?:new\s+)?(?:methods?|functions?|handlers?|services?)\b/gi),
  ];
  if (explicitMatches.length > 0) {
    return explicitMatches.reduce((sum, m) => sum + parseInt(m[1], 10), 0);
  }

  // Bullet items: "- add `doFoo()` method", "- new handler for …"
  const bulletMethodLines = countBulletLines(
    body,
    /\b(?:method|function|handler|util(?:ity)?)\b/i,
    /^(?:add|create|introduce|new|implement)\b/i
  );

  return bulletMethodLines;
}

// ---------------------------------------------------------------------------
// Core scoring function
// ---------------------------------------------------------------------------

/**
 * Score an issue body against the Phase 2 rubric and return a tier verdict.
 *
 * @param {string} body  Raw issue body text.
 * @returns {{
 *   tier: "SMALL"|"MEDIUM"|"LARGE"|"AMBIGUOUS",
 *   score: number,
 *   signals: {models: number, methods: number, routes: number, scenarios: number},
 *   reason: string
 * }}
 */
export function scoreIssue(body) {
  if (!body || typeof body !== "string") {
    return {
      tier: "AMBIGUOUS",
      score: 0,
      signals: { models: 0, methods: 0, routes: 0, scenarios: 0 },
      reason: "empty or non-string body — cannot score; treated as AMBIGUOUS",
    };
  }

  // UNTRUSTED input, no upstream size limit — bound the text before any regex.
  if (body.length > MAX_BODY_CHARS) body = body.slice(0, MAX_BODY_CHARS);

  const signals = {
    models: countModels(body),
    methods: countMethods(body),
    routes: countRoutes(body),
    scenarios: countScenarios(body),
  };

  const score =
    signals.models * WEIGHTS.models +
    signals.methods * WEIGHTS.methods +
    signals.routes * WEIGHTS.routes +
    signals.scenarios * WEIGHTS.scenarios;

  const tier = deriveTier(score);

  const reason = buildReason(tier, score, signals);

  return { tier, score, signals, reason };
}

/**
 * Map a numeric score to a tier, applying the ±MARGIN confidence window.
 *
 * @param {number} score
 * @returns {"SMALL"|"MEDIUM"|"LARGE"|"AMBIGUOUS"}
 */
function deriveTier(score) {
  if (score > LARGE_MIN + MARGIN) return "LARGE";
  if (score >= LARGE_MIN - MARGIN) return "AMBIGUOUS";
  if (score > SMALL_MAX) return "MEDIUM";
  return "SMALL";
}

/**
 * Build a human-readable reason string for the verdict.
 */
function buildReason(tier, score, signals) {
  const parts = [];
  if (signals.models > 0) parts.push(`${signals.models} model(s)×3`);
  if (signals.methods > 0) parts.push(`${signals.methods} method(s)×1`);
  if (signals.routes > 0) parts.push(`${signals.routes} route(s)×2`);
  if (signals.scenarios > 0) parts.push(`${signals.scenarios} scenario(s)×1`);
  const breakdown = parts.length > 0 ? ` [${parts.join(", ")} → score ${score}]` : ` [no signals detected, score ${score}]`;
  const boundary =
    tier === "AMBIGUOUS"
      ? ` (within ±${MARGIN} of Large threshold ${LARGE_MIN}; fall back to full gate)`
      : "";
  return `${tier}${breakdown}${boundary}`;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const USAGE = `Usage: node skills/lib/issue-prescorer.mjs [--body "<text>"]
       gh issue view 123 --json body --jq .body | node skills/lib/issue-prescorer.mjs

Applies the Phase 2 sizing rubric to an issue body and emits a tier verdict:

  SMALL      score ≤ ${SMALL_MAX}    — implement directly, no decomposition needed
  MEDIUM     ${SMALL_MAX + 1}–${LARGE_MIN - MARGIN - 1}    — implement directly (commit per vertical slice)
  AMBIGUOUS  ${LARGE_MIN - MARGIN}–${LARGE_MIN + MARGIN}    — near Large threshold; fall back to full sizing+governance
  LARGE      score > ${LARGE_MIN + MARGIN}   — decompose first; skip parent governance fork

Prints JSON: { tier, score, signals: { models, methods, routes, scenarios }, reason }
Exit codes: 0 success · 2 usage error.`;

async function main(argv) {
  let bodyArg = null;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      console.log(USAGE);
      return 0;
    } else if (arg === "--body") {
      const v = argv[++i];
      if (v === undefined) {
        console.error(`Missing value for --body\n\n${USAGE}`);
        return 2;
      }
      bodyArg = v;
    } else if (arg.startsWith("--")) {
      console.error(`Unknown option: ${arg}\n\n${USAGE}`);
      return 2;
    }
  }

  let body = bodyArg;

  // Read from stdin if --body was not supplied and stdin is not a TTY.
  if (body === null) {
    const { stdin } = process;
    if (stdin.isTTY) {
      console.error(`No --body supplied and stdin is a TTY.\n\n${USAGE}`);
      return 2;
    }
    const chunks = [];
    for await (const chunk of stdin) chunks.push(chunk);
    body = Buffer.concat(chunks).toString("utf8");
  }

  const result = scoreIssue(body);
  console.log(JSON.stringify(result, null, 2));
  return 0;
}

// Only run CLI when executed directly (not when imported as a module).
if (
  process.argv[1] &&
  (process.argv[1].endsWith("issue-prescorer.mjs") ||
    process.argv[1].endsWith("issue-prescorer"))
) {
  main(process.argv.slice(2))
    .then((code) => process.exit(code ?? 0))
    .catch((err) => {
      console.error(err.message);
      process.exit(2);
    });
}
