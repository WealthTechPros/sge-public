#!/usr/bin/env node
/**
 * select-gap.mjs — the script-anchored PICK step for the SGD-044-S3 scheduled
 * weekly improvement sweep (sge#833, parent #676).
 *
 * The sweep is the *cadence layer* that makes F-EFFICACY (SGD-044) real. Once a
 * week it reads the three drift **trend surfaces** the platform already
 * produces, normalises each dial's headline gap onto a comparable [0,1]
 * leverage scale, and picks the SINGLE highest-leverage dial. The chosen dial
 * maps to exactly one `/sge:drift-hillclimb` invocation bounded to ONE round —
 * so the sweep can never open more than one PR per cycle by construction.
 *
 * The three dials and their surfaces:
 *   - coherence     — docs/sge/drift-trend.jsonl rows (`audit_score`, 0..100;
 *                     legacy rows: `sm2_sample`), the Audit Score trend #724
 *                     (CLOSED) writes. Below-target Audit Score is the gap; the
 *                     lever is `/sge:drift-hillclimb`. NB: the Audit Score is the
 *                     plugin's per-check rollup, NOT the platform's canonical
 *                     SM-2 `coherence_score` (decision #834).
 *   - token-economy — score-token-economy.mjs trendRow (`worstTokensPerSuccess`,
 *                     sge#831). Tokens-per-success above budget is the gap; the
 *                     lever is `/sge:drift-hillclimb --dimension token-economy`.
 *   - skill-quality — score-skill-quality.mjs trendRow (`worstThrashRate`,
 *                     sge#832/#737). Thrash-rate is the gap; the lever is
 *                     `/sge:drift-hillclimb --dimension skill-quality`.
 *
 * Every dial is normalised to a leverage in [0,1] plus a `trendDelta` (change
 * vs the previous trend row; positive = worsening). Ranking is:
 *   1. leverage desc, 2. trendDelta desc (a worsening dial wins a tie),
 *   3. fixed dial priority (coherence > token-economy > skill-quality) for
 *   full determinism. A dial whose surface is absent/empty is `unavailable`
 *   and excluded from ranking — but always reported, so a skipped dial is
 *   visible (acceptance: "a skipped/failed cycle is visible").
 *
 * A dial only becomes a *candidate* if its leverage clears `--min-leverage`
 * (default 0.05). If no dial clears it, the sweep is a documented no-op cycle
 * (selected=null) — it still appends a delta row saying so, never silently
 * nothing.
 *
 * Usage:
 *   node select-gap.mjs [--coherence <drift-trend.jsonl>]
 *                       [--token <token trendRow json>]
 *                       [--skill-quality <skill-quality trendRow json>]
 *                       [--audit-score-target <n=85>]   (legacy alias: --sm2-target)
 *                       [--token-budget <tokensPerSuccess=5000>]
 *                       [--min-leverage <n=0.05>] [--repo <org/repo>]
 *
 * The three surface flags accept EITHER a `.jsonl` trend log (last row used) or
 * a single-object `.json` verdict (as emitted by the scorer scripts). A missing
 * flag or unreadable/empty file makes that dial `unavailable` — never a crash.
 *
 * Output (stdout): a single JSON verdict. ⚠ STABLE CONTRACT — the
 * improvement-sweep SKILL.md and its workflow parse this shape:
 *   { generatedAt, repo, sm2Target, tokenBudget, minLeverage,
 *     dials: [ { dial, available, leverage, trendDelta, current, target,
 *                headline, note } ],   // all three, ranked-then-unavailable
 *     selected: { dial, command, leverage, rationale } | null,
 *     skipped: [ { dial, reason } ] }  // unavailable / below-threshold dials
 *
 * Exit codes (the skill/workflow branch on these):
 *   0 — verdict emitted on stdout (selected may be null — a valid no-op cycle)
 *   2 — harness/arg error (unknown flag) => caller reports and degrades
 *
 * UNTRUSTED DATA: every trend row and verdict originates from filesystem scans
 * and skill self-reports — untrusted. They are parsed as numeric/string values
 * only, never executed; malformed lines/files are skipped or make the dial
 * unavailable. See the SKILL.md UNTRUSTED DATA banner.
 */

import { readFileSync } from 'node:fs';

const DIAL_PRIORITY = { coherence: 3, 'token-economy': 2, 'skill-quality': 1 };

const DIM_COMMAND = {
  coherence: '/sge:drift-hillclimb --max-rounds 1',
  'token-economy': '/sge:drift-hillclimb --dimension token-economy --max-rounds 1',
  'skill-quality': '/sge:drift-hillclimb --dimension skill-quality --max-rounds 1',
};

const clamp01 = (n) => (Number.isFinite(n) ? Math.max(0, Math.min(1, n)) : 0);

/**
 * Parse a surface file's text into an array of trend rows. Accepts a `.jsonl`
 * log (one JSON object per line — malformed lines skipped) or a single JSON
 * object/array. Returns [] for empty/whitespace text. Never throws on bad
 * lines — the sweep must degrade, not crash.
 */
export function parseSurface(text) {
  if (typeof text !== 'string' || text.trim() === '') return [];
  const trimmed = text.trim();
  // Try a single JSON document first (object or array).
  if (trimmed[0] === '[' || (trimmed[0] === '{' && !trimmed.includes('\n'))) {
    try {
      const doc = JSON.parse(trimmed);
      return Array.isArray(doc) ? doc.filter((r) => r && typeof r === 'object') : [doc];
    } catch {
      /* fall through to line-by-line */
    }
  }
  const rows = [];
  for (const line of trimmed.split(/\r?\n/)) {
    const l = line.trim();
    if (l === '') continue;
    try {
      const obj = JSON.parse(l);
      if (obj && typeof obj === 'object') rows.push(obj);
    } catch {
      /* skip malformed line — untrusted input */
    }
  }
  return rows;
}

/** Number-or-null: coerce a field to a finite number, else null. */
function num(v) {
  // `null`/`undefined` are the "no sample this run" placeholders — they are
  // absent data, NOT zero. Guard before coercion: `Number(null) === 0` and
  // `Number(undefined) === NaN` would otherwise admit an absent dial as a
  // scored row (leverage 1 off phantom data). Absent → null → dial unavailable.
  if (v === null || v === undefined) return null;
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

/**
 * Read the coherence dial from drift-trend.jsonl rows.
 * gap = clamp((target - score) / target, 0, 1). trendDelta = drop since prior row
 * (a falling Audit Score is worsening → positive delta).
 */
export function readCoherenceDial(rows, { sm2Target = 85 } = {}) {
  // The coherence dial reads the Audit Score (`audit_score`) written by
  // `/sge:sge-align` (decision #834). Legacy rows carry the pre-#834 key
  // `sm2_sample` (or `sm2`) — accepted as a fallback so historical trend
  // files keep working. NB: the Audit Score is the plugin's per-check
  // governance-coherence rollup, NOT the platform's canonical SM-2.
  const score = (r) => num(r.audit_score) ?? num(r.sm2_sample) ?? num(r.sm2);
  const withScore = rows.filter((r) => score(r) !== null);
  if (withScore.length === 0) {
    return { dial: 'coherence', available: false, note: 'no Audit Score samples on the coherence trend surface' };
  }
  const last = withScore[withScore.length - 1];
  const prev = withScore.length > 1 ? withScore[withScore.length - 2] : null;
  const current = score(last);
  const prevScore = prev ? score(prev) : null;
  const leverage = clamp01((sm2Target - current) / sm2Target);
  const trendDelta = prevScore !== null ? prevScore - current : 0; // fell => worsening => positive
  return {
    dial: 'coherence',
    available: true,
    leverage,
    trendDelta,
    current,
    target: sm2Target,
    headline: `Audit Score ${current} vs target ${sm2Target}`,
    note: leverage === 0 ? 'Audit Score at/above target' : `Audit Score ${sm2Target - current} below target`,
  };
}

/**
 * Read the token-economy dial from score-token-economy.mjs trendRow(s).
 * gap = clamp((worstTokensPerSuccess - budget) / worstTokensPerSuccess, 0, 1).
 * Infinity (a skill that shipped nothing) → leverage 1 (max). trendDelta =
 * rise in worstTokensPerSuccess since prior row (rising cost = worsening).
 */
export function readTokenDial(rows, { tokenBudget = 5000 } = {}) {
  const trendRows = rows.map((r) => r.trendRow ?? r).filter((r) => r && r.worstTokensPerSuccess !== undefined);
  if (trendRows.length === 0) {
    return { dial: 'token-economy', available: false, note: 'no token-economy telemetry on the trend surface' };
  }
  const last = trendRows[trendRows.length - 1];
  const prev = trendRows.length > 1 ? trendRows[trendRows.length - 2] : null;
  const rawWorst = last.worstTokensPerSuccess;
  const worst = rawWorst === null ? null : num(rawWorst);
  // A JSON `null` worst means "no worst skill" → nothing to climb.
  if (rawWorst === null) {
    return {
      dial: 'token-economy',
      available: true,
      leverage: 0,
      trendDelta: 0,
      current: null,
      target: tokenBudget,
      headline: 'no worst skill (no successful-run telemetry to rank)',
      note: 'no token-economy gap to climb',
    };
  }
  const isInfinite = worst === null || !Number.isFinite(worst); // Infinity serialises to null in JSON; treat unparseable as worst
  const leverage = isInfinite ? 1 : clamp01((worst - tokenBudget) / worst);
  const prevWorst = prev ? num(prev.worstTokensPerSuccess) : null;
  const trendDelta =
    prevWorst !== null && Number.isFinite(worst) ? worst - prevWorst : isInfinite ? 1 : 0;
  return {
    dial: 'token-economy',
    available: true,
    leverage,
    trendDelta,
    current: isInfinite ? Infinity : worst,
    target: tokenBudget,
    headline: `worst ${last.worstSkill ?? '?'} @ ${isInfinite ? '∞' : worst} tok/success vs budget ${tokenBudget}`,
    note: leverage === 0 ? 'worst skill within token budget' : 'worst skill over token budget',
  };
}

/**
 * Read the skill-quality dial from score-skill-quality.mjs trendRow(s).
 * The thrash rate is already a [0,1] rate, so it IS the leverage directly; a
 * mechanical-failure boost nudges ties. trendDelta = rise in worstThrashRate
 * since prior row.
 */
export function readSkillQualityDial(rows, {} = {}) {
  const trendRows = rows.map((r) => r.trendRow ?? r).filter((r) => r && (r.worstThrashRate !== undefined || r.deprecationCandidateCount !== undefined));
  if (trendRows.length === 0) {
    return { dial: 'skill-quality', available: false, note: 'no skill-quality telemetry on the trend surface' };
  }
  const last = trendRows[trendRows.length - 1];
  const prev = trendRows.length > 1 ? trendRows[trendRows.length - 2] : null;
  const thrash = clamp01(num(last.worstThrashRate) ?? 0);
  const failingMech = num(last.skillsFailingMechanical) ?? 0;
  // Thrash rate is the primary leverage; a mechanical failure floors leverage
  // at 0.1 so a purely-mechanical gap (thrash 0 but a broken skill) is still a
  // candidate, never invisible.
  const leverage = clamp01(Math.max(thrash, failingMech > 0 ? 0.1 : 0));
  const prevThrash = prev ? clamp01(num(prev.worstThrashRate) ?? 0) : null;
  const trendDelta = prevThrash !== null ? thrash - prevThrash : 0;
  return {
    dial: 'skill-quality',
    available: true,
    leverage,
    trendDelta,
    current: thrash,
    target: 0,
    headline: `worst ${last.worstSkill ?? '?'} thrash ${thrash}; ${failingMech} skills failing mechanical`,
    note: leverage === 0 ? 'no thrashing or mechanical failure' : 'thrashing/mechanical gap present',
  };
}

/**
 * The PICK: rank available candidate dials and select the single highest-
 * leverage one. Pure — takes the three already-read dial objects.
 *
 * @returns { dials, selected, skipped } — see file header STABLE CONTRACT.
 */
export function selectHighestLeverageGap(dialObjs, { minLeverage = 0.05 } = {}) {
  const dials = dialObjs.filter(Boolean);
  const skipped = [];

  const candidates = [];
  for (const d of dials) {
    if (!d.available) {
      skipped.push({ dial: d.dial, reason: d.note || 'surface unavailable' });
      continue;
    }
    if (!(d.leverage > minLeverage)) {
      skipped.push({ dial: d.dial, reason: `leverage ${round(d.leverage)} ≤ min-leverage ${minLeverage}` });
      continue;
    }
    candidates.push(d);
  }

  candidates.sort((a, b) => {
    if (b.leverage !== a.leverage) return b.leverage - a.leverage;
    if ((b.trendDelta ?? 0) !== (a.trendDelta ?? 0)) return (b.trendDelta ?? 0) - (a.trendDelta ?? 0);
    return DIAL_PRIORITY[b.dial] - DIAL_PRIORITY[a.dial];
  });

  const winner = candidates[0] || null;
  const selected = winner
    ? {
        dial: winner.dial,
        command: DIM_COMMAND[winner.dial],
        leverage: round(winner.leverage),
        rationale: `${winner.dial} is the highest-leverage gap this cycle (${winner.headline}); leverage ${round(winner.leverage)}, trendDelta ${round(winner.trendDelta ?? 0)}`,
      }
    : null;

  return { dials, selected, skipped };
}

function round(n) {
  return Number.isFinite(n) ? Math.round(n * 1000) / 1000 : n;
}

/**
 * Build the durable cycle-delta record the sweep appends to
 * docs/sge/improvement-sweep.jsonl after drift-hillclimb re-measures. This is
 * the "every cycle appends a measured delta" acceptance artefact — one row per
 * cycle whether the cycle acted, skipped, or failed.
 *
 * @param sel selectHighestLeverageGap() result
 * @param outcome { status: 'acted'|'skipped'|'failed', prNumber, before, after,
 *                  error }
 */
export function buildCycleRecord(sel, { repo = 'sge', timestamp, status, prNumber = null, before = null, after = null, error = null } = {}) {
  const ts = timestamp || new Date().toISOString();
  const measuredDelta = before !== null && after !== null ? round(after - before) : null;
  return {
    kind: 'improvement-sweep-cycle',
    repo,
    timestamp: ts,
    status, // acted | skipped | failed — a skipped/failed cycle is visible here
    selectedDial: sel.selected ? sel.selected.dial : null,
    command: sel.selected ? sel.selected.command : null,
    prNumber, // null unless exactly one PR opened this cycle
    before,
    after,
    measuredDelta,
    skipped: sel.skipped,
    error,
  };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = { sm2Target: 85, tokenBudget: 5000, minLeverage: 0.05, repo: 'sge' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const val = () => argv[++i];
    switch (a) {
      case '--coherence': args.coherence = val(); break;
      case '--token': args.token = val(); break;
      case '--skill-quality': args.skillQuality = val(); break;
      case '--audit-score-target': args.sm2Target = Number(val()); break;
      case '--sm2-target': args.sm2Target = Number(val()); break; // legacy alias for --audit-score-target (pre-#834)
      case '--token-budget': args.tokenBudget = Number(val()); break;
      case '--min-leverage': args.minLeverage = Number(val()); break;
      case '--repo': args.repo = val(); break;
      default:
        if (a.startsWith('--')) { process.stderr.write(`Unknown flag: ${a}\n`); process.exit(2); }
    }
  }
  return args;
}

function readOrEmpty(path) {
  if (!path) return '';
  try {
    return readFileSync(path, 'utf8');
  } catch {
    return ''; // unavailable dial — degrade, never crash
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const coherence = readCoherenceDial(parseSurface(readOrEmpty(args.coherence)), { sm2Target: args.sm2Target });
  const token = readTokenDial(parseSurface(readOrEmpty(args.token)), { tokenBudget: args.tokenBudget });
  const skillQuality = readSkillQualityDial(parseSurface(readOrEmpty(args.skillQuality)), {});
  const sel = selectHighestLeverageGap([coherence, token, skillQuality], { minLeverage: args.minLeverage });
  const out = {
    generatedAt: new Date().toISOString(),
    repo: args.repo,
    sm2Target: args.sm2Target,
    tokenBudget: args.tokenBudget,
    minLeverage: args.minLeverage,
    dials: sel.dials,
    selected: sel.selected,
    skipped: sel.skipped,
  };
  process.stdout.write(JSON.stringify(out, null, 2) + '\n');
}

// Run as CLI only when invoked directly, not when imported by the test.
if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith('select-gap.mjs')) {
  main();
}
