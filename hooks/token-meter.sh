#!/usr/bin/env bash
# Stop / SubagentStop hook: token-telemetry PRODUCER (#726).
#
# The token pipeline (token-governance schema, Cortex cost-attribution,
# /sge:cost-guard, /sge:roi-report) needs a producer for
# memory/token-usage.jsonl on every install. This hook is that producer.
# Local-only: it reads the session transcript and appends to a local file;
# it makes no network calls.
#
# What it does: reads the Stop/SubagentStop hook payload from stdin (JSON
# with at least `transcript_path` and `session_id`), parses the session
# transcript JSONL, aggregates usage PER assistant message (one
# TokenUsageRecord per assistant turn, including the cache_read/
# cache_creation split from the Anthropic Messages API `usage` block), and
# appends schema-v2-conformant records (platform/packages/token-governance)
# to `memory/token-usage.jsonl`.
#
# specId: `SGE_SPEC_ID` env var if set (sge-implement Phase 1 exports it),
# else the first `SPEC-\d+`, `SGE-\d+`, or legacy `SGD-\d+` match in the
# current branch name, else "unattributed" (schema v2 keeps specId required — see
# platform/packages/token-governance's ROI/attribution code, which already
# treats the literal string "unattributed" as the sentinel bucket for
# ungoverned spend, so a hook-side omission would just have to be
# re-defaulted downstream anyway).
#
# repo: derived from `git remote get-url origin` (org/repo), falling back to
# the repo directory's basename when there is no remote.
#
# cost: intentionally NOT emitted by this producer — schema v2 makes `cost`
# optional and non-authoritative; every consumer recomputes it centrally via
# computeCost() (platform/packages/token-governance/src/model-rates.ts)
# instead of trusting a producer-baked estimate.
#
# Idempotency: Stop can fire more than once for the same growing transcript
# (e.g. a Stop after a SubagentStop, or a resumed session), so this hook must
# never double-count an assistant message it already emitted. A tiny state
# file (a single integer: how many assistant messages have been emitted for
# this transcript so far) is kept per transcript, keyed by a hash of the
# transcript path, under a stable per-machine location OUTSIDE any repo
# working directory — mirroring the #677 fix in
# mcp/sge-cortex/src/db/paths.ts (a worktree's teardown must never destroy
# state that isn't actually tied to that worktree).
#
# Resilience: a hook must never break Stop/SubagentStop. Any failure — no
# jq, no git, an unreadable/missing transcript, malformed JSON — degrades to
# a silent exit 0. Never writes partial/invalid JSON lines.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"

[ -n "$transcript_path" ] || exit 0
[ -f "$transcript_path" ] || exit 0
[ -n "$session_id" ] || session_id="unknown-session"

REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
OUT="${REPO_ROOT}/memory/token-usage.jsonl"

# ── repo identity: org/repo from the origin remote, else dir basename ───────
resolve_repo() {
  local url org_repo
  url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  if [ -n "$url" ]; then
    org_repo="$(printf '%s' "$url" \
      | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^@/]+@##; s#:#/#; s#\.git$##; s#/+$##' \
      | grep -oE '[^/]+/[^/]+$' || true)"
    if [ -n "$org_repo" ]; then
      printf '%s' "$org_repo"
      return 0
    fi
  fi
  basename "$REPO_ROOT"
}
REPO_ID="$(resolve_repo)"
[ -n "$REPO_ID" ] || REPO_ID="unknown-repo"

# ── specId: SGE_SPEC_ID env, else SPEC-\d+/SGE-\d+/SGD-\d+ in the branch name, else unattributed
resolve_spec_id() {
  if [ -n "${SGE_SPEC_ID:-}" ]; then
    printf '%s' "$SGE_SPEC_ID"
    return 0
  fi
  local branch match
  branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  match="$(printf '%s' "$branch" | grep -oE 'SPEC-[0-9]+|SGE-[0-9]+|SGD-[0-9]+' | head -1 || true)"
  if [ -n "$match" ]; then
    printf '%s' "$match"
    return 0
  fi
  printf 'unattributed'
}
SPEC_ID="$(resolve_spec_id)"

AGENT_ID="${SGE_AGENT_ID:-}"
SKILL_NAME="${SGE_ACTIVE_SKILL:-}"

# ── idempotency state: count of assistant messages already emitted ──────────
STATE_DIR="${SGE_TOKEN_METER_STATE_DIR:-$HOME/.claude/sge-token-meter-state}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
hash_input() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    cksum | awk '{print $1}'
  fi
}
state_key="$(printf '%s' "$transcript_path" | hash_input)"
state_file="$STATE_DIR/${state_key:-unknown}.count"
already=0
if [ -f "$state_file" ]; then
  already="$(cat "$state_file" 2>/dev/null || echo 0)"
fi
case "$already" in '' | *[!0-9]*) already=0 ;; esac

# ── parse + filter-already-emitted + format, in a SINGLE streaming jq pass ──
# Previously this was two phases: one jq to extract a compact blob per
# assistant message, then a shell `while read` loop that spawned ~7 more jq
# processes for EVERY new assistant message (a Stop after 10 new turns = 1
# parse + ~70 process spawns — pathological on Windows/MSYS where fork/exec is
# expensive, multiplied across concurrent sessions; see #896).
#
# Now `jq -n` streams the transcript once via `inputs`, uses `foreach` to keep
# a running ordinal of assistant-messages-with-usage, and emits a
# schema-v2-conformant TokenUsageRecord line ONLY for ordinals beyond
# `already`. Exactly one jq invocation per Stop/SubagentStop regardless of
# message count; the per-record shell loop is gone.
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '1970-01-01T00:00:00Z')"

new_records="$(jq -c -n \
  --argjson already "$already" \
  --arg specId "$SPEC_ID" \
  --arg sessionId "$session_id" \
  --arg repo "$REPO_ID" \
  --arg skill "$SKILL_NAME" \
  --arg agent "$AGENT_ID" \
  --arg now "$now_iso" \
  '
  foreach inputs as $rec (0;
    if ($rec.type == "assistant" and $rec.message.usage != null) then . + 1 else . end;
    if ($rec.type == "assistant" and $rec.message.usage != null) and . > $already then
        ($rec.message.usage) as $u
      | ($u.cache_read_input_tokens // 0) as $cread
      | ($u.cache_creation_input_tokens // 0) as $ccreate
      | (if ($rec.timestamp // "") == "" then $now else $rec.timestamp end) as $ts
      | {specId:$specId, sessionId:$sessionId, repo:$repo}
        + (if $skill != "" then {skill:$skill} else {} end)
        + (if $agent != "" then {agent:$agent} else {} end)
        + {model:         ($rec.message.model // "unknown"),
           inputTokens:   ($u.input_tokens // 0),
           outputTokens:  ($u.output_tokens // 0)}
        + (if $cread   > 0 then {cacheReadTokens:$cread}       else {} end)
        + (if $ccreate > 0 then {cacheCreationTokens:$ccreate} else {} end)
        + {timestamp:$ts}
    else empty end)
  ' "$transcript_path" 2>/dev/null || true)"

# Nothing new (empty transcript, no assistant usage, or all already emitted).
[ -n "$new_records" ] || exit 0

# Symlink refusal (sge#2780): `memory/` lives inside a repo working tree, so
# a repo-controlled symlink there (or at memory/token-usage.jsonl) could
# redirect this append to any file the user can write. Refuse to append when
# either is a link, or when memory/ resolves outside the project dir. Exit
# before the idempotency counter advances, so a refused run never consumes
# records. (The per-session state file under $HOME is out of scope here.)
MEM_DIR="$(dirname "$OUT")"
[ -L "$MEM_DIR" ] && exit 0
mkdir -p "$MEM_DIR" 2>/dev/null || exit 0
[ -L "$MEM_DIR" ] && exit 0
[ -L "$OUT" ] && exit 0
root_phys="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)" || exit 0
mem_phys="$(cd "$MEM_DIR" 2>/dev/null && pwd -P)" || exit 0
[ -n "$root_phys" ] && [ "$mem_phys" = "$root_phys/memory" ] || exit 0
printf '%s\n' "$new_records" >> "$OUT" 2>/dev/null || exit 0

# Advance the idempotency counter by the number of records just emitted.
# already + new == the full count of assistant-usage records in the
# transcript, matching the previous full-recount semantics without a second
# parse (and never regressing the counter if the transcript ever shrank).
new_count="$(printf '%s\n' "$new_records" | grep -c . || true)"
case "$new_count" in '' | *[!0-9]*) new_count=0 ;; esac
printf '%s' "$((already + new_count))" > "$state_file" 2>/dev/null || true
exit 0
