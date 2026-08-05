#!/usr/bin/env node
/**
 * score-skill-quality.mjs — the script-anchored MEASURE step for
 * `/sge:drift-hillclimb --dimension skill-quality` (sge#832, parent #676).
 *
 * Joins two durable substrates — never re-derives either:
 *   - the #737 mechanical scan (`skills/sge-skill-audit/assets/scan-skills.sh`
 *     JSON output: SQ-0/SQ-3/SQ-4/SQ-5 pass/fail per skill) — the *quality*
 *     signal.
 *   - `memory/skill-runs.jsonl` — SkillRunRecord rows (#727 producer) — call
 *     counts x verdicts, windowed by recency — the *utilisation* signal.
 *
 * It surfaces TWO lanes (sge#832 acceptance):
 *   - utilisation: a skill with zero runs inside the window (default 30d) is
 *     a deprecation CANDIDATE. This script never deletes anything — the
 *     hill-climb governor turns candidates into an issue for a human to
 *     decide, exactly like a C13 content-drift gap.
 *   - executability: a skill whose bad-verdict (blocked/failed/thrashing)
 *     rate is high AND whose run count clears a noise floor is the single
 *     `worst` pick — the ONE bounded executability-fix PR this cycle.
 *
 * Usage:
 *   node score-skill-quality.mjs --scan <scan-skills.sh JSON output file>
 *                                 [--runs <path>] [--window-days <n>]
 *                                 [--now <ISO-8601>] [--repo <org/repo>]
 *
 * `--scan` is REQUIRED (unlike the runs sidecar, there is no sensible
 * default location for a one-shot scan's JSON — the caller runs
 * `scan-skills.sh ... > file` first, mirroring how sge-align consumes its
 * own JSON). A missing/unreadable/malformed --scan file is a harness error.
 *
 * Output (stdout): a single JSON verdict. STABLE CONTRACT — the
 * drift-hillclimb SKILL.md and its trend append parse this shape:
 *   { dimension: "skill-quality", repo, generatedAt, windowDays,
 *     perSkill: [ { skill, "SQ-0","SQ-3","SQ-4","SQ-5", mechanicalPass,
 *                    totalRuns, successfulRuns, badRuns, thrashRate,
 *                    runsInWindow, lastRunTimestamp } ],
 *     deprecationCandidates: [ { skill, totalRunsAllTime, lastRunTimestamp,
 *                                reason } ],   // zero runs in window
 *     worst: { skill, totalRuns, badRuns, thrashRate, recommendedAction,
 *              reason } | null,                // executability-fix pick
 *     mechanicalFindings: [ ...findings from --scan, passed through ],
 *     trendRow: { dimension, repo, timestamp, deprecationCandidateCount,
 *                 worstSkill, worstThrashRate, skillsScanned,
 *                 skillsFailingMechanical } }
 *
 * Exit codes (the skill branches on these):
 *   0 — verdict emitted on stdout
 *   1 — no data to score (--scan's results[] is empty) => the skill prints
 *       "No skill-quality telemetry yet." and exits cleanly
 *   2 — harness/arg error (missing/unreadable --scan, malformed JSON,
 *       unknown flag) => the skill reports the error and degrades gracefully
 *
 * UNTRUSTED DATA: the scan JSON and every skill-runs.jsonl row originate
 * from filesystem scans and skill self-reports — untrusted. They are parsed
 * as numeric/string values only, never executed; malformed lines/files are
 * rejected as harness errors (--scan) or skipped (skill-runs rows).
 */

import { readFileSync } from 'node:fs';

// Success verdicts across the four SkillRunRecord-emitting skills (types.ts):
//   sge-implement: "merged"; sge-review: "pass"; sge-preflight: "ready";
//   refactor: "done". "approved" is accepted as a pr-review synonym.
// Everything else (blocked, failed, fail, not_ready, reverted, skipped, ...)
// counts as a "bad" run for the thrash-rate calculation — the complement.
const SUCCESS_VERDICTS = new Set(['merged', 'pass', 'ready', 'done', 'approved']);

const DEFAULT_WINDOW_DAYS = 30;
// A skill needs at least this many runs before its thrash rate is trusted —
// one bad run out of one is 100% but tells you nothing (T7).
const MIN_RUNS_FOR_THRASH = 3;
// Bad-verdict share at/above this is "high" enough to warrant the ONE
// bounded executability-fix PR this cycle.
const THRASH_THRESHOLD = 0.5;

function failHarness(message) {
  process.stderr.write(`score-skill-quality: ${message}\n`);
  process.exit(2);
}

function round4(n) {
  return Math.round(n * 10_000) / 10_000;
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
  const args = {
    scan: null,
    runs: 'memory/skill-runs.jsonl',
    windowDays: DEFAULT_WINDOW_DAYS,
    now: null,
    repo: null,
  };
  const explicit = new Set();
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    switch (flag) {
      case '--scan': args.scan = argv[++i]; explicit.add('scan'); break;
      case '--runs': args.runs = argv[++i]; explicit.add('runs'); break;
      case '--window-days': args.windowDays = Number(argv[++i]); break;
      case '--now': args.now = argv[++i]; break;
      case '--repo': args.repo = argv[++i]; break;
      case '--help':
      case '-h':
        process.stdout.write(
          'Usage: score-skill-quality.mjs --scan PATH [--runs PATH] [--window-days N] [--now ISO8601] [--repo org/repo]\n' +
          'Exit: 0=verdict emitted, 1=no data, 2=harness/arg error\n',
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

function main() {
  const { args, explicit } = parseArgs(process.argv.slice(2));

  if (!args.scan) {
    failHarness('--scan <scan-skills.sh JSON output file> is required');
  }
  if (!Number.isFinite(args.windowDays) || args.windowDays <= 0) {
    failHarness('--window-days must be a positive number');
  }

  const scanRaw = readExplicit(args.scan);
  let scan;
  try {
    scan = JSON.parse(scanRaw);
  } catch (e) {
    failHarness(`--scan file is not valid JSON: ${e.message}`);
  }
  if (!scan || !Array.isArray(scan.results)) {
    failHarness('--scan file does not look like scan-skills.sh output (missing results[])');
  }

  if (scan.results.length === 0) {
    process.stderr.write('score-skill-quality: no data to score (--scan results[] is empty)\n');
    process.exit(1);
  }

  const now = args.now ? new Date(args.now) : new Date();
  if (Number.isNaN(now.getTime())) {
    failHarness(`--now is not a valid ISO-8601 timestamp: ${args.now}`);
  }
  const windowStart = new Date(now.getTime() - args.windowDays * 24 * 60 * 60 * 1000);

  const runRows = readSidecar(args.runs, explicit.has('runs')).filter((r) => matchesRepo(r, args.repo));

  const findings = Array.isArray(scan.findings) ? scan.findings : [];

  // Per-skill run tallies, keyed by the scan's skill universe (a skill that
  // exists in the repo but has never run must still surface as a possible
  // deprecation candidate — it cannot be silently absent).
  const skills = new Map();
  for (const r of scan.results) {
    if (typeof r.skill !== 'string') continue;
    skills.set(r.skill, {
      skill: r.skill,
      'SQ-0': r['SQ-0'] ?? 'na',
      'SQ-3': r['SQ-3'] ?? 'na',
      'SQ-4': r['SQ-4'] ?? 'na',
      'SQ-5': r['SQ-5'] ?? 'na',
      totalRuns: 0,
      successfulRuns: 0,
      runsInWindow: 0,
      lastRunTimestamp: null,
    });
  }

  for (const r of runRows) {
    if (typeof r.skill !== 'string') continue;
    const agg = skills.get(r.skill);
    if (!agg) continue; // run for a skill outside the scanned universe — ignore, not our scope
    agg.totalRuns += 1;
    if (SUCCESS_VERDICTS.has(String(r.verdict).toLowerCase())) agg.successfulRuns += 1;
    const ts = typeof r.timestamp === 'string' ? new Date(r.timestamp) : null;
    if (ts && !Number.isNaN(ts.getTime())) {
      if (!agg.lastRunTimestamp || ts > new Date(agg.lastRunTimestamp)) {
        agg.lastRunTimestamp = r.timestamp;
      }
      if (ts >= windowStart && ts <= now) agg.runsInWindow += 1;
    }
  }

  const perSkill = [];
  const deprecationCandidates = [];
  let skillsFailingMechanical = 0;

  for (const agg of skills.values()) {
    const badRuns = agg.totalRuns - agg.successfulRuns;
    const thrashRate = agg.totalRuns > 0 ? round4(badRuns / agg.totalRuns) : null;
    const mechanicalPass = agg['SQ-0'] !== 'fail' && agg['SQ-3'] !== 'fail'
      && agg['SQ-4'] !== 'fail' && agg['SQ-5'] !== 'fail';
    if (!mechanicalPass) skillsFailingMechanical += 1;

    perSkill.push({
      skill: agg.skill,
      'SQ-0': agg['SQ-0'],
      'SQ-3': agg['SQ-3'],
      'SQ-4': agg['SQ-4'],
      'SQ-5': agg['SQ-5'],
      mechanicalPass,
      totalRuns: agg.totalRuns,
      successfulRuns: agg.successfulRuns,
      badRuns,
      thrashRate,
      runsInWindow: agg.runsInWindow,
      lastRunTimestamp: agg.lastRunTimestamp,
    });

    if (agg.runsInWindow === 0) {
      deprecationCandidates.push({
        skill: agg.skill,
        totalRunsAllTime: agg.totalRuns,
        lastRunTimestamp: agg.lastRunTimestamp,
        reason: agg.totalRuns === 0
          ? `no recorded runs at all (never called)`
          : `zero runs in the last ${args.windowDays}d (last run: ${agg.lastRunTimestamp})`,
      });
    }
  }

  // Rank executability-fix candidates: eligible = clears the noise floor
  // (MIN_RUNS_FOR_THRASH) and its bad-verdict rate is at/above THRASH_THRESHOLD.
  // Worst-first by rate, ties broken by higher raw run count (more evidence).
  const eligible = perSkill.filter(
    (s) => s.totalRuns >= MIN_RUNS_FOR_THRASH && s.thrashRate !== null && s.thrashRate >= THRASH_THRESHOLD,
  );
  eligible.sort((a, b) => {
    if (b.thrashRate !== a.thrashRate) return b.thrashRate - a.thrashRate;
    return b.totalRuns - a.totalRuns;
  });

  let worst = null;
  if (eligible.length > 0) {
    const w = eligible[0];
    worst = {
      skill: w.skill,
      totalRuns: w.totalRuns,
      badRuns: w.badRuns,
      thrashRate: w.thrashRate,
      recommendedAction: 'executability-fix',
      reason: `${w.badRuns}/${w.totalRuns} runs blocked/failed/thrashing (${Math.round(w.thrashRate * 100)}%) — highest bad-verdict rate at or above ${MIN_RUNS_FOR_THRASH}+ runs`,
    };
  }

  perSkill.sort((a, b) => a.skill.localeCompare(b.skill));
  deprecationCandidates.sort((a, b) => a.skill.localeCompare(b.skill));

  const generatedAt = new Date().toISOString();
  const verdict = {
    dimension: 'skill-quality',
    repo: args.repo || scan.repo || 'all',
    generatedAt,
    windowDays: args.windowDays,
    perSkill,
    deprecationCandidates,
    worst,
    mechanicalFindings: findings,
    trendRow: {
      dimension: 'skill-quality',
      repo: args.repo || scan.repo || 'all',
      timestamp: generatedAt,
      deprecationCandidateCount: deprecationCandidates.length,
      worstSkill: worst ? worst.skill : null,
      worstThrashRate: worst ? worst.thrashRate : null,
      skillsScanned: scan.results.length,
      skillsFailingMechanical,
    },
  };

  process.stdout.write(JSON.stringify(verdict, null, 2) + '\n');
  process.exit(0);
}

main();
