#!/usr/bin/env bash
# review-tier.sh -- risk-tiered review DEPTH for /sge:pr-review (sge#2776),
# chosen mechanically from the diff (a script, never the LLM).
#
#   light     every changed path is light-eligible: an allowlisted regular-file
#             doc, or a version-only `.claude-plugin/*.json`/`marketplace.json` edit
#             -> single pass, no subagents, on sonnet. The PR's author never
#             matters (a dependency bot's manifest bump is standard).
#   standard  the default (ordinary code, tests, skills, config, unknown paths)
#             -> today's review, @security-auditor only on security triggers.
#   full      any full-list path (workflows, hooks, infra/IaC, Docker,
#             migrations, auth/secrets/credentials/crypto, gate config) or an
#             unreadable input -> today's full review.
#
# Escalates, never de-escalates, on uncertainty. Renames count both paths;
# deletions count their path (deleting a gate is a gate change). Repos extend
# the lists in `.sge/review-tier.yml` (constrained YAML subset, same as
# .sge/test-map.yml: list keys full_paths / standard_paths / light_paths, one
# `  - 'glob'` per line; precedence full > standard > light). `pr` mode reads it
# from the DEFAULT branch (not the PR's base), so a PR can't widen its light list.
#
# The Python twin (services/review-daemon-poc/review_tier.py) implements the
# same `classify`; skills/tests/review-tier.test.sh runs both over the shared
# fixture table skills/pr-review/review-tier.fixtures.tsv so they cannot drift.
#
# Usage:
#   review-tier.sh classify [--config FILE | --config-text TEXT] < files.json
#       files.json = GitHub pulls/files-shaped JSON array (null = unreadable)
#   review-tier.sh pr <pr> [--floor light|standard|full] [--risk <DIFF_RISK>]
#       tiers the WHOLE PR by path (delta tiering was dropped, sge#2776);
#       --floor never lowers it; --risk high floors it at standard
#   review-tier.sh max <tier> <tier>
# Every mode prints `<tier>\t<one-line reason>`, except `max` (the tier only).
# END_USAGE
#
# Requires jq. Everything read from GitHub is UNTRUSTED DATA: parsed with jq,
# never eval'd; the reason is whitespace-flattened to one line.

RT_FULL_GLOBS=(
  '.github/**' '.githooks/**' 'hooks/**' '.sge/**'
  '**/.gitattributes' '**/CODEOWNERS'
  '**/infra/**' '**/iac/**' '**/*.tf' '**/*.tfvars' '**/*.bicep'
  '**/Pulumi*.yaml' '**/Pulumi*.yml'
  '**/Dockerfile*' '**/*.Dockerfile' '**/docker-compose*'
  '**/migrations/**' '**/middleware/**'
  '**/*auth*' '**/*security*' '**/*secret*' '**/*credential*'
  '**/*crypto*' '**/*password*'
  '**/*auth*/**' '**/*security*/**' '**/*secret*/**' '**/*credential*/**'
  '**/*crypto*/**' '**/*password*/**'
  '**/*.pem' '**/*.key' '**/*.p12' '**/*.pfx' '**/.env' '**/.env.*'
)
RT_STANDARD_GLOBS=(
  '**/skills/**' '**/prompts/**' '**/.cursor/**'
  '**/agents/**' '**/commands/**' '**/.claude/**'
  '**/CLAUDE*.md' '**/AGENTS*.md' 'docs/specs/**' 'docs/decisions/**'
  # Other agents' instruction files (review of sge#2781, minor 10).
  '**/GEMINI*.md' '**/AGENT.md' '**/.clinerules'
  '**/.agents/**' '**/.windsurf/**' '**/.clinerules/**' '**/.kiro/**'
  '**/CONVENTIONS.md' '**/WARP.md' '**/.roo/**' '**/.junie/**'
  '**/.openhands/**' '**/.amazonq/**' '**/.continue/**'
  '**/copilot-instructions.md' '**/SKILL.md'
  # Agent context loaded into every session, and the verdict grammar (sge#2792).
  'docs/sge-digest*.md' 'docs/sge/**' 'docs/schemas/**'
)
# The light ALLOWLIST (round 4): a docs extension at the top level or under
# docs/, or a README.md anywhere; any other path is at least standard. No .mdx:
# MDX runs JSX/import/export at build time, so it is not inert docs.
RT_DOCS_GLOBS=(
  '*.md' '*.markdown' '*.rst' '*.adoc'
  'docs/**/*.md' 'docs/**/*.markdown' 'docs/**/*.rst' 'docs/**/*.adoc'
  '**/README.md'
)
RT_VERSION_GLOBS=('**/.claude-plugin/*.json' '**/marketplace.json')

# rt_glob_re <glob> -- the same translation as model_routing._glob_to_regex:
# `**/` = zero or more leading dirs, `**` = anything, `*` = no `/`, `?` = one.
rt_glob_re() {
  local g="$1" out="" i=0 c
  while [ "$i" -lt "${#g}" ]; do
    if [ "${g:i:3}" = "**/" ]; then out+='(?:.*/)?'; i=$((i+3)); continue; fi
    if [ "${g:i:2}" = "**" ]; then out+='.*'; i=$((i+2)); continue; fi
    c="${g:i:1}"
    case "$c" in
      '*') out+='[^/]*' ;;
      '?') out+='[^/]' ;;
      '.'|'['|']'|'('|')'|'+'|'{'|'}'|'|'|'^'|'$'|'\') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
    i=$((i+1))
  done
  printf '%s' "$out"
}

# rt_globs_re <glob>... -- one anchored alternation ("" for an empty list).
rt_globs_re() {
  local g out=""
  for g in "$@"; do out+="${out:+|}$(rt_glob_re "$g")"; done
  [ -n "$out" ] && printf '^(?:%s)$' "$out"
}

# rt_config_list <key> < config-text -- the `.sge/*.yml` list loader (same awk
# as require-regulated-signoff.yml's map_list), reading the config on stdin.
rt_config_list() {
  # CR stripped FIRST, so a CRLF file's quotes are still at the line end (minor 3).
  tr -d '\r' | awk -v key="$1" '
    $0 ~ "^"key":" { infield=1; next }
    infield && /^[A-Za-z_]+:/ { infield=0 }
    infield && /^[[:space:]]*-/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      # Whitespace BEFORE quotes (round 4, minor 4), then one matched pair --
      # the same order as the Python twin.
      gsub(/[[:space:]]+$/, "", line)
      f=substr(line, 1, 1)
      if (length(line) >= 2 && f == substr(line, length(line), 1) && (f == "\"" || f == "'"'"'"))
        line=substr(line, 2, length(line) - 2)
      if (line != "") print line
    }
  ' 2>/dev/null
}

# rt_config_malformed < config-text -- exit 0 when the lists cannot be read as
# the constrained subset: a near-miss list key (any non-item, non-comment line
# naming a list key, in any case and with `-` or `_`, that is not exactly
# `key:` at column 0 -- indented, quoted, `full_paths :`, `FULL_PATHS:`,
# `full-paths:`), an inline value on a list key (`full_paths: [...]`), a bare
# `-` or empty quoted (`- ''`) item or an unbalanced item quote
# (control/non-ASCII bytes, a BOM included, are caught by the caller -- sge#2791, sge#2792). Then the
# classifier escalates to full instead of silently dropping full_paths (rounds
# 3-4; the Python twin's parse_config "malformed").
rt_config_malformed() {
  tr -d '\r' | awk '
    !/^[[:space:]]*-/ && !/^[[:space:]]*#/ && tolower($0) ~ /(full|standard|light)[-_]paths/ \
      && !/^(full_paths|standard_paths|light_paths):/ { bad=1 }
    /^[A-Za-z_]+:/ {
      infield = ($0 ~ /^(full_paths|standard_paths|light_paths):/)
      if (infield) {
        rest=$0; sub(/^[A-Za-z_]+:/, "", rest); sub(/(^|[[:space:]])#.*$/, "", rest)
        gsub(/[[:space:]]/, "", rest); if (rest != "") bad=1
      }
      next
    }
    infield && /^[[:space:]]*-/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "") { bad=1; next }
      f=substr(line, 1, 1); l=substr(line, length(line), 1)
      # An empty quoted item (`- ''`) is no glob either, as a bare `-` is.
      if (length(line) >= 2 && f == l && (f == "\"" || f == "'"'"'")) { if (length(line) == 2) bad=1; next }
      if (f == "\"" || f == "'"'"'" || l == "\"" || l == "'"'"'") bad=1
    }
    END { exit(bad ? 0 : 1) }'
}

rt_max() {
  local a b
  case "$1" in light) a=0 ;; standard) a=1 ;; *) a=2 ;; esac
  case "$2" in light) b=0 ;; standard) b=1 ;; *) b=2 ;; esac
  [ "$b" -gt "$a" ] && a=$b
  case "$a" in 0) echo light ;; 1) echo standard ;; *) echo full ;; esac
}

# rt_classify [--config FILE | --config-text TEXT] < files.json -- paths only:
# who authored the change never lowers the tier.
rt_classify() {
  local config="" input out
  while [ $# -gt 0 ]; do
    case "$1" in
      # NUL -> \x01: a shell string cannot hold NUL, and it must still fail closed.
      --config) config=$(tr '\000' '\001' 2>/dev/null < "${2:-}"); shift 2 ;;
      --config-text) config="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  local -a cfull=() cstd=() clight=()
  local l
  if [ -n "$config" ]; then
    # Lines split on \n only (a CR only as part of CRLF or at the very end): any
    # other control byte, or any non-ASCII byte (a BOM too), is malformed, since
    # awk and Python split and trim lines on different bytes (sge#2792).
    l=${config//$'\r\n'/$'\n'}; l=${l%$'\r'}
    if printf '%s' "$l" | LC_ALL=C grep -q '[^[:print:][:blank:]]' || rt_config_malformed <<<"$config"; then
      cat >/dev/null
      printf 'full\trepo .sge/review-tier.yml malformed -- fail closed to full\n'
      return 0
    fi
    while IFS= read -r l; do cfull+=("$l"); done < <(rt_config_list full_paths <<<"$config")
    while IFS= read -r l; do cstd+=("$l"); done < <(rt_config_list standard_paths <<<"$config")
    while IFS= read -r l; do clight+=("$l"); done < <(rt_config_list light_paths <<<"$config")
  fi
  input=$(cat)
  out=$(printf '%s' "$input" | jq -r \
    --arg full "$(rt_globs_re "${RT_FULL_GLOBS[@]}")"     --arg cfull "$(rt_globs_re ${cfull[@]+"${cfull[@]}"})" \
    --arg std "$(rt_globs_re "${RT_STANDARD_GLOBS[@]}" ${cstd[@]+"${cstd[@]}"})" \
    --arg light "$(rt_globs_re "${RT_DOCS_GLOBS[@]}" ${clight[@]+"${clight[@]}"})" \
    --arg ver "$(rt_globs_re "${RT_VERSION_GLOBS[@]}")" '
    def m($re): ($re != "") and test($re; "i");
    def shown: (.[0:3] | join(", ")) + (if length > 3 then " (+\(length - 3) more)" else "" end);
    # Version-only (review of sge#2781, minor 12): each run of consecutive
    # changed lines is k removed then k added lines, identical pair for pair
    # with version values masked (keys sharing the line, as in sge'"'"'s
    # manifests, must not change; a swapped or MOVED version line is a change),
    # and every changed line starts with exactly one "version" key at the
    # manifest'"'"'s own level: indent <= 2 in plugin.json, <= 6 in
    # marketplace.json (top level, metadata, a plugins[] entry).
    def vmask: gsub("\"version\"\\s*:\\s*\"[^\"]*\""; "\"version\":\"_\"");
    def version_only($p):
      (if ($p | split("/") | last | ascii_downcase) == "marketplace.json" then 6 else 2 end) as $d
      | ([(.patch // "") | split("\n")[] | select(.[0:1] != "\\")]
         | reduce .[] as $x ([[]];
             if ($x[0:1] == "+" or $x[0:1] == "-") then .[length - 1] += [$x]
             elif (.[length - 1] | length) > 0 then . + [[]] else . end)
         | map(select(length > 0))) as $runs
      | (.status == "modified") and ($runs | length) > 0
        and all($runs[];
          [.[] | select(.[0:1] == "-") | .[1:]] as $r | [.[] | select(.[0:1] == "+") | .[1:]] as $a
          | ($r | length) == ($a | length)
            and all(.[0:($r | length)][]; .[0:1] == "-")
            and all(($r + $a)[]; test("^ {0,\($d)}\"version\"\\s*:\\s*\"[^\"]*\"") and ([scan("\"version\"\\s*:")] | length) == 1)
            and ($r | map(vmask)) == ($a | map(vmask)));
    def names: [.previous_filename, .filename][] | select(type == "string" and . != "");
    # A non-object record is unreadable input (round 3, minor 5).
    if type != "array" or any(.[]; type != "object") then
      ["full", "changed-file list unavailable or malformed -- fail closed to full"]
    else
      . as $files
      | (reduce ($files[] | names) as $p ([]; if any(.[]; . == $p) then . else . + [$p] end)) as $paths
      # "author"/"authors"/"authored"/"authoring"/"authorship" are not auth:
      # masked (whole word only) before the built-in `*auth*` globs;
      # "authority"/"authorization"/"authorise" stay auth (minor 11).
      | [$paths[] | select((gsub("author(?:s|ed|ing|ship)?(?![a-z])"; "a_uthor"; "i") | m($full)) or m($cfull))] as $hot
      # A control character (newline, NUL, DEL...) in a path is full before any
      # glob: `**` does not cross a newline, so it would dodge every full glob.
      | if any($paths[]; explode | any(.[]; . < 32 or . == 127)) then
          ["full", "control character in a changed path -- fail closed to full"]
        # Non-ASCII too: jq and Python fold Unicode case differently (İ, ß).
        elif any($paths[]; explode | any(.[]; . > 127)) then
          ["full", "non-ASCII changed path -- fail closed to full"]
        elif ($hot | length) > 0 then ["full", "full-tier path(s): \($hot | shown)"]
        elif ($paths | length) == 0 then ["standard", "no changed files"]
        else
          (reduce $files[] as $f ([];
             reduce ($f | names) as $p (.;
               # A regular file only: a symlink (120000) or "unknown" head-tree
               # mode is never light; no `mode` = a caller that read no tree.
               if ((($p | m($std)) | not) and ((if $f.mode == null then "100644" else $f.mode end) as $md | $md == "100644" or $md == "100755")
                   and (($p | m($light)) or (($p | m($ver)) and ($f | version_only($p)))))
                  or any(.[]; . == $p) then . else . + [$p] end)) ) as $nl
          | if ($nl | length) > 0 then ["standard", "not light-eligible: \($nl | shown)"]
            else ["light", "docs/version-only change (\($paths | length) file(s))"] end
        end
    end
    | "\(.[0])\t\(.[1] | gsub("\\s+"; " "))"' 2>/dev/null | tr -d '\r')
  case "${out%%$'\t'*}" in
    light|standard|full) printf '%s\n' "$out" ;;
    *) printf 'full\tclassifier input unreadable -- fail closed to full\n' ;;
  esac
}

# rt_pr <pr> [--floor <tier>] [--risk <DIFF_RISK>] -- the whole PR's tier.
#   --risk high floors the tier at standard (rl_diff_risk's safety net).
rt_pr() {
  local pr="${1:?rt_pr: pr required}"; shift
  local floor="light" risk="" repo meta head files cfg="" tree
  while [ $# -gt 0 ]; do
    case "$1" in
      --floor) floor="${2:-full}"; shift 2 ;;
      --risk) risk="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ "$risk" = "high" ] && floor=$(rt_max "$floor" standard)
  repo="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)}"
  rt__out() {  # <tier> <reason>
    local t
    t=$(rt_max "$1" "$floor")
    if [ "$t" = "$1" ]; then printf '%s\t%s\n' "$t" "$2"
    else printf '%s\tfloor %s over %s: %s\n' "$t" "$floor" "$1" "$2"; fi
  }
  meta=$(gh pr view "$pr" --repo "$repo" --json author,headRefOid 2>/dev/null) \
    || { rt__out full "PR metadata unreadable -- fail closed to full"; return 0; }
  head=$(printf '%s' "$meta" | jq -r '.headRefOid // ""' | tr -d '\r')
  if files=$(gh api --paginate "repos/$repo/pulls/$pr/files?per_page=100" 2>/dev/null); then
    files=$(printf '%s' "$files" | jq -cs 'add // []' 2>/dev/null) || files="null"
  else
    files="null"
  fi
  [ -n "$files" ] || files="null"
  # GitHub's pulls/files stops at 3000 files: at the cap the list may hide a
  # later-sorting sensitive file, so it is truncated -> full (as the Python
  # adapter's 30-page ceiling; review of sge#2781, B2).
  if [ "$files" != "null" ] && [ "$(printf '%s' "$files" | jq 'length' 2>/dev/null | tr -d '\r')" -ge 3000 ] 2>/dev/null; then
    rt__out full "file list truncated (GitHub's 3000-file cap) -- fail closed to full"
    return 0
  fi
  # Head-tree modes (round 4): every non-removed record gets its git mode, so a
  # symlinked doc (120000) is never light; an unreadable or truncated tree
  # makes every mode "unknown" (never light). Same as the daemon.
  if [ "$files" != "null" ]; then
    tree=$(gh api "repos/$repo/git/trees/$head?recursive=1" 2>/dev/null \
      | jq -c 'if type == "object" and .truncated == false and (.tree | type) == "array"
               then [.tree[] | select(.type == "blob") | {(.path): .mode}] | add // {} else null end' 2>/dev/null)
    # Both documents on stdin (as an argument a large tree overflows the command line).
    files=$(printf '%s\n%s\n' "${tree:-null}" "$files" | jq -cs '.[0] as $t | .[1]
      | [.[] | if type == "object" and .status != "removed"
               then . + {mode: (if ($t | type) != "object" then "unknown" else ($t[.filename] // "unknown") end)}
               else . end]' 2>/dev/null) || files="null"
    [ -n "$files" ] || files="null"
    # The file list came from the LIVE head; if a push landed before the tree
    # read, the modes may not describe those files -> unknown (round 5).
    local after
    after=$(gh pr view "$pr" --repo "$repo" --json headRefOid 2>/dev/null | jq -r '.headRefOid // ""' 2>/dev/null | tr -d '\r')
    if [ "${after,,}" != "${head,,}" ] && [ "$files" != "null" ]; then
      files=$(printf '%s' "$files" | jq -c '[.[] | if type == "object" and .status != "removed" then . + {mode: "unknown"} else . end]' 2>/dev/null) \
        || files="null"
    fi
  fi

  # Repo config from the DEFAULT branch (no ?ref=, review of sge#2781, M5): the
  # PR author picks the base ref, so a base they pushed could widen light_paths.
  # One call: an HTTP 404 is "no config" (the same token just read this PR's
  # files, so it is not a scope failure); any other failure escalates -- even
  # one whose text merely contains "404". The 256 KiB cap (the daemon's
  # REVIEW_TIER_CONFIG_MAX_BYTES) counts the raw bytes, as the daemon does;
  # $(...) alone would strip trailing newlines first. Over the cap the
  # file was not read in full, so it is unreadable, never a truncated list.
  # A sentinel byte after the output keeps $(...) from stripping trailing
  # newlines, so the length below is the raw byte count. NUL -> \x01 (byte for
  # byte), so a NUL still fails closed as a control byte (sge#2792).
  local raw
  if ! raw=$(gh api -H "Accept: application/vnd.github.raw" "repos/$repo/contents/.sge/review-tier.yml" 2>&1 \
               | tr '\000' '\001'
             rc=${PIPESTATUS[0]}; printf x; exit "$rc"); then
    case "$raw" in
      *"(HTTP 404)"*) raw=x ;;
      *) rt__out full "repo .sge/review-tier.yml unreadable -- fail closed to full"; return 0 ;;
    esac
  fi
  cfg="${raw%x}"
  if [ "$(printf '%s' "$cfg" | wc -c | tr -d ' \r')" -gt 262144 ]; then
    rt__out full "repo .sge/review-tier.yml over the 256 KiB read cap -- unreadable, fail closed to full"; return 0
  fi

  result=$(printf '%s' "$files" | rt_classify --config-text "$cfg")
  rt__out "${result%%$'\t'*}" "${result#*$'\t'}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    classify) rt_classify "$@" ;;
    pr) rt_pr "$@" ;;
    max) rt_max "${1:-}" "${2:-}" ;;
    *) sed -n '/^# Usage:/,/^# END_USAGE/p' "$0" >&2; exit 2 ;;
  esac
fi
