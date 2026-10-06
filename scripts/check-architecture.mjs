#!/usr/bin/env node
/**
 * check-architecture.mjs — the /sge:sge-align C41 check (SPEC-131 §2.5, #2922).
 *
 * Reports architecture drift for a repo: components with no capability,
 * capabilities the model does not declare, code paths that do not exist, and
 * structural errors in docs/sgd-build/architecture.yaml. Advisory, warn-first:
 * it ALWAYS exits 0. With no artefact the check is N/A, never a failure.
 *
 * Usage: node scripts/check-architecture.mjs [--repo <dir>] [--json]
 * Node built-ins only; the logic lives in packages/sge-dashboard/lib/architecture.mjs.
 */
import path from "node:path";
import { checkArchitecture } from "../packages/sge-dashboard/lib/architecture.mjs";

const args = process.argv.slice(2);
const at = args.indexOf("--repo");
const root = path.resolve(at !== -1 && args[at + 1] ? args[at + 1] : process.cwd());
const result = checkArchitecture(root);

if (args.includes("--json")) {
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
} else if (!result.applicable) {
  console.log(`C41 architecture drift: N/A (${result.reason})`);
} else {
  console.log(`C41 architecture drift: ${result.findings.length} finding(s) (advisory)`);
  for (const f of result.findings) console.log(`  [warn] ${f.kind}: ${f.subject} -- ${f.detail}`);
}
process.exit(0);
