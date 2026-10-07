#!/usr/bin/env node
/**
 * check-artefact-schemas.mjs — the /sge:sge-align C42 check (SPEC-133, #2923).
 *
 * Validates a repo's SGE artefacts (vision, capability model, feature specs,
 * ADRs, architecture) against the JSON Schemas in docs/schemas/ and reports
 * each violation with its file and field. Advisory, warn-first: it exits 0
 * unless --strict is given and there is a violation. A repo with no SGE
 * artefacts is N/A, never a failure.
 *
 * Usage: node scripts/check-artefact-schemas.mjs [--repo <dir>] [--json] [--strict]
 * Node built-ins only; the logic lives in scripts/artefact-schemas.mjs.
 */
import path from "node:path";
import { discoverArtefacts, validateArtefacts, exitCodeFor } from "./artefact-schemas.mjs";

const args = process.argv.slice(2);
const at = args.indexOf("--repo");
const root = path.resolve(at !== -1 && args[at + 1] ? args[at + 1] : process.cwd());
const strict = args.includes("--strict");

const artefacts = discoverArtefacts(root);
const result = artefacts.length
  ? {
      check: "C42",
      applicable: true,
      artefacts: artefacts.length,
      findings: validateArtefacts(root).map((f) => ({ check: "C42", ...f })),
    }
  : { check: "C42", applicable: false, reason: "no SGE artefacts in this repo (not onboarded yet)", findings: [] };

if (args.includes("--json")) {
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
} else if (!result.applicable) {
  console.log(`C42 artefact schemas: N/A (${result.reason})`);
} else {
  console.log(`C42 artefact schemas: ${result.findings.length} violation(s) in ${result.artefacts} artefact(s)${strict ? "" : " (advisory)"}`);
  for (const f of result.findings) console.log(`  [warn] ${f.kind}: ${f.file}: ${f.detail}`);
}
process.exit(exitCodeFor(result.findings, { strict }));
