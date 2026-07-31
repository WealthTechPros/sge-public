#!/usr/bin/env node
/**
 * score-token-economy.mjs — the script-anchored MEASURE step for
 * `/sgd:drift-hillclimb --dimension token-economy` (sgd#831).
 *
 * Scores **governed-value-per-token per SGD skill** and picks the worst
 * skill×outcome ratio — the single highest-leverage improvement along the
 * token-economy dimension — so the hill-climb governor can open ONE bounded
 * PR that pulls the recommended lever (prune prose to references, extract a
 * script, or demote a model tier).
 *
 * It joins the two durable telemetry sidecars shipped by the substrate:
 *   - memory/token-usage.jsonl  — TokenUsageRecord rows (#726 producer)
 *   - memory/skill-runs.jsonl   — SkillRunRecord rows   (#727 run artifacts)
 * A token row is attributed to a skill by its own `skill` field when present,
 * else by the skill-run that shares its `sessionId` (the documented join key).
 *
 * Governed value = count of *successful* skill runs (merged | pass | ready |
 * done | approved — the four emitting skills' success verdicts). Value-per-
 * token = successfulRuns / tokensSpent; the worst skill is the one with the
 * fewest successes per token (equivalently, the most tokens per success). A
 * skill that spent tokens but shipped nothing (0 successes) is Infinity
 * tokens/success — the worst by construction, never silently dropped.
 *
 * The org-wide `governedValuePerToken` is NOT re-derived here: pass
 * `--roi <file>` (roi-report / compute-roi.mjs output) and this script surfaces
 * that number verbatim as `orgGovernedValuePerToken`. Owns the per-skill
 * breakdown only; roi-report (sgd#823) owns the org number.
 *
 * Usage:
 *   node score-token-economy.mjs [--usage <path>] [--runs <path>]
 *                                [--roi <path>] [--repo <org/repo>]
 *
 * Output (stdout): a single JSON verdict. ⚠ STABLE CONTRACT — the drift-
 * hillclimb SKILL.md and its trend append parse this shape:
 *   { dimension: "token-economy", repo, generatedAt,
 *     orgGovernedValuePerToken,            // from --roi, else null
 *     perSkill: [ { skill, runs, successfulRuns, tokensSpent, inputTokens,
 *                   outputTokens, dominantModel, valuePerToken,
 *                   tokensPerSuccess } ],  // worst first
 *     worst: { skill, tokensSpent, successfulRuns, valuePerToken,
 *              tokensPerSuccess, recommendedLever, reason } | null,
 *     trendRow: { dimension, repo, timestamp, worstSkill,
 *                 worstTokensPerSuccess, worstValuePerToken,
 *                 orgGovernedValuePerToken },
 *     unattributedTokens,
 *     skillsWithoutTelemetry: [ skill, ... ] }
 *
 * Exit codes (the skill branches on these):
 *   0 — verdict emitted on stdout
 *   1 — no telemetry to score (either sidecar empty/absent) => the skill
 *       prints "No token-economy telemetry yet." and exits cleanly
 *   2 — harness/arg error (unknown flag, or an EXPLICITLY-named file that is
 *       unreadable) => the skill reports the error and degrades gracefully
 *
 * ⚠ Accuracy caveat (sgd#857, inherited from roi-report): token totals derive
 * from the plugin's self-reporting metering hook, which under-reports true API
 * consumption by ~2–4×. tokens/success is therefore a *relative* leverage
 * signal for ranking skills, not an absolute cost — treat the ranking as sound
 * and the magnitudes as a floor until real telemetry (sgd#857) lands.
 *
 * UNTRUSTED DATA: every JSONL row (token-usage, skill-runs) and the --roi JSON
 * originate from metering hooks, gh metadata, and Cortex — all untrusted. They
 * are parsed as numeric/string values only, never executed; malformed lines
 * are skipped, never evaluated.
 */

import { readFileSync } from 'node:fs';

// Success verdicts across the four SkillRunRecord-emitting skills (types.ts):
//   sgd-implement: "merged"; sgd-review: "pass"; sgd-preflight: "ready";
//   refactor: "done". "approved" is accepted as a pr-review synonym.
const SUCCESS_VERDICTS = new Set(['merged', 'pass', 'ready', 'done', 'approved']);
const UNATTRIBUTED = '__unattributed__';

function failHarness(message) {
  process.stderr.write(`score-token-economy: ${message}\n`);
  process.exit(2);
}

function round6(n) {
  return Math.round(n * 1_000_000) / 1_000_000;
}

/** Read an explicitly-named file: unreadable => harness error (exit 2). */
function readExplicit(path) {
  try {
    return readFileSync(path, 'utf8');
  } catch (e) {
    failHarness(`cannot read ${path}: ${e.message}`);
  }
}

/** Parse JSONL, skipping blank/malformed lines (untrusted input). */
function parseJsonl(raw) {
  const rows = [];
  for (const line of raw.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    try {
      const obj = JSON.parse(t);
      if (obj && typeof obj === 'object' && !Array.isArray(obj)) rows.push(obj);
    } catch {
      // skip malformed line — never execute untrusted content
    }
  }
  return rows;
}

function parseArgs(argv) {
  const args = { usage: 'memory/token-usage.jsonl', runs: 'memory/skill-runs.jsonl', roi: null, repo: null };
  const explicit = new Set();
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    switch (flag) {
      case '--usage': args.usage = argv[++i]; explicit.add('usage'); break;
      case '--runs': args.runs = argv[++i]; explicit.add('runs'); break;
      case '--roi': args.roi = argv[++i]; break;
      case '--repo': args.repo = argv[++i]; break;
      case '--help':
      case '-h':
        process.stdout.write(
          'Usage: score-token-economy.mjs [--usage PATH] [--runs PATH] [--roi PATH] [--repo org/repo]\n' +
          'Exit: 0=verdict emitted, 1=no telemetry, 2=harness/arg error\n',
        );
        process.exit(0);
        break;
      default:
        failHarness(`unknown flag: ${flag}`);
    }
  }
  return { args, explicit };
}

/**
 * Read a sidecar. An explicitly-named unreadable file is a harness error;
 * a default path that is simply absent is treated as empty ("no data yet").
 */
function readSidecar(path, isExplicit) {
  if (isExplicit) return parseJsonl(readExplicit(path));
  try {
    return parseJsonl(readFileSync(path, 'utf8'));
  } catch {
    return [];
  }
}

function matchesRepo(row, repo) {
  return !repo || row.repo === repo;
}

function selectLever(inputTokens, outputTokens, dominantModel) {
  // opus (premium tier) dominant -> the cheapest structural win is a tier demotion.
  if (/opus/i.test(dominantModel || '')) return 'demote-model-tier';
  const total = inputTokens + outputTokens;
  const inputShare = total > 0 ? inputTokens / total : 0;
  // prompt-dominated (>=70% input) -> the prose IS the cost; move it to references.
  if (inputShare >= 0.7) return 'prune-prose-to-references';
  // otherwise the work itself is the cost -> extract deterministic steps to a script.
  return 'extract-script';
}

function main() {
  const { args, explicit } = parseArgs(process.argv.slice(2));

  const roiRaw = args.roi ? readExplicit(args.roi) : null;
  let orgGovernedValuePerToken = null;
  if (roiRaw !== null) {
    try {
      const roi = JSON.parse(roiRaw);
      if (roi && typeof roi.governedValuePerToken === 'number') {
        orgGovernedValuePerToken = roi.governedValuePerToken;
      }
    } catch (e) {
      failHarness(`--roi file is not valid JSON: ${e.message}`);
    }
  }

  const usageRows = readSidecar(args.usage, explicit.has('usage')).filter((r) => matchesRepo(r, args.repo));
  const runRows = readSidecar(args.runs, explicit.has('runs')).filter((r) => matchesRepo(r, args.repo));

  // Cannot compute value-per-token without BOTH spend and outcomes.
  if (usageRows.length === 0 || runRows.length === 0) {
    process.stderr.write('score-token-economy: no telemetry to score (a sidecar is empty)\n');
    process.exit(1);
  }

  // sessionId -> skill, from skill-runs (the join fallback for skill-less token rows).
  const sessionSkill = new Map();
  for (const r of runRows) {
    if (typeof r.sessionId === 'string' && typeof r.skill === 'string' && !sessionSkill.has(r.sessionId)) {
      sessionSkill.set(r.sessionId, r.skill);
    }
  }

  // Per-skill run tallies.
  const skills = new Map(); // skill -> aggregate
  const ensure = (skill) => {
    if (!skills.has(skill)) {
      skills.set(skill, {
        skill, runs: 0, successfulRuns: 0,
        tokensSpent: 0, inputTokens: 0, outputTokens: 0,
        modelTokens: new Map(),
      });
    }
    return skills.get(skill);
  };

  for (const r of runRows) {
    if (typeof r.skill !== 'string') continue;
    const agg = ensure(r.skill);
    agg.runs += 1;
    if (SUCCESS_VERDICTS.has(String(r.verdict).toLowerCase())) agg.successfulRuns += 1;
  }

  // Attribute token spend to skills.
  let unattributedTokens = 0;
  for (const u of usageRows) {
    const inTok = Number(u.inputTokens) || 0;
    const outTok = Number(u.outputTokens) || 0;
    const tok = inTok + outTok;
    if (tok <= 0) continue;
    const skill = (typeof u.skill === 'string' && u.skill)
      || sessionSkill.get(u.sessionId)
      || UNATTRIBUTED;
    if (skill === UNATTRIBUTED) { unattributedTokens += tok; continue; }
    const agg = ensure(skill);
    agg.tokensSpent += tok;
    agg.inputTokens += inTok;
    agg.outputTokens += outTok;
    const model = typeof u.model === 'string' ? u.model : 'unknown';
    agg.modelTokens.set(model, (agg.modelTokens.get(model) || 0) + tok);
  }

  // Build the per-skill scorecard.
  const perSkill = [];
  const skillsWithoutTelemetry = [];
  for (const agg of skills.values()) {
    if (agg.tokensSpent <= 0) {
      // A skill with runs but no attributable spend cannot be scored on
      // value-per-token — report it honestly, keep it out of the worst pick.
      if (agg.runs > 0) skillsWithoutTelemetry.push(agg.skill);
      continue;
    }
    let dominantModel = 'unknown';
    let maxTok = -1;
    for (const [m, t] of agg.modelTokens) {
      if (t > maxTok) { maxTok = t; dominantModel = m; }
    }
    const valuePerToken = round6(agg.successfulRuns / agg.tokensSpent);
    const tokensPerSuccess = agg.successfulRuns > 0
      ? Math.round(agg.tokensSpent / agg.successfulRuns)
      : null; // null == Infinity (all cost, no governed value)
    perSkill.push({
      skill: agg.skill,
      runs: agg.runs,
      successfulRuns: agg.successfulRuns,
      tokensSpent: agg.tokensSpent,
      inputTokens: agg.inputTokens,
      outputTokens: agg.outputTokens,
      dominantModel,
      valuePerToken,
      tokensPerSuccess,
    });
  }

  // Rank worst-first: a null tokensPerSuccess (0 successes) sorts worst; then
  // the highest tokens/success; ties broken by the larger absolute spend.
  perSkill.sort((a, b) => {
    const av = a.tokensPerSuccess === null ? Infinity : a.tokensPerSuccess;
    const bv = b.tokensPerSuccess === null ? Infinity : b.tokensPerSuccess;
    if (av !== bv) return bv - av;
    return b.tokensSpent - a.tokensSpent;
  });

  let worst = null;
  if (perSkill.length > 0) {
    const w = perSkill[0];
    const wagg = skills.get(w.skill);
    const recommendedLever = selectLever(w.inputTokens, w.outputTokens, w.dominantModel);
    const reason = w.successfulRuns === 0
      ? `${w.tokensSpent} tokens spent with no successful runs — no governed value returned`
      : `${w.tokensPerSuccess} tokens per successful run (worst governed-value-per-token: ${w.valuePerToken})`;
    worst = {
      skill: w.skill,
      tokensSpent: w.tokensSpent,
      successfulRuns: w.successfulRuns,
      valuePerToken: w.valuePerToken,
      tokensPerSuccess: w.tokensPerSuccess,
      dominantModel: w.dominantModel,
      recommendedLever,
      reason,
    };
    void wagg;
  }

  const generatedAt = new Date().toISOString();
  const verdict = {
    dimension: 'token-economy',
    repo: args.repo || 'all',
    generatedAt,
    orgGovernedValuePerToken,
    perSkill,
    worst,
    trendRow: {
      dimension: 'token-economy',
      repo: args.repo || 'all',
      timestamp: generatedAt,
      worstSkill: worst ? worst.skill : null,
      worstTokensPerSuccess: worst ? worst.tokensPerSuccess : null,
      worstValuePerToken: worst ? worst.valuePerToken : null,
      orgGovernedValuePerToken,
    },
    unattributedTokens,
    skillsWithoutTelemetry,
  };

  process.stdout.write(JSON.stringify(verdict, null, 2) + '\n');
  process.exit(0);
}

main();
