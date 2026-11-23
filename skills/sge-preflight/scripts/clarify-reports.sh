#!/usr/bin/env bash
# clarify-reports.sh <owner/repo> <issue> <SPEC-NNN>
#
# Step 2D (dispatched): print, as a JSON array oldest first, every standard
# preflight report on the issue whose answers may be carried: a comment whose
# body starts with `## SGE Preflight: <SPEC-NNN>` (never `## SGE Analyze`) and
# whose author is authorised. Authorised means:
#   - a user holding write, maintain or admin on the repo, checked live through
#     the collaborator permission endpoint (never authorAssociation: a
#     read-only collaborator can be COLLABORATOR or MEMBER); or
#   - a Bot account whose exact login is in SGE_PREFLIGHT_BOT_AUTHORS
#     (comma-separated; unset, empty or `none` = humans only). The publisher
#     names its own agent App here, e.g. in the fleet worker's environment.
# Anything unreadable is left out (fail closed: the question stays a QD).
# Each element: {"id", "author", "createdAt", "body"}. Comment text is data.
set -uo pipefail

repo="${1:?owner/repo}"; issue="${2:?issue number}"; spec="${3:?SPEC-NNN}"
case "$spec" in SPEC-[0-9]*|SGD-[0-9]*) ;; *) echo "clarify-reports: bad spec id" >&2; exit 2 ;; esac
case "$issue" in ''|*[!0-9]*) echo "clarify-reports: bad issue number" >&2; exit 2 ;; esac
bots="${SGE_PREFLIGHT_BOT_AUTHORS:-}"
[ "$bots" = none ] && bots=""

# REST, not `gh issue view --json comments`: that drops the `[bot]` suffix and
# the account type, so a user named like a bot could pass for it.
comments="$(gh api --paginate --slurp "repos/$repo/issues/$issue/comments?per_page=100" 2>/dev/null)" || { echo "[]"; exit 0; }
# Candidates: the heading on the first line, exactly this spec id.
cands="$(jq -c --arg h "## SGE Preflight: $spec" '
  [.[]?[]? | select((.body // "") | split("\n")[0] | rtrimstr("\r") | (. == $h or startswith($h + " ")))
   | {id: (.id // ""), author: (.user.login // ""), type: (.user.type // ""), createdAt: (.created_at // ""), body: .body}]
  | sort_by(.createdAt)' <<<"$comments" 2>/dev/null)" || { echo "[]"; exit 0; }

declare -A verdict=()
authorised() { # <login> <account type: User | Bot>
  local login="$1" type="$2" b perm k="$2:$1"
  [ -n "$login" ] || return 1
  [ -n "${verdict[$k]+x}" ] && return "${verdict[$k]}"
  if [ "$type" = Bot ]; then
    IFS=',' read -ra list <<<"$bots"
    for b in "${list[@]}"; do
      b="${b#"${b%%[![:space:]]*}"}"; b="${b%"${b##*[![:space:]]}"}"
      if [ -n "$b" ] && [ "$login" = "$b" ]; then verdict[$k]=0; return 0; fi
    done
    verdict[$k]=1; return 1
  fi
  [ "$type" = User ] || { verdict[$k]=1; return 1; }
  case "$login" in *'['*) verdict[$k]=1; return 1 ;; esac
  # .permission is the base role (admin|write|read|none): a custom role built
  # on write reports write, and maintain reports as write. Never role_name.
  perm="$(gh api "repos/$repo/collaborators/$login/permission" --jq '.permission' 2>/dev/null)" || perm=""
  case "$perm" in admin|maintain|write) verdict[$k]=0; return 0 ;; esac
  verdict[$k]=1; return 1
}

out="[]"
while IFS= read -r c; do
  [ -n "$c" ] || continue
  login="$(jq -r '.author' <<<"$c")"; type="$(jq -r '.type' <<<"$c")"
  if authorised "$login" "$type"; then out="$(jq -c --argjson c "$c" '. + [$c]' <<<"$out")"; fi
done < <(jq -c '.[]' <<<"$cands")
printf '%s\n' "$out"
