#!/usr/bin/env bash
# Offline, credential-aware staged scan. Follow-up sge#3219.
# Exit 0 = clean, 1 = findings, 2 = unavailable/failed scan. No skip switch.
set -uo pipefail
[ "$#" -eq 0 ] || { echo "SECRET-SCAN error: takes no arguments" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
error() { echo "SECRET-SCAN error: $*; do not commit until the scan succeeds." >&2; exit 2; }
command -v node >/dev/null 2>&1 || error "Node.js is required"
version="$(cat "$HERE/gitleaks.version")" || error "scanner version is missing"
scanner="${HOME:?}/.cache/sge/gitleaks/$version/gitleaks"
[ -x "$scanner" ] || scanner="$scanner.exe"
[ -x "$scanner" ] || scanner="$(command -v gitleaks 2>/dev/null || true)"
[ -x "$scanner" ] || error "Gitleaks is missing; run bash \"$HERE/install-scanner.sh\""
actual="$("$scanner" version 2>/dev/null)" || error "Gitleaks could not start"
[ "$actual" = "$version" ] || error "Gitleaks $version is required; run bash \"$HERE/install-scanner.sh\""
root="$(git rev-parse --show-toplevel 2>/dev/null)" || error "not a Git repository"
git diff --cached --no-ext-diff --numstat >/dev/null 2>&1 || error "cannot read the Git index"
work="$(mktemp -d)" || error "cannot create a restricted temporary directory"
trap 'rm -rf "$work"' EXIT

# Explicit policy/ignore inputs prevent repository config and inline comments
# from silently disabling the commit gate. The engine never validates tokens online.
"$scanner" git --pre-commit --staged --config "$HERE/gitleaks.toml" \
  --redact=100 --no-banner --no-color --ignore-gitleaks-allow \
  --gitleaks-ignore-path "$work" --report-format json --report-path "$work/report.json" \
  --exit-code 23 --log-level error --timeout 120 "$root" >"$work/engine.log" 2>&1
rc=$?
case "$rc" in 0|23) ;; *) error "Gitleaks failed (exit $rc); check Git, installation and the plugin policy" ;; esac

node - "$work/report.json" "$rc" <<'NODE'
const fs = require("node:fs");
try {
  const findings = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const detected = process.argv[3] === "23";
  if (!Array.isArray(findings) || detected !== (findings.length > 0)) throw new Error();
  for (const finding of findings) {
    if (typeof finding.File !== "string" || !finding.File || !Number.isInteger(finding.StartLine)
      || finding.StartLine < 1 || typeof finding.RuleID !== "string"
      || !/^[a-z0-9_.-]+$/i.test(finding.RuleID)) throw new Error();
  }
  for (const finding of findings) {
    console.error(`SECRET-SCAN ${JSON.stringify(finding.File)}:${finding.StartLine} rule=${finding.RuleID}`);
  }
  if (detected) {
    console.error("SECRET-SCAN blocked: remove the staged credential and use an injected secret/reference. Rotate it if already exposed. No secret values are printed.");
  }
  process.exitCode = detected ? 1 : 0;
} catch {
  console.error("SECRET-SCAN error: invalid or inconsistent scanner report; do not commit.");
  process.exitCode = 2;
}
NODE
