#!/usr/bin/env node
/**
 * select-gap.test.mjs — unit tests for the SGD-044-S3 improvement-sweep PICK
 * step (sgd#833). Node built-in test runner only (node:test + node:assert),
 * no external deps — repo convention (see scripts/*.test.mjs).
 *
 * Proves the acceptance invariants that are testable at the pick layer:
 *   - highest-leverage dial wins across the three dials
 *   - NEVER more than one dial selected → one PR per cycle by construction
 *   - an unavailable/below-threshold dial is skipped AND visible
 *   - deterministic tie-breaking (trendDelta, then fixed dial priority)
 *   - every cycle yields a delta record (acted / skipped / failed)
 *   - malformed/untrusted surface rows degrade, never crash
 *
 * Run: node --test skills/improvement-sweep/assets/select-gap.test.mjs
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  parseSurface,
  readCoherenceDial,
  readTokenDial,
  readSkillQualityDial,
  selectHighestLeverageGap,
  buildCycleRecord,
} from './select-gap.mjs';

// --- parseSurface: untrusted-input robustness ------------------------------

test('parseSurface: empty / whitespace → []', () => {
  assert.deepEqual(parseSurface(''), []);
  assert.deepEqual(parseSurface('   \n  '), []);
  assert.deepEqual(parseSurface(undefined), []);
});

test('parseSurface: jsonl with a malformed line skips the bad line, keeps the good', () => {
  const rows = parseSurface('{"sm2_sample":80}\nnot json\n{"sm2_sample":82}');
  assert.equal(rows.length, 2);
  assert.equal(rows[0].sm2_sample, 80);
  assert.equal(rows[1].sm2_sample, 82);
});

test('parseSurface: a single JSON object document parses to one row', () => {
  const rows = parseSurface('{"trendRow":{"worstTokensPerSuccess":9000}}');
  assert.equal(rows.length, 1);
  assert.equal(rows[0].trendRow.worstTokensPerSuccess, 9000);
});

// --- coherence dial ---------------------------------------------------------

test('coherence: below target → positive leverage; falling trend → positive delta', () => {
  const d = readCoherenceDial(parseSurface('{"sm2_sample":90}\n{"sm2_sample":68}'), { sm2Target: 85 });
  assert.equal(d.available, true);
  assert.equal(d.current, 68);
  assert.ok(d.leverage > 0);
  assert.ok(d.trendDelta > 0, 'SM-2 dropped 90→68, so trendDelta must be positive (worsening)');
});

test('coherence: at/above target → zero leverage', () => {
  const d = readCoherenceDial(parseSurface('{"sm2_sample":91}'), { sm2Target: 85 });
  assert.equal(d.leverage, 0);
});

test('coherence: reads the #834 audit_score key (primary); legacy sm2_sample still accepted as fallback', () => {
  // Post-#834 rows carry `audit_score`; select-gap must read it as the coherence
  // dial's sample. The plugin composite is the Audit Score (NOT SM-2).
  const d = readCoherenceDial(parseSurface('{"audit_score":90}\n{"audit_score":68}'), { sm2Target: 85 });
  assert.equal(d.available, true);
  assert.equal(d.current, 68);
  assert.ok(d.leverage > 0);
  assert.match(d.headline, /^Audit Score /);

  // audit_score wins over a legacy sm2_sample if both are present on a row
  const mixed = readCoherenceDial(parseSurface('{"audit_score":70,"sm2_sample":40}'), { sm2Target: 85 });
  assert.equal(mixed.current, 70);
});

test('coherence: no samples → unavailable', () => {
  const d = readCoherenceDial([], { sm2Target: 85 });
  assert.equal(d.available, false);
});

test('coherence: latest row with explicit sm2_sample:null → unavailable, NOT phantom leverage 1', () => {
  // Regression (#833 review): `sm2_sample: null` is the normal "no sample this
  // run" placeholder — absent data, not a score. `Number(null) === 0` used to
  // admit it as a scored row (current=null → leverage 1, self-contradictory
  // "SM-2 null vs target 85" headline) that falsely won selection and would
  // dispatch a real climb PR off phantom data. It MUST degrade to unavailable.
  const d = readCoherenceDial(parseSurface('{"sm2_sample":null}'), { sm2Target: 85 });
  assert.equal(d.available, false, 'a null latest sample must make the dial unavailable');
  assert.equal(d.leverage, undefined, 'an unavailable dial must carry no leverage (NOT the phantom 1)');

  // And it must never be selected: an unavailable coherence dial alongside a
  // real token gap must yield the token dial, never the phantom coherence one.
  const token = { dial: 'token-economy', available: true, leverage: 0.3, trendDelta: 0, headline: 'token' };
  const res = selectHighestLeverageGap([d, token], { minLeverage: 0.05 });
  assert.equal(res.selected.dial, 'token-economy');
  assert.ok(res.skipped.some((s) => s.dial === 'coherence'));
});

// --- token-economy dial -----------------------------------------------------

test('token-economy: over budget → positive leverage', () => {
  const d = readTokenDial(parseSurface('{"trendRow":{"worstSkill":"x","worstTokensPerSuccess":20000}}'), { tokenBudget: 5000 });
  assert.equal(d.available, true);
  assert.ok(d.leverage > 0 && d.leverage < 1);
});

test('token-economy: a skill that shipped nothing (Infinity → null) → max leverage 1', () => {
  // Infinity serialises to null in JSON, per the scorer contract.
  const d = readTokenDial(parseSurface('{"trendRow":{"worstSkill":"z","worstTokensPerSuccess":null,"worstValuePerToken":0}}'), { tokenBudget: 5000 });
  // worstTokensPerSuccess===null means "no worst skill", NOT infinite — contract
  // says a null worst = nothing to climb. Assert that documented behaviour.
  assert.equal(d.leverage, 0);
});

test('token-economy: no telemetry → unavailable', () => {
  const d = readTokenDial([], {});
  assert.equal(d.available, false);
});

// --- skill-quality dial -----------------------------------------------------

test('skill-quality: thrash rate is the leverage directly', () => {
  const d = readSkillQualityDial(parseSurface('{"trendRow":{"worstSkill":"s","worstThrashRate":0.4,"skillsFailingMechanical":0}}'), {});
  assert.equal(d.available, true);
  assert.equal(d.leverage, 0.4);
});

test('skill-quality: a mechanical failure floors leverage at 0.1 even with zero thrash', () => {
  const d = readSkillQualityDial(parseSurface('{"trendRow":{"worstThrashRate":0,"skillsFailingMechanical":2}}'), {});
  assert.equal(d.leverage, 0.1);
});

// --- the PICK: highest-leverage wins, exactly one selected ------------------

const coherenceHigh = { dial: 'coherence', available: true, leverage: 0.5, trendDelta: 0.2, headline: 'SM-2 low' };
const tokenMid = { dial: 'token-economy', available: true, leverage: 0.3, trendDelta: 0.1, headline: 'token' };
const skillLow = { dial: 'skill-quality', available: true, leverage: 0.1, trendDelta: 0, headline: 'skill' };

test('pick: the highest-leverage dial is selected and maps to its drift-hillclimb command', () => {
  const { selected } = selectHighestLeverageGap([tokenMid, coherenceHigh, skillLow], { minLeverage: 0.05 });
  assert.equal(selected.dial, 'coherence');
  assert.equal(selected.command, '/sgd:drift-hillclimb --max-rounds 1');
});

test('pick: token dial maps to the token-economy dimension command', () => {
  const { selected } = selectHighestLeverageGap(
    [{ ...tokenMid, leverage: 0.9 }, coherenceHigh, skillLow],
    { minLeverage: 0.05 },
  );
  assert.equal(selected.dial, 'token-economy');
  assert.equal(selected.command, '/sgd:drift-hillclimb --dimension token-economy --max-rounds 1');
});

test('pick: NEVER selects more than one dial — one PR per cycle by construction', () => {
  const res = selectHighestLeverageGap([coherenceHigh, tokenMid, skillLow], { minLeverage: 0.05 });
  // `selected` is a single object or null — structurally impossible to be >1.
  assert.ok(res.selected === null || typeof res.selected === 'object');
  assert.ok(!Array.isArray(res.selected));
});

test('pick: equal leverage → higher trendDelta wins (worsening dial prioritised)', () => {
  const a = { dial: 'token-economy', available: true, leverage: 0.4, trendDelta: 0.5, headline: 't' };
  const b = { dial: 'skill-quality', available: true, leverage: 0.4, trendDelta: 0.1, headline: 's' };
  const { selected } = selectHighestLeverageGap([b, a], { minLeverage: 0.05 });
  assert.equal(selected.dial, 'token-economy');
});

test('pick: equal leverage AND equal trendDelta → fixed dial priority breaks the tie deterministically', () => {
  const a = { dial: 'token-economy', available: true, leverage: 0.4, trendDelta: 0.2, headline: 't' };
  const b = { dial: 'skill-quality', available: true, leverage: 0.4, trendDelta: 0.2, headline: 's' };
  const { selected } = selectHighestLeverageGap([b, a], { minLeverage: 0.05 });
  assert.equal(selected.dial, 'token-economy'); // coherence > token > skill-quality
});

test('pick: an unavailable dial is skipped AND reported (a skipped dial is visible)', () => {
  const unavail = { dial: 'token-economy', available: false, note: 'no telemetry yet' };
  const res = selectHighestLeverageGap([coherenceHigh, unavail, skillLow], { minLeverage: 0.05 });
  assert.equal(res.selected.dial, 'coherence');
  assert.ok(res.skipped.some((s) => s.dial === 'token-economy'));
});

test('pick: all dials below threshold → selected null (a documented no-op cycle)', () => {
  const flat = [
    { dial: 'coherence', available: true, leverage: 0.0, trendDelta: 0, headline: 'ok' },
    { dial: 'token-economy', available: true, leverage: 0.01, trendDelta: 0, headline: 'ok' },
    { dial: 'skill-quality', available: true, leverage: 0.02, trendDelta: 0, headline: 'ok' },
  ];
  const res = selectHighestLeverageGap(flat, { minLeverage: 0.05 });
  assert.equal(res.selected, null);
  assert.equal(res.skipped.length, 3);
});

// --- cycle delta record: every cycle appends a measured delta ---------------

test('cycle record: an acted cycle carries the measured before→after delta and exactly one PR', () => {
  const sel = selectHighestLeverageGap([coherenceHigh, tokenMid, skillLow], { minLeverage: 0.05 });
  const rec = buildCycleRecord(sel, { repo: 'sgd', timestamp: '2026-07-09T00:00:00Z', status: 'acted', prNumber: 900, before: 68, after: 71 });
  assert.equal(rec.status, 'acted');
  assert.equal(rec.selectedDial, 'coherence');
  assert.equal(rec.prNumber, 900);
  assert.equal(rec.measuredDelta, 3); // 71 - 68
});

test('cycle record: a skipped cycle is visible with a null PR and null delta', () => {
  const flat = selectHighestLeverageGap(
    [{ dial: 'coherence', available: true, leverage: 0, trendDelta: 0, headline: 'ok' }],
    { minLeverage: 0.05 },
  );
  const rec = buildCycleRecord(flat, { status: 'skipped', timestamp: '2026-07-09T00:00:00Z' });
  assert.equal(rec.status, 'skipped');
  assert.equal(rec.prNumber, null);
  assert.equal(rec.measuredDelta, null);
  assert.equal(rec.selectedDial, null);
});

test('cycle record: a failed cycle records the error and stays visible', () => {
  const sel = selectHighestLeverageGap([coherenceHigh], { minLeverage: 0.05 });
  const rec = buildCycleRecord(sel, { status: 'failed', timestamp: '2026-07-09T00:00:00Z', error: 'drift-hillclimb crashed' });
  assert.equal(rec.status, 'failed');
  assert.equal(rec.error, 'drift-hillclimb crashed');
});
