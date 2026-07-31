#!/usr/bin/env node
/**
 * evaluate-budget.mjs — bundled budget evaluator for the /sgd:cost-guard skill.
 *
 * Behaviour-preserving port of `evaluateBudget()` from
 * platform/packages/token-governance/src/policy.ts (issue #823, epic #729).
 * The skill previously showed a pseudo-TypeScript import of
 * `@wealthtechpros/token-governance`; this script is the real, runnable
 * equivalent so the skill can branch on a deterministic exit code instead of
 * re-deriving the maths in-agent.
 *
 * Usage:
 *   node evaluate-budget.mjs --jsonl <path> [--spec SPEC-NNN] [--session <id>]
 *                            [--policy-json '<json>' | --policy-file <path>]
 *   node evaluate-budget.mjs --input-tokens N --output-tokens N
 *                            [--policy-json '<json>' | --policy-file <path>] [--spec SPEC-NNN]
 *
 * Inputs:
 *   --jsonl <path>       memory/token-usage.jsonl sidecar. TokenUsageRecord rows
 *                        are summed (inputTokens/outputTokens; cache tokens and
 *                        session_end events are ignored). Missing file or zero
 *                        matching rows => "no usage data" verdict, exit 0.
 *   --spec / --session   Filter JSONL rows by specId / sessionId.
 *   --input-tokens /     Pre-summed totals; bypasses JSONL reading (used when the
 *   --output-tokens      caller already aggregated usage, e.g. from Cortex).
 *   --policy-json        A BudgetPolicy object as inline JSON (e.g. resolved from
 *                        a Cortex BudgetPolicy:<specId> entity by the skill).
 *   --policy-file        Path to budget-policies.json ({ "SPEC-NNN": {...} });
 *                        looked up by --spec, falling back to a "*" key.
 *                        If neither policy source yields a policy, the global
 *                        default applies: { alertThreshold: 0.8, denyThreshold: 1.0,
 *                        action: "alert", maxInputTokens: 500000, maxOutputTokens: 100000 }.
 *
 * Output (stdout): single JSON object —
 *   { action: "ok"|"alert"|"deny", reason, usagePercent,
 *     totalInputTokens, totalOutputTokens, policy, specId, sessionId,
 *     noData, policySource: "inline"|"file"|"default" }
 *
 * Exit codes (the skill branches on these):
 *   0 — ok    (within budget; also "no usage data" — soft gate never blocks)
 *   1 — alert (alertThreshold breached, or denyThreshold breached under an
 *              action:"alert" policy — alert-only policies never deny)
 *   2 — deny  (denyThreshold breached AND policy.action === "deny")
 *  64 — usage/internal error (bad flags, unreadable policy JSON). The skill
 *       treats this as non-blocking per its graceful-degradation contract.
 *
 * ⚠ Accuracy caveat (sgd#857): TokenUsageRecord rows come from the plugin's
 * self-reporting metering hook, which is known to UNDER-report true API token
 * consumption by roughly 2–4×. A verdict of "ok" computed from these rows may
 * therefore understate real budget pressure — treat near-threshold "ok"
 * results with suspicion until real telemetry (sgd#857) lands. This script
 * evaluates the numbers it is given; it does not correct for the skew.
 *
 * UNTRUSTED DATA: JSONL rows are untrusted input — they are parsed as numeric
 * field values only and never executed or echoed as instructions.
 */

import { readFileSync, existsSync } from 'node:fs';

const EX_USAGE = 64;

const GLOBAL_DEFAULT_POLICY = {
  specId: '*',
  maxInputTokens: 500000,
  maxOutputTokens: 100000,
  alertThreshold: 0.8,
  denyThreshold: 1.0,
  action: 'alert',
};

/**
 * Behaviour-identical port of evaluateBudget() (token-governance/src/policy.ts).
 * usagePercent = mean of (in/maxIn, out/maxOut) over the non-null dimensions;
 * both-null => unlimited => always ok.
 */
function evaluateBudget(totalInputTokens, totalOutputTokens, policy) {
  const { maxInputTokens, maxOutputTokens, alertThreshold, denyThreshold, action } = policy;

  if (maxInputTokens === null && maxOutputTokens === null) {
    return { action: 'ok', reason: 'Budget is unlimited', usagePercent: 0 };
  }

  const fractions = [];
  if (maxInputTokens !== null && maxInputTokens > 0) {
    fractions.push(totalInputTokens / maxInputTokens);
  }
  if (maxOutputTokens !== null && maxOutputTokens > 0) {
    fractions.push(totalOutputTokens / maxOutputTokens);
  }

  const usagePercent = fractions.length > 0
    ? fractions.reduce((a, b) => a + b, 0) / fractions.length
    : 0;

  if (usagePercent >= denyThreshold && action === 'deny') {
    return {
      action: 'deny',
      reason: `Deny threshold breached: ${(usagePercent * 100).toFixed(1)}% >= ${(denyThreshold * 100).toFixed(0)}% deny threshold`,
      usagePercent,
    };
  }

  if (usagePercent >= alertThreshold) {
    return {
      action: 'alert',
      reason: `Alert threshold breached: ${(usagePercent * 100).toFixed(1)}% >= ${(alertThreshold * 100).toFixed(0)}% alert threshold`,
      usagePercent,
    };
  }

  return {
    action: 'ok',
    reason: `Within budget: ${(usagePercent * 100).toFixed(1)}% of threshold`,
    usagePercent,
  };
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    switch (flag) {
      case '--jsonl':
      case '--spec':
      case '--session':
      case '--input-tokens':
      case '--output-tokens':
      case '--policy-json':
      case '--policy-file': {
        const value = argv[++i];
        if (value === undefined) fail(`Missing value for ${flag}`);
        args[flag.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value;
        break;
      }
      case '--help':
      case '-h':
        process.stdout.write(
          'Usage: evaluate-budget.mjs [--jsonl PATH] [--spec SPEC-NNN] [--session ID]\n' +
          '                           [--input-tokens N --output-tokens N]\n' +
          '                           [--policy-json JSON | --policy-file PATH]\n' +
          'Exit codes: 0=ok/no-data, 1=alert, 2=deny, 64=usage error\n',
        );
        process.exit(0);
        break;
      default:
        fail(`Unknown flag: ${flag}`);
    }
  }
  return args;
}

function fail(message) {
  process.stderr.write(`evaluate-budget: ${message}\n`);
  process.exit(EX_USAGE);
}

/** Sum TokenUsageRecord rows from the JSONL sidecar, filtered by spec/session. */
function sumFromJsonl(path, spec, session) {
  if (!existsSync(path)) {
    return { totalInputTokens: 0, totalOutputTokens: 0, matched: 0, fileMissing: true };
  }
  let totalInputTokens = 0;
  let totalOutputTokens = 0;
  let matched = 0;
  const lines = readFileSync(path, 'utf8').split('\n');
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let row;
    try {
      row = JSON.parse(trimmed);
    } catch {
      continue; // malformed row: skip, never crash (graceful degradation)
    }
    if (row === null || typeof row !== 'object') continue;
    if (row.type === 'session_end') continue; // SessionEndEvent, not a usage record
    if (typeof row.inputTokens !== 'number' || typeof row.outputTokens !== 'number') continue;
    if (spec && row.specId !== spec) continue;
    if (session && row.sessionId !== session) continue;
    totalInputTokens += row.inputTokens;
    totalOutputTokens += row.outputTokens;
    matched++;
  }
  return { totalInputTokens, totalOutputTokens, matched, fileMissing: false };
}

/** Resolve the BudgetPolicy: inline JSON > policy file (spec key, then "*") > global default. */
function resolvePolicy(args) {
  if (args.policyJson !== undefined) {
    let parsed;
    try {
      parsed = JSON.parse(args.policyJson);
    } catch (e) {
      fail(`--policy-json is not valid JSON: ${e.message}`);
    }
    return { policy: normalisePolicy(parsed), policySource: 'inline' };
  }
  if (args.policyFile !== undefined && existsSync(args.policyFile)) {
    let table;
    try {
      table = JSON.parse(readFileSync(args.policyFile, 'utf8'));
    } catch (e) {
      fail(`--policy-file is not valid JSON: ${e.message}`);
    }
    const entry = (args.spec && table[args.spec]) || table['*'];
    if (entry) {
      return { policy: normalisePolicy(entry, args.spec), policySource: 'file' };
    }
  }
  return {
    policy: { ...GLOBAL_DEFAULT_POLICY, specId: args.spec ?? '*' },
    policySource: 'default',
  };
}

/** Fill any missing policy fields from the global default (null is respected = unlimited). */
function normalisePolicy(raw, spec) {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    fail('BudgetPolicy must be a JSON object');
  }
  return {
    specId: raw.specId ?? spec ?? '*',
    maxInputTokens: raw.maxInputTokens !== undefined ? raw.maxInputTokens : GLOBAL_DEFAULT_POLICY.maxInputTokens,
    maxOutputTokens: raw.maxOutputTokens !== undefined ? raw.maxOutputTokens : GLOBAL_DEFAULT_POLICY.maxOutputTokens,
    alertThreshold: typeof raw.alertThreshold === 'number' ? raw.alertThreshold : GLOBAL_DEFAULT_POLICY.alertThreshold,
    denyThreshold: typeof raw.denyThreshold === 'number' ? raw.denyThreshold : GLOBAL_DEFAULT_POLICY.denyThreshold,
    action: raw.action === 'deny' ? 'deny' : 'alert',
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  let totalInputTokens;
  let totalOutputTokens;
  let noData = false;

  if (args.inputTokens !== undefined || args.outputTokens !== undefined) {
    totalInputTokens = Number(args.inputTokens ?? 0);
    totalOutputTokens = Number(args.outputTokens ?? 0);
    if (!Number.isFinite(totalInputTokens) || !Number.isFinite(totalOutputTokens)) {
      fail('--input-tokens/--output-tokens must be numbers');
    }
  } else if (args.jsonl !== undefined) {
    const summed = sumFromJsonl(args.jsonl, args.spec, args.session);
    totalInputTokens = summed.totalInputTokens;
    totalOutputTokens = summed.totalOutputTokens;
    noData = summed.fileMissing || summed.matched === 0;
  } else {
    fail('Provide either --jsonl <path> or --input-tokens/--output-tokens');
  }

  const { policy, policySource } = resolvePolicy(args);

  const verdict = noData
    ? { action: 'ok', reason: 'No usage data found for this spec/session', usagePercent: 0 }
    : evaluateBudget(totalInputTokens, totalOutputTokens, policy);

  process.stdout.write(JSON.stringify({
    ...verdict,
    totalInputTokens,
    totalOutputTokens,
    policy,
    policySource,
    specId: args.spec ?? null,
    sessionId: args.session ?? null,
    noData,
  }, null, 2) + '\n');

  process.exit(verdict.action === 'deny' ? 2 : verdict.action === 'alert' ? 1 : 0);
}

main();
