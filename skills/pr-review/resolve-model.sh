#!/usr/bin/env bash
# resolve-model.sh -- provider-neutral reviewer-model resolution (issue #3035).
#
# Maps a reviewer ROLE (+ risk signal) to a CONCRETE model id that the active
# harness actually offers, so Agent(model: <id>) never receives a bare
# `sonnet`/`opus` alias a non-Anthropic-aliasing harness (Copilot CLI) rejects.
# Data lives in model-roles.json (ids in ONE place); see
# references/model-roles.md.
#
# Usage:
#   resolve-model.sh --role <code-reviewer|design-reviewer|security-auditor|...>
#                    [--security] [--class light|standard|deep] [--override <id>]
#
# Inputs:
#   catalog   SGE_MODEL_CATALOG_JSON (inline) or SGE_MODEL_CATALOG_FILE (path):
#             a JSON array of model ids, or of objects with an `id` field. A
#             catalog that is supplied but unreadable/unparseable/empty is exit 3.
#             Under Claude Code (CLAUDECODE=1) with none supplied, the table's
#             `claude-*` ids are the catalog (assumed accepted by Agent(model:)).
#   overrides --override flag, else the `overrides.<role>` key of
#             SGE_MODEL_OVERRIDES_JSON / SGE_MODEL_OVERRIDES_FILE /
#             ./.sge/model-roles.json (first present). The working-tree file is
#             the tree UNDER REVIEW, so it is never read for a `deep` lane (a PR
#             must not steer its own security floor); use the env vars/flag.
#             An override must be ONE id ([A-Za-z0-9._:/-]+), else exit 4.
#   table     SGE_MODEL_ROLES_TABLE (test seam) else model-roles.json beside this file.
#
# Output: the model id on stdout (exit 0), or the literal `default` for a
# `standard` lane when NO catalog is available (caller omits `model:`; never
# for `deep`). Every failure is non-zero with a one-line reason on stderr and
# NOTHING on stdout -- the caller must treat it as lane not-run/incomplete:
#   2 usage / unknown role   3 no-catalog (deep, or an override, cannot be verified)
#   4 invalid-override (unreadable, unlisted, lower class, or not in catalog)
#   5 no-eligible-model (catalog has nothing at or above the required class)
# There is no silent downgrade: a `deep` requirement is never satisfied by a
# `standard`-only model, and an invalid override is never replaced by a default.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TABLE="${SGE_MODEL_ROLES_TABLE:-$HERE/model-roles.json}"

die() { echo "resolve-model: $2" >&2; exit "$1"; }

role="" security=0 want="" override="" override_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --role) role="${2:-}"; shift 2 || die 2 "--role needs a value" ;;
    --security) security=1; shift ;;
    --class) want="${2:-}"; shift 2 || die 2 "--class needs a value" ;;
    --override) override="${2:-}"; override_set=1; shift 2 || die 2 "--override needs a value" ;;
    *) die 2 "unknown argument: $1" ;;
  esac
done
[ -n "$role" ] || die 2 "--role is required"
command -v jq >/dev/null 2>&1 || die 3 "jq is required"

jq -e '.version == 1 and (.classes.standard|type=="array") and (.classes.deep|type=="array") and ((.classes.light // [])|type=="array") and ((.roles // {})|type=="object" and all(.[]; IN("light","standard","deep")))' "$TABLE" >/dev/null 2>&1 \
  || die 2 "model-roles table missing or invalid: $TABLE"

# Required class = the highest of: role default, --class, --security (=> deep).
rank() { case "$1" in light) echo 1 ;; standard) echo 2 ;; deep) echo 3 ;; *) echo 0 ;; esac; }
# An unknown role (typo, or the `@` spelling) never defaults to `standard`.
jq -e --arg r "$role" '(.roles // {}) | has($r)' "$TABLE" >/dev/null 2>&1 \
  || die 2 "unknown role: $role (not in $TABLE; pass the bare name, e.g. security-auditor)"
req="$(jq -r --arg r "$role" '.roles[$r]' "$TABLE" | tr -d '\r')"
[ -z "$want" ] || [ "$(rank "$want")" -gt 0 ] || die 2 "unknown --class: $want"
[ -n "$want" ] && [ "$(rank "$want")" -gt "$(rank "$req")" ] && req="$want"
[ "$security" -eq 1 ] && req="deep"

# Catalog: ABSENT means no catalog; a SUPPLIED one that is unreadable, unparseable or
# yields no ids is an error (exit 3), never read as absent.
catalog="" supplied=0
if [ -n "${SGE_MODEL_CATALOG_JSON:-}" ]; then catalog="$SGE_MODEL_CATALOG_JSON"; supplied=1
elif [ -n "${SGE_MODEL_CATALOG_FILE:-}" ]; then
  supplied=1
  [ -r "$SGE_MODEL_CATALOG_FILE" ] && catalog="$(cat "$SGE_MODEL_CATALOG_FILE")"
fi
ids=""
if [ -n "$catalog" ]; then
  ids="$(printf '%s' "$catalog" | jq -r 'if type=="array" then .[] | (if type=="object" then .id else . end) | select(type=="string" and length>0) else empty end' 2>/dev/null | tr -d '\r')" || ids=""
fi
if [ "$supplied" -eq 1 ] && [ -z "$ids" ]; then die 3 "no-catalog: the supplied model catalog is unreadable, invalid or empty"; fi
if [ "$supplied" -eq 0 ] && [ "${CLAUDECODE:-}" = "1" ]; then
  ids="$(jq -r '[.classes[]?[]] | unique | .[] | select(startswith("claude-"))' "$TABLE" | tr -d '\r')"
fi

# Project/explicit override. A present-but-malformed overrides document fails closed,
# and so does a SUPPLIED-but-empty override (--override "" or overrides.<role>: ""):
# "supplied" is tracked separately from the value so emptiness is never read as absent.
if [ "$override_set" -eq 0 ]; then
  doc=""
  if [ -n "${SGE_MODEL_OVERRIDES_JSON:-}" ]; then doc="$SGE_MODEL_OVERRIDES_JSON"
  elif [ -n "${SGE_MODEL_OVERRIDES_FILE:-}" ]; then
    [ -r "$SGE_MODEL_OVERRIDES_FILE" ] || die 4 "invalid-override: overrides file unreadable"
    doc="$(cat "$SGE_MODEL_OVERRIDES_FILE")"
  elif [ "$req" != "deep" ] && [ -r ./.sge/model-roles.json ]; then doc="$(cat ./.sge/model-roles.json)"; fi
  if [ -n "$doc" ]; then
    printf '%s' "$doc" | jq -e 'type=="object" and ((.overrides // {})|type=="object")' >/dev/null 2>&1 \
      || die 4 "invalid-override: overrides document is not valid"
    if printf '%s' "$doc" | jq -e --arg r "$role" '(.overrides // {}) | has($r)' >/dev/null 2>&1; then
      override_set=1
      override="$(printf '%s' "$doc" | jq -r --arg r "$role" '(.overrides // {})[$r] | if type=="string" then . else "" end' | tr -d '\r')"
    fi
  fi
fi

# Ids eligible for the required class, in preference order (data order; for
# `standard`/`light`, higher-class ids are a legitimate upward fallback, never the
# reverse). `light` (lightweight tier, e.g. haiku) prefers its own ids first.
case "$req" in
  deep)  eligible="$(jq -r '.classes.deep[]' "$TABLE" | tr -d '\r')" ;;
  light) eligible="$(jq -r '(.classes.light // [])[], .classes.standard[], .classes.deep[]' "$TABLE" | tr -d '\r')" ;;
  *)     eligible="$(jq -r '.classes.standard[], .classes.deep[]' "$TABLE" | tr -d '\r')" ;;
esac

if [ "$override_set" -eq 1 ]; then
  [ -n "$override" ] || die 4 "invalid-override: an empty override was supplied for $role"
  # Exactly one id: a newline would otherwise be read by grep as several patterns.
  [ "$override" = "${override//[^A-Za-z0-9._:\/-]/}" ] \
    || die 4 "invalid-override: an override must be a single model id for $role"
  [ -n "$ids" ] || die 3 "no-catalog: cannot verify override '$override'"
  printf '%s\n' "$eligible" | grep -Fxq -- "$override" \
    || die 4 "invalid-override: '$override' is not a listed $req-class model for $role"
  printf '%s\n' "$ids" | grep -Fxq -- "$override" \
    || die 4 "invalid-override: '$override' is not in the harness catalog"
  printf '%s\n' "$override"; exit 0
fi

if [ -z "$ids" ]; then
  [ "$req" != "deep" ] && { echo default; exit 0; }
  die 3 "no-catalog: a $req-class model cannot be verified for $role"
fi

while IFS= read -r m; do
  [ -n "$m" ] || continue
  if printf '%s\n' "$ids" | grep -Fxq -- "$m"; then printf '%s\n' "$m"; exit 0; fi
done <<< "$eligible"
die 5 "no-eligible-model: catalog offers no $req-class model for $role"
