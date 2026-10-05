#!/usr/bin/env node
/**
 * resolve-governance-tier.mjs — proportional-governance tier (T0/T1/T2) for
 * `/sge:sge-implement` Phase 2 and `/sge:pr-review` (proposal: "sge v5.0.0
 * tiered proportional governance").
 *
 * Sibling to `resolve-context-depth.mjs`, deliberately kept separate from it.
 * `resolve-context-depth.mjs` answers "how much governance CONTEXT should be
 * read while implementing this?" (digest / scoped / full) — a Phase 2.5
 * concern, UNCHANGED by this module. This module answers a different
 * question: "how much governance PROCESS should this change pay for?" — does
 * Phase 0.5 fork `/sge:governance-trace`, does Phase 5 run a pre-PR
 * `/sge:sge-review`, and how deep does `/sge:pr-review`'s own pass go. Two
 * independent axes: a change can legitimately read full spec context (because
 * it touches a spec's own module) while still being process-light (a 3-line
 * fix with a trivial blast radius), or vice versa.
 *
 * Tiers:
 *   T0 — fast lane.     no-spec lane, score <= 15, risk = low.
 *   T1 — standard lane. no-spec lane, score 16-30, risk = low.
 *   T2 — audit-grade.   spec lane (ALWAYS, any score) OR risk = high OR
 *                        score > 30 (Large — already forces decomposition
 *                        in Phase 2, so this leg is a defensive label, not a
 *                        new enforcement point).
 *
 * Path risk always outranks score: a 5-line change to an auth file is T2.
 * Spec-lane work is always T2 — this tier is the audit-grade artefact WTP
 * sells to clients; only the no-spec (chore/infra) lane is eligible for
 * T0/T1. This is a deliberate, load-bearing design choice, not an oversight —
 * see the PR description for the rationale and its one honest caveat (the
 * Phase 0.5 fork-skip stays narrower than a strict T0 reading would allow).
 *
 * Risk classification reuses `resolve-context-depth.mjs`'s exported
 * CRITICAL_RE (security/auth, DB migrations, multi-tenant / data-isolation)
 * and extends it with four more risk classes named in the proportional-
 * governance plan: PII handling, docs/compliance/**, trust-fabric evidence
 * paths, and regulatory-trace outputs. Over-matching is SAFE here (worst
 * case: an eligible T0/T1 change pays the T2 tax); under-matching is not, so
 * these patterns err toward inclusion exactly like CRITICAL_RE does.
 *
 * Two more risk classes close gaps found in security-auditor review of this
 * PR (confirmed via design pass with the repo owner):
 *
 *   - GOVERNANCE_SELF_RE (gap 1 — governance self-reference). None of the
 *     above covers the governance system's OWN infrastructure — a no-spec,
 *     low-score edit to `.github/**`, `skills/**`, `.claude/**`, `hooks/**`,
 *     `docs/specs/**`, `docs/decisions/**`, or this module's own sibling
 *     scripts (`scripts/resolve-*.mjs`) previously resolved T0 and skipped
 *     review entirely — including edits to the merge gate, hook scripts, or
 *     the skill files that define the review process itself. NOTE: there is
 *     a SEPARATE, already-existing `SENSITIVE_RE` deny in
 *     `.github/workflows/sge-auto-merge.yml` (sge#2521/#2563) that already
 *     covers `.github/**` at the auto-merge-GATE layer; this risk class is
 *     the earlier REVIEW-tier layer (this file), and closes the same class
 *     of gap one layer up for the paths the auto-merge deny does not cover
 *     (`skills/`, `.claude/`, `docs/specs/`, `hooks/`).
 *
 *   - UI_TOUCHING_RE (gap 3 — UI exemption). T0/T1 previously had no
 *     awareness that `/sge:pr-review`'s Phase 4.5 design-evidence gate
 *     (`skills/pr-review/references/design-evidence.md`) explicitly does
 *     NOT exempt `SGE_UNATTENDED=1`/T0-shaped PRs from needing a passing
 *     design-reviewer verdict — T0 skipping Phases 4.3-4.6 unconditionally
 *     silently overrode that invariant for any small UI change that
 *     happened to touch no other risk-class path. This reuses
 *     `hooks/ui-edit-tracker.sh`'s UI-file glob BYTE-FOR-BYTE (single
 *     source of truth: that hook's own "UI-file glob" case block, which is
 *     itself kept in sync with design-evidence.md's "UI-touching detection"
 *     list — update all three together if the glob ever changes).
 *     Deliberately does NOT replicate that hook's `primitives/` exemption:
 *     this risk map's own doctrine (above) is "over-matching is safe, under-
 *     matching is not", so a primitives-exempt UI file still forces T2 here
 *     even though the design-evidence gate itself wouldn't have required a
 *     verdict for it — the safe direction to err.
 *
 *   - DUAL_BACKEND_PROXY_RE (gap 3 — seam/dual-backend exemption). The
 *     seam-evidence gate (`skills/pr-review/references/seam-evidence.md`,
 *     Phase 4.4) detects a dual-backend surface via a diff-content heuristic
 *     (a `*Demo*`/`*Mock*`/`*Fixture*` provider paired with a
 *     `*Warehouse*`/`*Real*`/`*Live*` one behind a shared interface) or an
 *     authoritative `## Seam evidence` spec section — NEITHER of which is a
 *     simple path glob this module can replicate exactly from a path list
 *     alone. This is a CONSERVATIVE PATH-BASED PROXY, not a faithful port of
 *     that detection: it only catches paths that literally name the
 *     convention (`seam`/`seams`, `dual-backend`). It will under-match a
 *     dual-backend surface whose paths don't literally say so — that residual
 *     gap is a known, documented limitation, not a claim of full coverage.
 *     See `skills/sge-implement/references/governance-tier.md` for the same
 *     caveat stated for PR-facing readers.
 *
 * CLI:
 *   node scripts/resolve-governance-tier.mjs \
 *     --paths "a.ts,b.ts" --score 8 --lane no-spec [--score-unknown-floor T1]
 *
 * Prints JSON on stdout. Exit codes: 0 resolved · 2 usage error.
 * Dependency-free (Node >= 18), repo convention for scripts/*.mjs.
 */

import { CRITICAL_RE } from "./resolve-context-depth.mjs";

function normalisePath(p) {
  let s = String(p).replace(/\\/g, "/").replace(/\/{2,}/g, "/");
  s = s.replace(/^\.\//, "").replace(/^\//, "");
  return s.replace(/\/+$/, "");
}

// Additional risk classes beyond CRITICAL_RE's auth/migrations/multi-tenant —
// named explicitly in the proportional-governance plan. Kept as a separate,
// named export so callers/tests can reason about "why did this path force
// T2" without re-deriving the union.
export const RISK_EXTRA_RE = [
  // PII handling
  /(^|\/)(pii|personal-?data|gdpr|dsar|data-subject)([/._-]|$)/i,
  // compliance artefacts (AI/infosec risk register, policies, DD records)
  /^docs\/compliance\//i,
  // trust-fabric evidence store / control-evidence paths
  /(^|\/)trust-fabric([/._-]|$)/i,
  /(^|\/)evidence(\/|$)/i,
  // regulatory-trace outputs (this repo's own /sge:regulatory-trace skill
  // and any product's generated regulatory-trace artefacts)
  /(^|\/)regulatory-trace([/._-]|$)/i,
];

// Gap 1 (governance self-reference): the governance system's OWN
// infrastructure. A no-spec, low-score edit here must never resolve T0 —
// it forces T2 unconditionally, same as every other class in RISK_RE. Kept
// as its own named export (mirrors RISK_EXTRA_RE) so callers/tests can
// reason about "why did this path force T2" without re-deriving the union.
// See the header comment above for the full rationale and the note on the
// separate, already-existing `.github/**` deny in sge-auto-merge.yml.
export const GOVERNANCE_SELF_RE = [
  /^\.github\//i,
  /^skills\//i,
  /^\.claude\//i,
  /^hooks\//i,
  /^docs\/specs\//i,
  /^docs\/decisions\//i,
  // this module's own siblings (resolve-governance-tier.mjs,
  // resolve-context-depth.mjs, and any future scripts/resolve-*.mjs)
  /^scripts\/resolve-[^/]*\.mjs$/i,
];

// Gap 3a (UI exemption): reused BYTE-FOR-BYTE from hooks/ui-edit-tracker.sh's
// "UI-file glob" case block (that hook's own comment: "kept in sync with
// skills/pr-review/references/design-evidence.md's 'UI-touching detection'
// list; if you change this glob, update that doc too" — this array is now a
// THIRD place that must stay in sync with the same source of truth):
//
//   *.tsx|*.jsx|*.vue|*.svelte
//   *.css|*.scss|*.less
//   *.html
//
// Deliberately does NOT replicate that hook's `primitives/` exemption — see
// the header comment's rationale (over-matching is this risk map's safe
// direction).
export const UI_TOUCHING_RE = [
  /\.(tsx|jsx|vue|svelte)$/i,
  /\.(css|scss|less)$/i,
  /\.html$/i,
];

// Gap 3b (dual-backend/seam exemption): a CONSERVATIVE, path-only PROXY for
// seam-evidence.md's diff-content/spec-section heuristic — see the header
// comment for why this is a proxy, not a port, and its known under-match
// limitation.
export const DUAL_BACKEND_PROXY_RE = [
  /(^|\/)seams?([/._-]|$)/i,
  /(^|\/)dual-backend([/._-]|$)/i,
];

// The full risk map this module enforces = CRITICAL_RE (imported) ∪
// RISK_EXTRA_RE ∪ GOVERNANCE_SELF_RE ∪ UI_TOUCHING_RE ∪
// DUAL_BACKEND_PROXY_RE. Exported combined for convenience.
export const RISK_RE = [
  ...CRITICAL_RE,
  ...RISK_EXTRA_RE,
  ...GOVERNANCE_SELF_RE,
  ...UI_TOUCHING_RE,
  ...DUAL_BACKEND_PROXY_RE,
];

const SMALL_SCORE_MAX = 15; // mirrors sge-implement Phase 2's Small bound
const MEDIUM_SCORE_MAX = 30; // mirrors sge-implement Phase 2's Medium bound

function classifyRisk(paths) {
  const norm = (paths || []).map(normalisePath).filter(Boolean);
  const riskyPaths = norm.filter((p) => RISK_RE.some((re) => re.test(p))).sort();
  if (riskyPaths.length > 0) {
    return { level: "high", riskyPaths, reason: `risk-class path(s): ${riskyPaths.join(", ")}` };
  }
  if (norm.length === 0) {
    // Fail toward inclusion: an unclassifiable/empty path set is never
    // treated as provably safe.
    return { level: "unknown", riskyPaths: [], reason: "no paths supplied — risk cannot be ruled out" };
  }
  return { level: "low", riskyPaths: [], reason: "no risk-class path touched" };
}

/**
 * Resolve the T0/T1/T2 governance tier.
 *
 * @param {{
 *   paths?: string[],
 *   complexityScore?: number|null,
 *   lane?: "spec"|"no-spec"|null,
 * }} [input]
 * @returns {{
 *   tier: "T0"|"T1"|"T2",
 *   reason: string,
 *   lane: "spec"|"no-spec"|null,
 *   complexityScore: number|null,
 *   risk: {level: "low"|"high"|"unknown", riskyPaths: string[], reason: string},
 *   forkGovernanceTrace: boolean,
 *   runPhase5Review: boolean,
 *   prReviewMode: "lightweight"|"correctness-subset"|"full"
 * }}
 */
export function resolveGovernanceTier(input = {}) {
  const { paths = [], complexityScore = null, lane = null } = input || {};
  const score =
    complexityScore === null || complexityScore === undefined || Number.isNaN(Number(complexityScore))
      ? null
      : Number(complexityScore);
  const risk = classifyRisk(paths);

  const finish = (tier, reason) => ({
    tier,
    reason,
    lane,
    complexityScore: score,
    risk,
    forkGovernanceTrace: tier !== "T0",
    runPhase5Review: tier === "T2",
    prReviewMode: tier === "T0" ? "lightweight" : tier === "T1" ? "correctness-subset" : "full",
  });

  // 1. Spec-lane work is always audit-grade — the tier this PR proposal
  //    explicitly keeps unchanged and does not discount by score.
  if (lane === "spec") {
    return finish("T2", "spec-lane work is always audit-grade (T2), regardless of score");
  }

  // 2. Risk always outranks score — a 5-line auth-file change is still T2.
  if (risk.level === "high" || risk.level === "unknown") {
    return finish("T2", risk.reason + " — forces T2");
  }

  // 3. Lane not conclusively no-spec (null/unset) — fail toward the safer,
  //    still-governed T1, never the fast lane, mirroring
  //    resolve-context-depth.mjs's "fail toward inclusion" doctrine.
  if (lane !== "no-spec") {
    return finish("T1", `lane not confirmed no-spec (got ${JSON.stringify(lane)}) — fails safe to T1`);
  }

  // 4. Score-driven split within the no-spec, low-risk lane.
  if (score === null) {
    return finish("T1", "no complexity score supplied — fails safe to T1, never T0");
  }
  if (score > MEDIUM_SCORE_MAX) {
    return finish("T2", `score ${score} > ${MEDIUM_SCORE_MAX} (Large) — decompose first; not T0/T1-eligible`);
  }
  if (score <= SMALL_SCORE_MAX) {
    return finish("T0", `no-spec lane, score ${score} <= ${SMALL_SCORE_MAX}, no risk path — fast lane`);
  }
  return finish("T1", `no-spec lane, score ${score} in (${SMALL_SCORE_MAX}, ${MEDIUM_SCORE_MAX}], no risk path — standard lane`);
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const USAGE = `Usage: node scripts/resolve-governance-tier.mjs [--paths "a,b,c"] [--score N] [--lane spec|no-spec] [path ...]

Resolves the proportional-governance tier (T0/T1/T2) for /sge:sge-implement
Phase 2 and /sge:pr-review:
  T0 -> fast lane      (no-spec, score <= 15, no risk path)
  T1 -> standard lane  (no-spec, score 16-30, no risk path — or any signal missing/ambiguous)
  T2 -> audit-grade     (spec lane, OR a risk-class path touched, OR score > 30 — UNCHANGED pipeline)

Prints JSON: { tier, reason, lane, complexityScore, risk, forkGovernanceTrace,
  runPhase5Review, prReviewMode }.
Exit codes: 0 resolved · 2 usage error.`;

function main(argv) {
  const paths = [];
  let score = null;
  let lane = null;
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
    } else if (arg === "--lane") {
      const v = argv[++i];
      if (v !== "spec" && v !== "no-spec") {
        console.error(`--lane must be "spec" or "no-spec", got ${JSON.stringify(v)}\n\n${USAGE}`);
        return 2;
      }
      lane = v;
    } else if (arg.startsWith("--")) {
      console.error(`Unknown option: ${arg}\n\n${USAGE}`);
      return 2;
    } else {
      paths.push(arg);
    }
  }
  console.log(JSON.stringify(resolveGovernanceTier({ paths, complexityScore: score, lane }), null, 2));
  return 0;
}

if (
  import.meta.url === `file://${process.argv[1]}` ||
  process.argv[1]?.endsWith("resolve-governance-tier.mjs")
) {
  process.exit(main(process.argv.slice(2)));
}
