# sgd-implement — SkillRunRecord emission (reference)

The exact jq command for the mandatory `SkillRunRecord` emitted on every exit
path (schema in `platform/packages/token-governance`, #727). Field contract and
the "when" stay in `SKILL.md` (Phase 8.3 success exit; Phase 0.5 headless
governance-pause exit); this file carries the command template.

Sink: `memory/skill-runs.jsonl` (a sibling sidecar to `memory/token-usage.jsonl`).
`sessionId` is the join key back to this session's `TokenUsageRecord` rows — use
`SGD_SESSION_ID` if the environment exports it (same convention `/sgd:cost-guard`
reads), else the run is still recorded but not joinable to spend.

## Success-lane exit (Phase 8.3 — `verdict "merged"`, `phaseReached "Phase 8"`)

```bash
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
JSONL="$(git rev-parse --show-toplevel)/memory/skill-runs.jsonl"
mkdir -p "$(dirname "$JSONL")"
jq -nc \
  --arg skill "sgd-implement" \
  --arg repo "$REPO" \
  --argjson issue <issue-number> \
  --argjson pr <PR_NUMBER> \
  --arg verdict "merged" \
  --arg phaseReached "Phase 8" \
  --arg sessionId "${SGD_SESSION_ID:-unknown-session}" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{skill:$skill, repo:$repo, issue:$issue, pr:$pr, verdict:$verdict, phaseReached:$phaseReached, sessionId:$sessionId, timestamp:$timestamp}' \
  >> "$JSONL"
```

## Governance-pause exit (Phase 0.5 — `verdict "blocked"`, `phaseReached "Phase 0.5"`)

Same sink and shape, omitting `pr` (no PR was opened):

```bash
jq -nc \
  --arg skill "sgd-implement" \
  --arg repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)" \
  --argjson issue <issue-number> \
  --arg verdict "blocked" \
  --arg phaseReached "Phase 0.5" \
  --arg sessionId "${SGD_SESSION_ID:-unknown-session}" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{skill:$skill, repo:$repo, issue:$issue, verdict:$verdict, phaseReached:$phaseReached, sessionId:$sessionId, timestamp:$timestamp}' \
  >> "$(git rev-parse --show-toplevel)/memory/skill-runs.jsonl"
```

Do not double-emit for the same run — a merged run emits only the success record;
a governance-paused run emits only the blocked record.
