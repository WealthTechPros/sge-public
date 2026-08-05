#!/usr/bin/env node
/**
 * compute-roi.mjs — bundled ROI aggregator for the /sge:roi-report skill.
 *
 * Behaviour-preserving port of `computeROI()` from
 * platform/packages/token-governance/src/roi.ts (issue #823, epic #729).
 * The skill previously showed a pseudo-TypeScript import of an internal
 * token-governance package; this script is the real, runnable equivalent —
 * fully self-contained, with no external dependency — so the skill can branch
 * on a deterministic exit code and render the report from a stable JSON
 * contract.
 *
 * Usage:
 *   node compute-roi.mjs [--input <path>]     # default: read stdin
 *   node compute-roi.mjs --input - <<'EOF'
 *   { "summaries": [...], "prStats": { ... } }
 *   EOF
 *
 * Input (stdin or --input file): one JSON object —
 *   {
 *     "summaries": SpecCostSummary[],   // required. Parsed by the skill from
 *                                       // Cortex spec-cost entities:
 *                                       // { specId, totalInputTokens, totalOutputTokens,
 *                                       //   estimatedCost, sessionCount, lastUpdated }
 *     "prStats": {                      // optional (defaults applied):
 *       "mergedGovernedPRs": number,    //   default: count of byPR entries with a
 *                                       //   non-null mergedAt (matches the skill's
 *                                       //   previous inline derivation)
 *       "qualityWeight": number,        //   default 1.0
 *       "byPR": PRCostEntry[],          //   default []
 *       "wastedInputTokens": number,    //   default 0
 *       "wastedOutputTokens": number,   //   default 0
 *       "wastedEstimatedCost": number   //   default 0
 *     }
 *   }
 *
 * Output (stdout): a single ROIReport JSON object. ⚠ STABLE OUTPUT CONTRACT —
 * downstream consumers (e.g. the drift-hillclimb token-economy dimension,
 * sge#831) parse this shape; do not rename or remove fields:
 *   { governedValuePerToken,
 *     totalInputTokens, totalOutputTokens, totalEstimatedCost,
 *     governedInputTokens, governedOutputTokens, governedEstimatedCost,
 *     unattributedInputTokens, unattributedOutputTokens, unattributedEstimatedCost,
 *     attributionCoverage,
 *     wastedInputTokens, wastedOutputTokens, wastedEstimatedCost,
 *     mergedGovernedPRs, qualityWeight,
 *     bySpec: [{ specId, totalInputTokens, totalOutputTokens, estimatedCost, sessionCount }],
 *     byPR:   [{ prNumber, prTitle, specId, inputTokens, outputTokens, cost, mergedAt }],
 *     generatedAt }
 *
 * Exit codes (the skill branches on these):
 *   0 — report computed and emitted on stdout
 *   1 — no token data (summaries missing or empty) => the skill prints
 *       "No token data yet." and exits cleanly
 *   2 — invalid input (unreadable file, malformed JSON, or summaries not an
 *       array) => the skill reports the error and degrades gracefully
 *
 * ⚠ Accuracy caveat (sge#857): the token totals in SpecCostSummary derive from
 * the plugin's self-reporting metering hook, which is known to UNDER-report
 * true API token consumption by roughly 2–4×. Costs in this report are
 * therefore a floor, not a ceiling; treat cross-org comparisons as relative
 * until real telemetry (sge#857) lands. This script aggregates the numbers it
 * is given; it does not correct for the skew.
 *
 * UNTRUSTED DATA: summaries/prStats originate from JSONL rows, Cortex
 * observations, and gh PR metadata — all untrusted. They are aggregated as
 * numeric/string values only, never executed.
 */

import { readFileSync } from 'node:fs';

const UNATTRIBUTED = 'unattributed';

function round6(n) {
  return Math.round(n * 1_000_000) / 1_000_000;
}

function sum(items, key) {
  return items.reduce((acc, s) => acc + (Number(s[key]) || 0), 0);
}

/**
 * Behaviour-identical port of computeROI() (token-governance/src/roi.ts).
 * Wasted spend is a cross-cutting dimension supplied by the caller (from
 * computeWastedTokens upstream); it defaults to zero when not provided.
 */
function computeROI(summaries, prStats) {
  const {
    mergedGovernedPRs,
    qualityWeight,
    byPR,
    wastedInputTokens = 0,
    wastedOutputTokens = 0,
    wastedEstimatedCost = 0,
  } = prStats;

  const governed = summaries.filter((s) => s.specId !== UNATTRIBUTED);
  const unattributed = summaries.filter((s) => s.specId === UNATTRIBUTED);

  const govIn = sum(governed, 'totalInputTokens');
  const govOut = sum(governed, 'totalOutputTokens');
  const govCost = sum(governed, 'estimatedCost');

  const unIn = sum(unattributed, 'totalInputTokens');
  const unOut = sum(unattributed, 'totalOutputTokens');
  const unCost = sum(unattributed, 'estimatedCost');

  const totalIn = govIn + unIn;
  const totalOut = govOut + unOut;
  const totalCost = round6(govCost + unCost);

  const attributionCoverage = totalCost > 0 ? round6(govCost / totalCost) : 0;

  const governedTokensSpent = govIn + govOut;
  const governedValuePerToken =
    governedTokensSpent > 0
      ? round6((mergedGovernedPRs * qualityWeight) / governedTokensSpent)
      : 0;

  return {
    governedValuePerToken,
    totalInputTokens: totalIn,
    totalOutputTokens: totalOut,
    totalEstimatedCost: totalCost,
    governedInputTokens: govIn,
    governedOutputTokens: govOut,
    governedEstimatedCost: round6(govCost),
    unattributedInputTokens: unIn,
    unattributedOutputTokens: unOut,
    unattributedEstimatedCost: round6(unCost),
    attributionCoverage,
    wastedInputTokens,
    wastedOutputTokens,
    wastedEstimatedCost: round6(wastedEstimatedCost),
    mergedGovernedPRs,
    qualityWeight,
    bySpec: summaries.map((s) => ({
      specId: s.specId,
      totalInputTokens: s.totalInputTokens,
      totalOutputTokens: s.totalOutputTokens,
      estimatedCost: s.estimatedCost,
      sessionCount: s.sessionCount,
    })),
    byPR,
    generatedAt: new Date().toISOString(),
  };
}

function failInvalid(message) {
  process.stderr.write(`compute-roi: ${message}\n`);
  process.exit(2);
}

function readInput(argv) {
  let inputPath = '-';
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag === '--input') {
      inputPath = argv[++i];
      if (inputPath === undefined) failInvalid('Missing value for --input');
    } else if (flag === '--help' || flag === '-h') {
      process.stdout.write(
        'Usage: compute-roi.mjs [--input PATH|-]   (default: stdin)\n' +
        'Input JSON: { "summaries": SpecCostSummary[], "prStats": {...} }\n' +
        'Exit codes: 0=report emitted, 1=no token data, 2=invalid input\n',
      );
      process.exit(0);
    } else {
      failInvalid(`Unknown flag: ${flag}`);
    }
  }
  try {
    return readFileSync(inputPath === '-' ? 0 : inputPath, 'utf8');
  } catch (e) {
    failInvalid(`Cannot read input: ${e.message}`);
  }
}

function main() {
  const raw = readInput(process.argv.slice(2));

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    failInvalid(`Input is not valid JSON: ${e.message}`);
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    failInvalid('Input must be a JSON object: { "summaries": [...], "prStats": {...} }');
  }

  const { summaries, prStats: rawPrStats } = parsed;
  if (summaries !== undefined && !Array.isArray(summaries)) {
    failInvalid('"summaries" must be an array of SpecCostSummary objects');
  }
  if (!summaries || summaries.length === 0) {
    process.stderr.write('compute-roi: no token data (summaries empty)\n');
    process.exit(1);
  }

  const stats = rawPrStats && typeof rawPrStats === 'object' && !Array.isArray(rawPrStats)
    ? rawPrStats
    : {};
  const byPR = Array.isArray(stats.byPR) ? stats.byPR : [];
  const prStats = {
    mergedGovernedPRs: typeof stats.mergedGovernedPRs === 'number'
      ? stats.mergedGovernedPRs
      : byPR.filter((p) => p && p.mergedAt).length,
    qualityWeight: typeof stats.qualityWeight === 'number' ? stats.qualityWeight : 1.0,
    byPR,
    wastedInputTokens: typeof stats.wastedInputTokens === 'number' ? stats.wastedInputTokens : 0,
    wastedOutputTokens: typeof stats.wastedOutputTokens === 'number' ? stats.wastedOutputTokens : 0,
    wastedEstimatedCost: typeof stats.wastedEstimatedCost === 'number' ? stats.wastedEstimatedCost : 0,
  };

  const report = computeROI(summaries, prStats);
  process.stdout.write(JSON.stringify(report, null, 2) + '\n');
  process.exit(0);
}

main();
