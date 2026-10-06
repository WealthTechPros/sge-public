#!/usr/bin/env node
/**
 * design-verdict-gate.mjs — base-relative evaluation of a design-reviewer
 * verdict for the /sge:pr-review design-evidence gate (#2837, SPEC-115 I3).
 *
 * Why: design-reviewer scores the RENDERED page, so a PR that touches one
 * file on a page with existing design debt gets a FAIL for problems it did
 * not introduce. The gate therefore also accepts a FAIL verdict when the
 * reviewer scored the PR's merge-base on the same routes/viewports and
 *   - no finding introduced by the PR scores a rubric category at 0, and
 *   - the head score is not below the base score.
 * Pre-existing findings are reported as follow-up, never silently waived.
 * When no base score was captured the absolute rule applies (FAIL flags).
 *
 * Verdict shape (written by agents/design-reviewer.md):
 *
 *   VERDICT: PASS | FAIL
 *   Score: NN/16
 *   Evidence: live | static — <dir> @ <commit>, ...
 *   Base: NN/16 @ <merge-base sha> | not captured — <reason>
 *   R1 Token discipline: H (base B) — evidence [introduced | pre-existing]
 *   ... (all eight)
 *
 * The `(base B)` and `[introduced|pre-existing]` parts are optional for a
 * PASS verdict and for a verdict without a base. A category at 0 with no tag
 * is treated as introduced (fail closed), and so is a category tagged
 * pre-existing that the base scored above 0 (the PR made it 0).
 *
 * CLI
 *   node design-verdict-gate.mjs <verdict.md | -> [--stale] [--json]
 *   --stale: the pr-review gate found the verdict older than the PR's latest
 *            UI-touching commit (I2): it never passes, under either rule.
 *   Exit 0 = gate passes (pass | base-relative-pass), 1 = flag, 2 = bad args.
 *   Stdout: one human line, or the full decision object with --json.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const RUBRIC_CATEGORIES = 8;
export const MAX_SCORE = RUBRIC_CATEGORIES * 2;

const CATEGORY_RE =
  /^R([1-8])\s+([^:]+?):\s*([0-2])(?:\s*\(\s*base\s+([0-2])\s*\))?(.*)$/i;
const TAG_RE = /\[\s*(introduced|pre-existing)\s*\]/i;

/** Parse verdict text into a structured object. Never throws. */
export function parseVerdict(text) {
  const lines = String(text ?? "").replace(/\r\n?/g, "\n").split("\n");
  const firstLine = lines.find((l) => l.trim() !== "") ?? "";
  const vm = firstLine.trim().match(/^VERDICT:\s*(PASS|FAIL)\s*$/i);
  const verdict = {
    outcome: vm ? vm[1].toUpperCase() : null,
    headScore: null,
    base: { captured: false, score: null, commit: null, reason: null },
    categories: [],
  };
  for (const raw of lines) {
    const line = raw.trim();
    let m;
    if ((m = line.match(/^Score:\s*(\d{1,2})\s*\/\s*16\b/i))) {
      verdict.headScore = Number(m[1]);
    } else if ((m = line.match(/^Base(?:\s+score)?:\s*(\d{1,2})\s*\/\s*16\b(?:\s*@\s*(\S+))?/i))) {
      verdict.base = { captured: true, score: Number(m[1]), commit: m[2] ?? null, reason: null };
    } else if ((m = line.match(/^Base(?:\s+score)?:\s*not captured\b\s*(?:[—–-]\s*)?(.*)$/i))) {
      verdict.base = { captured: false, score: null, commit: null, reason: m[1].trim() || null };
    } else if ((m = line.match(CATEGORY_RE))) {
      const tag = m[5].match(TAG_RE);
      verdict.categories.push({
        id: `R${m[1]}`,
        name: m[2].trim(),
        head: Number(m[3]),
        base: m[4] === undefined ? null : Number(m[4]),
        tag: tag ? tag[1].toLowerCase() : null,
      });
    }
  }
  return verdict;
}

/** A category finding is PR-introduced unless the evidence says otherwise. */
export function attribution(cat) {
  if (cat.tag === "pre-existing") {
    // The base scoring it higher contradicts the tag: the PR caused it.
    if (cat.base !== null && cat.base > cat.head) return "introduced";
    return "pre-existing";
  }
  return "introduced"; // explicit [introduced], or untagged (fail closed)
}

/**
 * Decide the gate for one verdict.
 * Returns { decision: "pass" | "base-relative-pass" | "flag", rule, reasons[],
 *           introducedBlockers[], preExisting[] }.
 */
export function evaluateGate(verdict, { stale = false } = {}) {
  const out = { decision: "flag", rule: "absolute", reasons: [], introducedBlockers: [], preExisting: [] };
  if (stale) {
    out.reasons.push("verdict is stale (predates the PR's latest UI-touching commit) — I2");
    return out;
  }
  if (verdict.outcome === null) {
    out.reasons.push("no 'VERDICT: PASS|FAIL' first line");
    return out;
  }
  const findings = verdict.categories.filter((c) => c.head < 2);
  if (verdict.outcome === "PASS") {
    // I1: a PASS must meet the floor; a malformed PASS is not trusted.
    const zero = verdict.categories.some((c) => c.head === 0);
    if (verdict.headScore === null || verdict.headScore < 14 || zero) {
      out.reasons.push("PASS verdict does not meet the 14/16 + no-zero floor (I1)");
      return out;
    }
    out.decision = "pass";
    out.preExisting = findings.filter((c) => attribution(c) === "pre-existing").map((c) => c.id);
    return out;
  }
  // FAIL: the base-relative rule needs a captured base and a full rubric.
  if (!verdict.base.captured || verdict.base.score === null) {
    out.reasons.push(
      `FAIL with no base score captured${verdict.base.reason ? ` (${verdict.base.reason})` : ""} — absolute rule`,
    );
    return out;
  }
  out.rule = "base-relative";
  if (verdict.headScore === null) {
    out.reasons.push("FAIL verdict has no 'Score: NN/16' line");
    return out;
  }
  if (verdict.categories.length !== RUBRIC_CATEGORIES) {
    out.reasons.push(`rubric incomplete: ${verdict.categories.length}/${RUBRIC_CATEGORIES} categories scored`);
    return out;
  }
  if (verdict.headScore < verdict.base.score) {
    out.reasons.push(`score dropped against base: ${verdict.headScore}/16 < ${verdict.base.score}/16`);
  }
  for (const c of findings) {
    if (attribution(c) === "introduced") {
      if (c.head === 0) out.introducedBlockers.push(c.id);
    } else {
      out.preExisting.push(c.id);
    }
  }
  if (out.introducedBlockers.length) {
    out.reasons.push(`introduced-by-PR blocker(s): ${out.introducedBlockers.join(", ")} scored 0`);
  }
  if (out.reasons.length === 0) out.decision = "base-relative-pass";
  return out;
}

function main(argv) {
  const args = argv.slice(2);
  const stale = args.includes("--stale");
  const json = args.includes("--json");
  const positional = args.filter((a) => a === "-" || !a.startsWith("--"));
  const unknown = args.filter((a) => a.startsWith("--") && a !== "--stale" && a !== "--json");
  if (positional.length !== 1 || unknown.length) {
    process.stderr.write("Usage: design-verdict-gate.mjs <verdict.md | -> [--stale] [--json]\n");
    return 2;
  }
  let text;
  try {
    text = readFileSync(positional[0] === "-" ? 0 : positional[0], "utf8");
  } catch (e) {
    process.stderr.write(`cannot read ${positional[0]}: ${e.message}\n`);
    return 2;
  }
  const decision = evaluateGate(parseVerdict(text), { stale });
  if (json) {
    process.stdout.write(JSON.stringify(decision) + "\n");
  } else {
    const extra = decision.preExisting.length ? `; pre-existing follow-up: ${decision.preExisting.join(", ")}` : "";
    process.stdout.write(`${decision.decision} (${decision.rule})${decision.reasons.length ? ": " + decision.reasons.join("; ") : ""}${extra}\n`);
  }
  return decision.decision === "flag" ? 1 : 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv);
}
