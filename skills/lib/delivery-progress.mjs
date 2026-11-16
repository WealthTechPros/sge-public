#!/usr/bin/env node
// Evaluates declared delivery evidence; never executes actions or grants authority.
import { realpathSync } from "node:fs";
import { isDeepStrictEqual } from "node:util";
import { pathToFileURL } from "node:url";

const levels = ["source", "publication", "runtime", "acceptance"];
const operations = ["read", "source-change", "publish", "deploy", "access-change", "message", "destructive"];
const invalid = () => { throw new Error("Invalid delivery contract."); };
const text = (value) => {
  if (typeof value !== "string" || !value.trim() || value.length > 2048) invalid();
};
const optionalText = (value) => { if (value !== null) text(value); };
const list = (value) => {
  if (!Array.isArray(value) || value.length > 200) invalid();
};
function object(value, keys) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).length !== keys.length ||
      keys.some(key => !Object.hasOwn(value, key))) invalid();
}
function validateAction(action) {
  object(action, ["operation", "target", "revision", "conditions"]);
  if (!operations.includes(action.operation)) invalid();
  text(action.target);
  text(action.revision);
  list(action.conditions);
  action.conditions.forEach(text);
}
function validateProof(proof) {
  object(proof, ["level", "gate", "state", "evidence"]);
  if (!levels.includes(proof.level) || !["passed", "blocked", "unknown"].includes(proof.state)) invalid();
  text(proof.gate);
  text(proof.evidence);
}
function validateProofs(proofs) {
  list(proofs);
  proofs.forEach(validateProof);
  if (new Set(proofs.map(proof => `${proof.level}:${proof.gate}`)).size !== proofs.length) invalid();
}

export function assessDelivery(input) {
  object(input, ["version", "outcome", "evidenceLevel", "route", "nextProof",
    "addedPrerequisites", "baseline", "attempts", "action", "approvals"]);
  if (input.version !== 1 || !["source", "runtime"].includes(input.evidenceLevel)) invalid();
  text(input.outcome);
  text(input.nextProof);
  object(input.route, ["existing", "selected", "replacementEvidence"]);
  text(input.route.existing);
  text(input.route.selected);
  optionalText(input.route.replacementEvidence);
  list(input.addedPrerequisites);
  for (const prerequisite of input.addedPrerequisites) {
    object(prerequisite, ["description", "necessityEvidence"]);
    text(prerequisite.description);
    optionalText(prerequisite.necessityEvidence);
  }
  validateProofs(input.baseline);
  list(input.attempts);
  for (const attempt of input.attempts) {
    if (attempt && Object.hasOwn(attempt, "reassessment")) {
      object(attempt, ["reassessment"]);
      text(attempt.reassessment);
    } else {
      object(attempt, ["proofs"]);
      validateProofs(attempt.proofs);
    }
  }
  validateAction(input.action);
  list(input.approvals);
  for (const approval of input.approvals) {
    object(approval, ["action", "reference", "state"]);
    validateAction(approval.action);
    text(approval.reference);
    if (!["current", "expired", "unknown"].includes(approval.state)) invalid();
  }
  // One state per reference, so a superseded approval cannot ride on an older "current" entry.
  if (new Set(input.approvals.map(item => item.reference)).size !== input.approvals.length) invalid();

  const reasons = [];
  if (input.route.existing.trim() !== input.route.selected.trim() && !input.route.replacementEvidence) {
    reasons.push("Establish why the existing route cannot deliver before replacing it.");
  }
  if (input.addedPrerequisites.some(item => !item.necessityEvidence)) {
    reasons.push("Separate unproven prerequisites from first delivery.");
  }

  const passed = new Set();
  const relevant = (proof) => levels.indexOf(proof.level) >= levels.indexOf(input.evidenceLevel);
  const key = (proof) => `${proof.level}:${proof.gate}`;
  for (const proof of input.baseline.filter(relevant)) {
    if (proof.state === "passed") passed.add(key(proof));
  }
  let stalledCycles = 0;
  for (const attempt of input.attempts) {
    if (Object.hasOwn(attempt, "reassessment")) {
      // A recorded route reassessment re-arms the bound; it is only valid once the bound has tripped.
      if (stalledCycles < 2) invalid();
      stalledCycles = 0;
      continue;
    }
    let advanced = false;
    for (const proof of attempt.proofs.filter(relevant)) {
      if (proof.state === "passed" && !passed.has(key(proof))) {
        advanced = true;
        passed.add(key(proof));
      }
    }
    stalledCycles = advanced ? 0 : stalledCycles + 1;
  }
  if (stalledCycles >= 2) reasons.push("Two cycles without advancing required proof: reassess the route before another attempt.");

  const approval = ["read", "source-change"].includes(input.action.operation) ? "not-required" :
    input.approvals.some(item => item.state === "current" && isDeepStrictEqual(item.action, input.action)) ? "reuse" : "required";
  const status = reasons.length ? "reassess" : approval === "required" ? "approval-required" : "continue";
  if (approval === "required") reasons.push("Obtain authority for this exact action; changed scope cannot reuse an old approval.");
  return { status, reasons, stalledCycles, approval };
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  try {
    if (process.argv.length !== 2) invalid();
    const chunks = [];
    let bytes = 0;
    for await (const chunk of process.stdin) {
      bytes += chunk.length;
      if (bytes > 65536) invalid();
      chunks.push(chunk);
    }
    const result = assessDelivery(JSON.parse(Buffer.concat(chunks).toString("utf8")));
    console.log(JSON.stringify(result));
    process.exitCode = result.status === "continue" ? 0 : 1;
  } catch {
    console.error("Invalid delivery contract; no action is authorised.");
    process.exitCode = 2;
  }
}
