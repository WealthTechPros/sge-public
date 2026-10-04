#!/usr/bin/env bash
# check-enforcement-required-checks.sh — are the enforced-profile gate checks
# REQUIRED status checks on the default branch? (SPEC-128 slice S3.)
# ---------------------------------------------------------------------------------------
# Read-only. Complements check-gate-coverage.sh, which proves from files that a
# gate is installed; this script asks the GitHub API whether branch protection
# or a ruleset actually requires it. Emits one JSON block on stdout and exits:
#   0 = pass (enforced: every gate required or under a live exception)
#       or info (onboarding: findings are informational)
#   1 = fail (enforced: >=1 gate not required; or a malformed posture.yaml)
#   2 = harness error (bad arguments)
#   3 = unknown (protection could not be read: 403/404, no credentials, or a
#       refused consumer CI token). Unknown is never reported as a pass.
#
# Gates (check context names, as the SGE workflows name their jobs):
#   Require commit trailer       exception gate: require-commit-trailer
#   Require test evidence        exception gate: require-test-evidence
#   Require enforcement profile  exception gate: branch-protection
#   Require pr-reviewed label    exception gate: branch-protection; checked only
#                                where .github/workflows/require-pr-reviewed-label.yml
#                                is adopted
# A live posture.yaml exception for the gate (or for branch-protection) turns
# a not-required/unknown gate into "exception", with its reason. An expired
# exception counts as absent.
#
# Sources: classic protection (repos/:r/branches/:b/protection/required_status_checks)
# and rulesets (repos/:r/rules/branches/:b). A gate found in either is
# required. A gate found in neither is not-required only when BOTH sources
# were readable; otherwise it is unknown, because the unreadable source might
# require it. Any 403 or 404 counts as unreadable.
#
# Credentials: run with operator or GitHub App installation credentials (for
# example GH_TOKEN set to an App installation token, or SGE_OPERATOR_TOKEN). Never a
# consumer repo's CI token: inside GitHub Actions only an SGE_OPERATOR_TOKEN
# distinct (whitespace-trimmed) from GITHUB_TOKEN, GH_TOKEN,
# GH_ENTERPRISE_TOKEN and GITHUB_ENTERPRISE_TOKEN is accepted; otherwise the
# script refuses and reports unknown without calling the API.
# Undetectable case: the CI token passed ONLY as SGE_OPERATOR_TOKEN, with none
# of those variables exported, cannot be told apart and is accepted (see the
# credentials section below for why that cannot produce a false pass).
#
# Profile: read with the plugin's scripts/read-enforcement-profile.sh.
#
# Usage: check-enforcement-required-checks.sh [repo-root] [owner/repo] [branch]
#   owner/repo defaults to `gh repo view` in repo-root; branch defaults to the
#   repository's default branch.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="$HERE/../../../scripts/read-enforcement-profile.sh"
GH="${SGE_GH:-gh}"

ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
[ -d "$ROOT" ] || { echo "check-enforcement-required-checks.sh: repo root not found: $ROOT" >&2; exit 2; }
REPO="${2:-}"
BRANCH="${3:-}"
TODAY="${SGE_TODAY:-$(date -u +%Y-%m-%d)}"

json_esc() { printf '%s' "$1" | tr '\n\t' '  ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

emit() { # <status> <profile> <sources-json> <gates-json> <findings-json>
  printf '%s\n' "{
  \"check\": \"enforcement-required-checks\",
  \"name\": \"Enforcement profile: required status checks (SPEC-128)\",
  \"layer\": \"governance-posture\",
  \"repo\": \"$(json_esc "$REPO")\",
  \"branch\": \"$(json_esc "$BRANCH")\",
  \"profile\": \"$2\",
  \"status\": \"$1\",
  \"sources\": $3,
  \"gates\": $4,
  \"findings\": $5
}"
}

# ---- profile ----------------------------------------------------------------
if ! PROFILE_OUT="$(bash "$READER" "$ROOT" 2>&1)"; then
  emit fail unreadable '{}' '[]' "[{\"artefact\":\".sge/posture.yaml\",\"severity\":\"high\",\"check\":\"enforcement-profile\",\"finding\":\"$(json_esc "$PROFILE_OUT")\"}]"
  exit 1
fi
PROFILE="$(printf '%s\n' "$PROFILE_OUT" | awk -F '\t' '$1 == "enforcement" { print $2 }')"

live_exception() { # <gate> -> "<reason> (<approver>, until <date>)" or nothing
  printf '%s\n' "$PROFILE_OUT" | awk -F '\t' -v g="$1" -v t="$TODAY" \
    '$1 == "exception" && NF == 5 && $5 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $2 == g && $5 >= t { print $3 " (" $4 ", until " $5 ")"; exit }'
}

# ---- credentials ----------------------------------------------------------------
# Inside GitHub Actions the step's GH_TOKEN is, in the standard setup
# (`env: GH_TOKEN: ${{ github.token }}`), the consumer CI token, and Actions
# does not export GITHUB_TOKEN by default, so GH_TOKEN cannot be told apart
# from it there (sge#2860 B4). In Actions the ONLY accepted credential is an
# SGE_OPERATOR_TOKEN that differs from both GITHUB_TOKEN and GH_TOKEN; pass
# the operator/App token as SGE_OPERATOR_TOKEN alone. Outside Actions an
# operator gh login, GH_TOKEN, or SGE_OPERATOR_TOKEN all work as before.
#
# On GHES gh prefers GH_ENTERPRISE_TOKEN / GITHUB_ENTERPRISE_TOKEN over
# GH_TOKEN, so the operator token must differ from those too, and is exported
# as all three so gh uses it whichever host it targets. Tokens are compared
# with surrounding whitespace trimmed.
#
# UNDETECTABLE CASE: if a workflow passes its own github.token ONLY as
# SGE_OPERATOR_TOKEN (no GH_TOKEN/GITHUB_TOKEN/enterprise token exported),
# nothing in the environment shows it is the CI token, so it is accepted. The
# impact is bounded: an Actions token cannot read classic branch protection,
# so that source is unreadable and any gate it alone could show reports
# unknown (exit 3), never not-required or a false pass. Pass only an
# operator or App installation token as SGE_OPERATOR_TOKEN.
tok_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  op="$(tok_trim "${SGE_OPERATOR_TOKEN:-}")"
  same_as_ci=0
  for t in "${GITHUB_TOKEN:-}" "${GH_TOKEN:-}" "${GH_ENTERPRISE_TOKEN:-}" "${GITHUB_ENTERPRISE_TOKEN:-}"; do
    [ -n "$op" ] && [ "$op" = "$(tok_trim "$t")" ] && same_as_ci=1
  done
  if [ -n "$op" ] && [ "$same_as_ci" -eq 0 ]; then
    export GH_TOKEN="$op" GH_ENTERPRISE_TOKEN="$op" GITHUB_ENTERPRISE_TOKEN="$op"
  else
    CRED_REFUSED="refusing to read branch protection with the consumer CI token inside GitHub Actions; set SGE_OPERATOR_TOKEN to an operator or GitHub App installation token that is not the workflow's github.token (and do not also set GH_TOKEN, GITHUB_TOKEN, GH_ENTERPRISE_TOKEN or GITHUB_ENTERPRISE_TOKEN to it)"
  fi
elif [ -n "$(tok_trim "${SGE_OPERATOR_TOKEN:-}")" ]; then
  export GH_TOKEN="$(tok_trim "$SGE_OPERATOR_TOKEN")"
fi

# ---- gates ------------------------------------------------------------------
CHECKS=("Require commit trailer" "Require test evidence" "Require enforcement profile")
GATES=("require-commit-trailer" "require-test-evidence" "branch-protection")
if [ -f "$ROOT/.github/workflows/require-pr-reviewed-label.yml" ] || [ -f "$ROOT/.github/workflows/require-pr-reviewed-label.yaml" ]; then
  CHECKS+=("Require pr-reviewed label"); GATES+=("branch-protection")
fi

# ---- read protection ----------------------------------------------------------
REQUIRED=""; prot_state=unread; rules_state=unread; prot_reason=""; rules_reason=""
if [ -z "${CRED_REFUSED:-}" ]; then
  if [ -z "$REPO" ]; then
    REPO="$(cd "$ROOT" && "$GH" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || REPO=""
  fi
  if [ -n "$REPO" ] && [ -z "$BRANCH" ]; then
    BRANCH="$("$GH" api "repos/$REPO" --jq .default_branch 2>/dev/null)" || BRANCH=""
  fi
  if [ -z "$REPO" ] || [ -z "$BRANCH" ]; then
    CRED_REFUSED="could not resolve the repository or its default branch with the available credentials"
  fi
fi

# gh_read <endpoint> <jq>: one API call, no temp file. stdout lines go to
# GH_OUT; the first stderr line goes to GH_ERR (stderr is tagged through a
# pipe; pipefail keeps gh's exit status). Returns gh's status.
GH_TAG='__sge_gh_stderr__:'
gh_read() {
  local res rc
  res="$( { "$GH" api "$1" --jq "$2" 2>&1 1>&3 3>&- | sed "s/^/$GH_TAG/"; } 3>&1 )"; rc=$?
  GH_OUT="$(printf '%s\n' "$res" | grep -v "^$GH_TAG")"
  GH_ERR="$(printf '%s\n' "$res" | sed -n "s/^$GH_TAG//p" | head -1)"
  return "$rc"
}
if [ -z "${CRED_REFUSED:-}" ]; then
  if gh_read "repos/$REPO/branches/$BRANCH/protection/required_status_checks" \
        '(.contexts // [])[], ((.checks // [])[] | .context)'; then
    prot_state=ok; REQUIRED="$REQUIRED"$'\n'"$GH_OUT"
  else
    prot_state=unknown; prot_reason="classic protection: $GH_ERR"
  fi
  if gh_read "repos/$REPO/rules/branches/$BRANCH" \
        '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context'; then
    rules_state=ok; REQUIRED="$REQUIRED"$'\n'"$GH_OUT"
  else
    rules_state=unknown; rules_reason="rulesets: $GH_ERR"
  fi
else
  prot_state=unknown; rules_state=unknown; prot_reason="${CRED_REFUSED}"; rules_reason="${CRED_REFUSED}"
fi
REQUIRED="$(printf '%s\n' "$REQUIRED" | tr -d '\r')"
unread_reason="$(printf '%s; %s' "$prot_reason" "$rules_reason" | sed -e 's/^; //' -e 's/; $//')"
sources_json="{\"protection\":\"$prot_state\",\"rulesets\":\"$rules_state\",\"reason\":\"$(json_esc "$unread_reason")\"}"

# ---- classify -------------------------------------------------------------------
gates_json=""; findings_json=""; n_not=0; n_unknown=0
for i in "${!CHECKS[@]}"; do
  c="${CHECKS[$i]}"; g="${GATES[$i]}"
  if printf '%s\n' "$REQUIRED" | grep -qxF -- "$c"; then
    st=required; ev="required status check on $BRANCH"
  elif [ "$prot_state" = ok ] && [ "$rules_state" = ok ]; then
    st=not-required; ev="$c is not a required status check on $BRANCH (classic protection and rulesets both read)"
  else
    st=unknown; ev="not found in the readable sources, and could not read the rest: $unread_reason"
  fi
  if [ "$st" != required ]; then
    exc="$(live_exception "$g")"; [ -n "$exc" ] || [ "$g" = branch-protection ] || exc="$(live_exception branch-protection)"
    if [ -n "$exc" ]; then st=exception; ev="posture.yaml exception: $exc"; fi
  fi
  case "$st" in
    not-required)
      n_not=$((n_not+1)); sev=high; [ "$PROFILE" = enforced ] || sev=info
      findings_json="${findings_json}{\"artefact\":\"branch-protection:$(json_esc "$BRANCH")\",\"severity\":\"$sev\",\"check\":\"enforcement-required-checks\",\"finding\":\"$(json_esc "$ev")\"}," ;;
    unknown)
      n_unknown=$((n_unknown+1))
      findings_json="${findings_json}{\"artefact\":\"branch-protection:$(json_esc "$BRANCH")\",\"severity\":\"medium\",\"check\":\"enforcement-required-checks\",\"finding\":\"$(json_esc "$c: unknown — $ev")\"}," ;;
  esac
  gates_json="${gates_json}{\"check\":\"$(json_esc "$c")\",\"gate\":\"$g\",\"status\":\"$st\",\"evidence\":\"$(json_esc "$ev")\"},"
done
gates_json="[${gates_json%,}]"; findings_json="[${findings_json%,}]"

if [ "$PROFILE" = enforced ] && [ "$n_not" -gt 0 ]; then
  emit fail "$PROFILE" "$sources_json" "$gates_json" "$findings_json"; exit 1
fi
if [ "$n_unknown" -gt 0 ]; then
  emit unknown "$PROFILE" "$sources_json" "$gates_json" "$findings_json"; exit 3
fi
if [ "$PROFILE" = enforced ]; then
  emit pass "$PROFILE" "$sources_json" "$gates_json" "$findings_json"; exit 0
fi
emit info "$PROFILE" "$sources_json" "$gates_json" "$findings_json"; exit 0
