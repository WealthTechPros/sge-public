#!/usr/bin/env bash
# check-cortex-recall.sh — /sge:sge-align C43: Cortex installed but no recall hook
# (SPEC-108 §2.4b, issue #3110, parent #3101).
# ---------------------------------------------------------------------------------------
# Advisory, read-only, offline. Emits one JSON block on stdout. Exit 0 always
# (the verdict is in `status`: pass | warn | na); exit 2 = harness error only.
#
# "Cortex installed" = ANY of, read from this repo's own files only:
#   - .mcp.json declares the `sge-memory` MCP server
#   - .claude/settings.json | settings.local.json sets a CORTEX_* env var
#   - those settings enable the sge plugin (`"sge@<marketplace>": true`), which
#     ships the sge-memory MCP
# "Recall hook configured" = the plugin's SessionStart hook cortex-recall.sh is in
# the effective hooks AND is not switched off:
#   - sge plugin enabled in those settings, OR a repo hook file
#     (.claude/settings*.json, .claude/hooks.json) has a "command" running cortex-recall.sh
#     (hooks/hooks.json is the plugin manifest: it counts only via the enabled plugin)
#   - AND no `"SGE_CORTEX_RECALL": "off"` in those settings' env.
# User-level (~/.claude) settings and shell environment are deliberately NOT read.
#
# Usage: check-cortex-recall.sh [repo-root]   (default: enclosing git toplevel or .)
set -uo pipefail

if [ -n "${1:-}" ]; then
  [ -d "$1" ] || { echo "check-cortex-recall.sh: repo root not found: $1" >&2; exit 2; }
  ROOT="$(cd "$1" && pwd)"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
fi
SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

SETTINGS=""
for f in "$ROOT/.claude/settings.json" "$ROOT/.claude/settings.local.json"; do
  [ -f "$f" ] && SETTINGS="$SETTINGS $f"
done
# shellcheck disable=SC2086
grepq() { # pattern files... (tolerates an empty file list)
  local p="$1"; shift
  [ "$#" -gt 0 ] || return 1
  grep -Eqs -- "$p" "$@"
}

PLUGIN_RE='"sge@[^"]*"[[:space:]]*:[[:space:]]*true'
installed=0; evidence=""
if grepq '"sge-memory"' "$ROOT/.mcp.json"; then installed=1; evidence="${evidence}.mcp.json declares sge-memory; "; fi
# shellcheck disable=SC2086
if grepq '"CORTEX_[A-Z_]+"' $SETTINGS; then installed=1; evidence="${evidence}CORTEX_* env in settings; "; fi
# shellcheck disable=SC2086
plugin=0; grepq "$PLUGIN_RE" $SETTINGS && { plugin=1; installed=1; evidence="${evidence}sge plugin enabled; "; }

hook=0
[ "$plugin" = 1 ] && hook=1
# A repo hook file counts only when a "command" value runs cortex-recall.sh (a bare
# filename mention does not). hooks/hooks.json is the plugin manifest: it takes effect
# only through the enabled plugin above, so it is deliberately not read here.
# shellcheck disable=SC2086
grepq '"command"[[:space:]]*:[[:space:]]*"[^,]*cortex-recall\.sh' "$ROOT/.claude/hooks.json" $SETTINGS && hook=1
off=0
# shellcheck disable=SC2086
grepq '"SGE_CORTEX_RECALL"[[:space:]]*:[[:space:]]*"off"' $SETTINGS && off=1

MSG='Cortex is installed but session recall is not configured: the sge cortex-recall SessionStart hook is not active, so agents will not recall stored facts before asking.'
FIX='Fix: enable the sge plugin (/plugin install sge) so hooks/cortex-recall.sh runs at SessionStart, and remove SGE_CORTEX_RECALL=off from .claude/settings*.json env. See docs/sge-memory.md "Facts vs governance" and SPEC-108 section 2.4b.'

json_esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
status=pass; findings="[]"; detail="$(json_esc "${evidence%; }")"
if [ "$installed" = 0 ]; then
  status=na; detail="no Cortex signal in repo files (not scored)"
elif [ "$hook" = 0 ] || [ "$off" = 1 ]; then
  status=warn
  reason="recall hook absent"; [ "$off" = 1 ] && reason="recall switched off (SGE_CORTEX_RECALL=off)"
  findings="[{\"artefact\":\".claude/settings.json\",\"severity\":\"low\",\"check\":\"C43\",\"reason\":\"$(json_esc "$reason")\",\"finding\":\"$(json_esc "$MSG")\",\"fix\":\"$(json_esc "$FIX")\"}]"
fi

printf '%s\n' "{
  \"check\": \"C43\",
  \"name\": \"Cortex recall hook\",
  \"layer\": \"cortex\",
  \"sha\": \"${SHA}\",
  \"status\": \"${status}\",
  \"advisory\": true,
  \"evidence\": \"${detail}\",
  \"findings\": ${findings}
}"
exit 0
