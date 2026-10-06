#!/usr/bin/env node
/**
 * build-ready-prescorer.mjs — authoring-time build-ready gate pre-check for
 * `/sge:build-ready-audit` (#1975, child of #1762 proposal 2; sibling of the
 * size-only issue-prescorer.mjs which covers #1762 proposal 3).
 *
 * Problem: the build-ready gate (skills/build-ready-audit) only runs during a
 * triage sweep — long after an issue is written. The issue-form template
 * (.github/ISSUE_TEMPLATE/task.yml, #1784) gives an author the *shape* of a
 * dispatchable issue, but a template without scoring is just a suggestion: an
 * author gets no feedback that a section is missing or left as the empty
 * skeleton until a sweep rejects it. This module scores the four authoring
 * gates the moment an issue body exists, and names WHICH gate failed and why.
 *
 * It advises, it does not gate — it never blocks issue creation. Nothing here
 * runs on the GitHub issue-create path; it is a dependency-free library + CLI
 * a human, a git hook, or the build-ready-audit skill can run at authoring
 * time. Blank issues stay enabled (config.yml, #1781).
 *
 * The four gates mirror build-ready-audit's own vocabulary (SKILL.md Steps
 * 2A/2B/2C/2D), but at the authoring surface — presence-and-substance of the
 * structured sections the template asks for, NOT the sizing heuristic (that is
 * issue-prescorer.mjs) and NOT the governance classification (governance-trace):
 *
 *   gate           template section     passes when
 *   ─────────────────────────────────────────────────────────────────────────
 *   acceptance     Acceptance criteria  substantive Gherkin steps OR a SPEC-NNN
 *                  (2A)                  link — not the empty Given/When/Then
 *                                        skeleton the form ships as its default
 *   scope          Out of scope (2B)    section present and non-empty — the
 *                                        field that keeps a PR diff tight
 *   dependencies   Dependencies (2D)    section present and non-empty ("None"
 *                                        counts — an undeclared blocker is the
 *                                        failure, a declared "None" is not)
 *   decisions      Decisions needed     section present and non-empty ("None"
 *                  (2C)                  counts). A section naming a REAL open
 *                                        decision passes the authoring gate but
 *                                        emits a routing advisory (needs-decision)
 *
 * verdict = READY when all four gates pass, else NOT_READY (with the failing
 * gate names). Running it on an already-good issue is quiet.
 *
 * CLI (accepts issue body via --body flag or stdin):
 *
 *   node skills/lib/build-ready-prescorer.mjs --body "<issue body text>"
 *   gh issue view 123 --json body --jq .body | node skills/lib/build-ready-prescorer.mjs
 *   ... | node skills/lib/build-ready-prescorer.mjs --json   # full JSON always
 *
 * Human output: quiet one line on READY; the failing gates + reasons on
 * NOT_READY. `--json` always prints the full structured result.
 *
 * Exit codes: 0 success (either verdict — this advises, it never gates) ·
 *             2 usage error.
 * Dependency-free (Node ≥ 18), repo convention for skills/lib/*.mjs.
 */

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/**
 * UNTRUSTED input, no upstream size limit — bound the text before any regex.
 * Set to GitHub's own issue-body cap (65,536 chars) so a legitimate near-max
 * issue is not truncated (which would drop the task.yml template's trailing
 * Dependencies/Decisions sections and score a false NOT_READY).
 */
const MAX_BODY_CHARS = 65_536;

/**
 * Low-content placeholders that must NOT satisfy the acceptance-criteria gate
 * even though they are technically non-empty — a deferral marker is the absence
 * of criteria, not criteria. Matched as the section's sole substantive token.
 */
const ACCEPTANCE_PLACEHOLDERS = new Set(["tbd", "wip", "later", "fixme", "todo", "?", "??", "???", "n/a", "na"]);

/** The four authoring gates, in the template's field order. */
const GATE_KEYS = ["acceptance", "scope", "dependencies", "decisions"];

/**
 * GitHub issue-forms render an empty optional textarea as this exact marker in
 * the submitted body. Treat it (and a genuinely empty section) as "not filled".
 */
const NO_RESPONSE = "_no response_";

/**
 * Heading aliases per gate section. Issue forms render a textarea's `label` as
 * a `### <label>` heading; humans writing free-form use `##`/`###` too. Match
 * case-insensitively and tolerate minor wording ("non-goals", "open questions").
 */
const SECTION_ALIASES = {
  acceptance: ["acceptance criteria", "acceptance-criteria", "acceptance"],
  scope: ["out of scope", "out-of-scope", "non-goals", "non goals"],
  dependencies: ["dependencies", "dependency", "depends on"],
  decisions: ["decisions needed", "decisions-needed", "decisions", "open questions", "open-questions"],
};

/** Values that count as "explicitly none" for the dependencies/decisions gates. */
const NONE_VALUES = new Set(["none", "n/a", "na", "no", "nil", "-", "—"]);

// ---------------------------------------------------------------------------
// Section parsing
// ---------------------------------------------------------------------------

/**
 * Split a markdown body into { headingText(lowercased) -> sectionBody } by
 * ATX headings (`#`..`######`). Content runs from a heading to the next one.
 * A trailing/leading `_No response_` collapses to an empty section body.
 *
 * Fence-aware: a `#`-leading line INSIDE a fenced code block (```/~~~) is not a
 * heading — CommonMark/GitHub do not render ATX headings inside code blocks. A
 * Gherkin `# comment` or a fenced doc-example that shows a `### Dependencies`
 * heading must not flush or clobber the surrounding section (reviewer-found).
 * Fenced lines still belong to the current section's buffer (so an acceptance
 * ```gherkin block is retained for the substance check).
 *
 * @param {string} body
 * @returns {Map<string, string>}
 */
function parseSections(body) {
  const sections = new Map();
  const lines = body.split(/\r?\n/);
  let current = null;
  let buf = [];
  let fence = null; // the opening fence marker (``` or ~~~) while inside a block

  const flush = () => {
    if (current !== null) {
      let content = buf.join("\n").trim();
      if (content.toLowerCase() === NO_RESPONSE) content = "";
      sections.set(current, content);
    }
  };

  for (const line of lines) {
    const fenceMatch = /^\s*(`{3,}|~{3,})/.exec(line);
    if (fenceMatch) {
      const marker = fenceMatch[1][0]; // ` or ~
      if (fence === null) fence = marker;
      else if (fence === marker) fence = null; // closing fence of the same kind
      if (current !== null) buf.push(line);
      continue;
    }

    // Linear heading match: `.*` to EOL then strip closed-ATX trailing hashes
    // with an anchored op. The prior `(.+?)\s*#*\s*$` form backtracks
    // catastrophically (ReDoS) on a long line ending in non-whitespace after a
    // whitespace run — the body is attacker-controlled, so the pattern, not the
    // MAX_BODY_CHARS bound, must be safe (security-review-found).
    const m = fence === null ? /^#{1,6}\s+(.*)$/.exec(line) : null;
    if (m) {
      flush();
      current = m[1].replace(/#+\s*$/, "").trim().toLowerCase();
      buf = [];
    } else if (current !== null) {
      buf.push(line);
    }
  }
  flush();
  return sections;
}

/**
 * Look up a section's content by any of a gate's heading aliases.
 * @returns {string|null} the section body, or null if no matching heading exists
 */
function findSection(sections, aliases) {
  for (const alias of aliases) {
    if (sections.has(alias)) return sections.get(alias);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Gate checks
// ---------------------------------------------------------------------------

/**
 * True when the Acceptance criteria SECTION carries a real criteria signal.
 * Scoped to the section content — a `SPEC-NNN` mention elsewhere in the body
 * (e.g. an aside in Out of scope) must NOT satisfy 2A, and no section at all is
 * an outright fail regardless of what the rest of the body says (reviewer-found).
 */
function hasSubstantiveAcceptance(sectionContent) {
  if (!sectionContent) return false;

  // Criteria may live in a ratified spec referenced in THIS section — the
  // build-ready-audit 2A spec-link path, scoped to the acceptance section.
  if (/\bSPEC-\d+\b/i.test(sectionContent)) return true;
  // A filled Scenario title (not the bare "Scenario:" the form ships). Must be
  // on the SAME line — `\s` would span the newline into the next skeleton step.
  if (/scenario:[ \t]*\S/i.test(sectionContent)) return true;
  // A Given/When/Then step with actual text after the keyword — the empty
  // skeleton the template ships (bare "Given"/"When"/"Then") must NOT count.
  if (/\b(given|when|then)\b[ \t]+\S+/i.test(sectionContent)) return true;

  // Otherwise: substantive only if there is non-Gherkin-scaffold prose. Strip
  // fenced-block markers and the bare skeleton keywords, then require content
  // that is not merely a low-content deferral placeholder (TBD/WIP/…).
  const stripped = sectionContent
    .replace(/```[a-z]*/gi, "")
    .replace(/~~~[a-z]*/gi, "")
    .replace(/^\s*scenario:\s*$/gim, "")
    .replace(/^\s*(given|when|then)\s*$/gim, "")
    .trim();
  if (stripped.length === 0) return false;
  const norm = stripped.toLowerCase().replace(/[^a-z0-9/?]+$/i, "");
  return !ACCEPTANCE_PLACEHOLDERS.has(norm);
}

/**
 * Score an issue body against the four authoring build-ready gates.
 *
 * @param {string} body raw issue body (markdown, as GitHub stores it)
 * @returns {{
 *   verdict: "READY"|"NOT_READY",
 *   gates: Record<string, boolean>,
 *   failed: string[],
 *   reasons: Record<string, string>,
 *   advice: string[]
 * }}
 */
export function prescoreIssue(body) {
  const gates = { acceptance: false, scope: false, dependencies: false, decisions: false };
  const reasons = {};
  const advice = [];

  if (!body || typeof body !== "string" || body.trim() === "") {
    for (const k of GATE_KEYS) reasons[k] = "empty body — nothing to score";
    return { verdict: "NOT_READY", gates, failed: [...GATE_KEYS], reasons, advice };
  }

  // UNTRUSTED input — bound before any regex work.
  if (body.length > MAX_BODY_CHARS) body = body.slice(0, MAX_BODY_CHARS);

  const sections = parseSections(body);

  // --- acceptance (2A) ---
  const acc = findSection(sections, SECTION_ALIASES.acceptance);
  if (hasSubstantiveAcceptance(acc)) {
    gates.acceptance = true;
  } else if (acc === null) {
    reasons.acceptance = "no Acceptance criteria section and no SPEC-NNN link (2A)";
  } else {
    reasons.acceptance = "Acceptance criteria left as the empty Given/When/Then skeleton — no observable behaviour stated (2A)";
  }

  // --- scope / out of scope (2B authoring surface) ---
  const scope = findSection(sections, SECTION_ALIASES.scope);
  if (scope && scope.trim() !== "") {
    gates.scope = true;
  } else {
    reasons.scope =
      scope === null
        ? "no Out of scope section — the field that keeps the PR diff tight is missing (2B)"
        : "Out of scope section is empty — declare the neighbouring work this does NOT cover (2B)";
  }

  // --- dependencies (2D) ---
  const deps = findSection(sections, SECTION_ALIASES.dependencies);
  if (deps && deps.trim() !== "") {
    gates.dependencies = true;
  } else {
    reasons.dependencies =
      deps === null
        ? 'no Dependencies section — declare blockers or write "None" (2D)'
        : 'Dependencies section is empty — declare blockers or write "None" (2D)';
  }

  // --- decisions (2C) ---
  const dec = findSection(sections, SECTION_ALIASES.decisions);
  if (dec && dec.trim() !== "") {
    gates.decisions = true;
    if (!NONE_VALUES.has(dec.trim().toLowerCase())) {
      advice.push(
        "Decisions needed records an open decision — route it to its owner (needs-decision) before dispatch; a decision belonging to a human blocks dispatch even when everything else is defined (2C)"
      );
    }
  } else {
    reasons.decisions =
      dec === null
        ? 'no Decisions needed section — declare open human decisions or write "None" (2C)'
        : 'Decisions needed section is empty — declare open human decisions or write "None" (2C)';
  }

  const failed = GATE_KEYS.filter((k) => !gates[k]);
  const verdict = failed.length === 0 ? "READY" : "NOT_READY";
  return { verdict, gates, failed, reasons, advice };
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/** Map an internal gate key to the author-facing label used in #1975's ACs. */
const GATE_LABEL = {
  acceptance: "criteria",
  scope: "scope",
  dependencies: "dependencies",
  decisions: "decisions",
};

/** Human-readable, quiet-on-READY summary. */
export function renderHuman(result) {
  if (result.verdict === "READY") {
    const tail = result.advice.length > 0 ? `\n${result.advice.map((a) => `  • ${a}`).join("\n")}` : "";
    return `build-ready pre-check: READY — all authoring gates pass (criteria, scope, dependencies, decisions)${tail}`;
  }
  const failedLabels = result.failed.map((k) => GATE_LABEL[k]).join(", ");
  const lines = [`build-ready pre-check: NOT_READY — failing gate(s): ${failedLabels}`];
  for (const k of result.failed) lines.push(`  ✗ ${GATE_LABEL[k]}: ${result.reasons[k]}`);
  for (const a of result.advice) lines.push(`  • ${a}`);
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const USAGE = `Usage: node skills/lib/build-ready-prescorer.mjs [--body "<text>"] [--json]
       gh issue view 123 --json body --jq .body | node skills/lib/build-ready-prescorer.mjs

Scores an issue body against the four authoring build-ready gates and names
which one failed — at authoring time, not only during a triage sweep:

  criteria      Acceptance criteria present (Gherkin) or a SPEC-NNN link (2A)
  scope         Out of scope declared — keeps the PR diff tight (2B)
  dependencies  Dependencies declared ("None" counts) (2D)
  decisions     Decisions needed declared ("None" counts) (2C)

This ADVISES; it never blocks issue creation. Output is quiet on a ready issue.
--json always prints the full result: { verdict, gates, failed, reasons, advice }

Exit codes: 0 success (either verdict) · 2 usage error.`;

async function main(argv) {
  let bodyArg = null;
  let asJson = false;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      console.log(USAGE);
      return 0;
    } else if (arg === "--json") {
      asJson = true;
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
    } else {
      // A bare positional is almost always a forgotten --body flag — surface it
      // as a usage error rather than silently reading empty stdin (reviewer-found).
      console.error(`Unexpected argument: ${JSON.stringify(arg)} — did you mean --body ${JSON.stringify(arg)}?\n\n${USAGE}`);
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
    // Defence-in-depth: stop accumulating well past the body cap so an
    // unbounded pipe cannot exhaust memory before the MAX_BODY_CHARS slice.
    const chunks = [];
    let total = 0;
    const STDIN_CAP = MAX_BODY_CHARS * 4; // bytes; > any real UTF-8 issue body
    for await (const chunk of stdin) {
      chunks.push(chunk);
      total += chunk.length;
      if (total >= STDIN_CAP) break;
    }
    body = Buffer.concat(chunks).toString("utf8");
  }

  const result = prescoreIssue(body);
  console.log(asJson ? JSON.stringify(result, null, 2) : renderHuman(result));
  return 0;
}

// Only run CLI when executed directly (not when imported as a module).
if (
  process.argv[1] &&
  (process.argv[1].endsWith("build-ready-prescorer.mjs") ||
    process.argv[1].endsWith("build-ready-prescorer"))
) {
  main(process.argv.slice(2))
    .then((code) => process.exit(code ?? 0))
    .catch((err) => {
      console.error(err.message);
      process.exit(2);
    });
}
