#!/usr/bin/env bash
# review-lib.sh — sourced helpers for /sge:pr-review (issue #820, epic #729).
#
# Mechanical parsing extracted from SKILL.md so the model never re-derives or
# re-types it per invocation (the pr-labels.sh pattern — scripts cost zero
# context): bot-reviewer signal detection (#688), diff-risk classification
# (#688), the sge-phase5-verdict marker parse (pass-through mode), and the
# cursor-paginated unresolved-review-thread query (#717, fail-closed).
#
# Usage — SOURCE it (do not execute; rl_phase5_verdict sets caller variables):
#   source "${CLAUDE_PLUGIN_ROOT}/skills/pr-review/review-lib.sh"
#
#   rl_security_glob_regex          print the canonical security-path ERE
#   rl_security_files <pr>          changed files matching the security globs
#   rl_bot_signal <pr>              JSON: bot reviews + inline comments (#688)
#   rl_diff_risk <pr> [bot_hot]     print low|medium|high (bot_hot=1 when
#                                   BOT_FINDINGS carries a major/blocker).
#                                   The >400-line `high` leg uses the
#                                   test/doc-weighted count (#984), not raw
#                                   additions+deletions — see
#                                   rl_diff_weighted_lines.
#   rl_diff_weighted_lines <pr>     print "<weighted> <raw>" changed-line
#                                   counts (#984) — weighted subtracts lines
#                                   in test/BDD/doc files (rl_test_doc_glob_
#                                   regex) from the raw total; falls back to
#                                   raw==weighted on any fetch/parse error
#                                   (fails closed toward the raw, larger
#                                   count — never silently downgrades risk)
#   rl_test_doc_glob_regex          print the canonical test/BDD/doc-path ERE
#                                   used by rl_diff_weighted_lines (#984)
#   rl_diff_trivial <pr>            print 1|0 — issue #973 `trivial` tier
#                                   gate: 1 only for a whitespace-only diff
#                                   (git diff -w/-b leaves nothing) OR a
#                                   single-file dependency-lockfile diff with
#                                   a passing check already on the PR. FAIL
#                                   CLOSED to 0 (never-trivial) on any
#                                   fetch/parse failure — a false "trivial"
#                                   would skip specialist dispatch entirely.
#   rl_phase5_verdict <pr>          sets PHASE5_SHA / PHASE5_VERDICT /
#                                   PHASE5_BLOCKERS in the caller's shell
#   rl_unresolved_threads <pr>      JSON array of unresolved threads; non-zero
#                                   exit on ANY query failure (fail closed —
#                                   a failed query is never "0 unresolved")
#   rl_head_sha <pr>                print the PR head SHA (REST — reliable
#                                   where GraphQL-by-number is flaky)
#   rl_idempotency_check <pr> <state_json> <head_sha>
#                                   MECHANICAL Stage 0 gate (#1973) — returns
#                                   non-zero (refuse) when the PR is already
#                                   reviewed at the current head or closed/merged;
#                                   0 (proceed) otherwise. Prints an observable
#                                   refusal message so a silent skip is never
#                                   indistinguishable from the bug it replaces.
#                                   Fails OPEN: any parse/fetch error → proceed
#                                   (a wrong "proceed" wastes tokens; a wrong
#                                   "refuse" skips a needed review — worse).
#   rl_pr_state <pr>                one-line {state,draft,head,labels} JSON
#                                   for the #699 idempotency short-circuit
#   rl_ensure_closing_link <pr> <n> append "Fixes #n" to the PR body unless a
#                                   closing keyword for #n is already present
#   rl_qa_evidence <pr>             sets QA_COMMENT / QA_HEAD_SHA from the
#                                   latest qa-audit-report comment (#732)
#   rl_changes_requested <pr>       count of CHANGES_REQUESTED reviews across
#                                   the whole PR (must be 0 to arm auto-merge)
#   rl_failing_checks <pr>          count of FAILURE/TIMED_OUT checks
#   rl_reviewer_ran <tool_uses> [reply_file]
#                                   verify a dispatched review subagent ACTUALLY
#                                   RAN before its verdict is folded into the
#                                   Phase 5 aggregate (#883). Prints
#                                   ran | not-run:zero-tools | not-run:no-findings
#                                   exit 0 only when it ran; fails CLOSED toward
#                                   re-run. reply from stdin ("-"/omitted) or file.
#                                   When tool_uses>0 and the reply is non-empty,
#                                   prose-only (no JSON array) is accepted as ran
#                                   — fixes the "[] -findings deadlock" (#1314).
#   rl_attest_reset <pr>            clear the per-PR attestation ledger at the
#                                   start of a fresh review (#883)
#   rl_reviewer_dispatch <pr> <id>  record a dispatched Layer 2/3 reviewer as
#                                   PENDING in the ledger (#883)
#   rl_reviewer_attest <pr> <id> <tool_uses> [reply_file]
#                                   run rl_reviewer_ran for that reviewer and, on
#                                   `ran`, mark it ATTESTED in the ledger; leaves
#                                   it PENDING (exit 1) otherwise so `pass` stays
#                                   blocked until re-run (#883)
#   rl_attest_pending <pr>          print the count of dispatched-but-unattested
#                                   reviewers — pr-labels.sh `pass` refuses (exit
#                                   5) while this is > 0, mirroring the #754
#                                   SGE_REVIEW_ADVISORY exit-4 backstop (#883)
#   rl_review_identity              print "app" | "pat" — the review identity mode
#                                   (#862). app when wtp-sge App creds are in the
#                                   env; pat (LOGGED fallback) otherwise.
#   rl_app_jwt                      print an RS256-signed App JWT (openssl)
#   rl_app_installation_token       print an installation access token (verbatim
#                                   from SGE_REVIEW_APP_TOKEN, else minted)
#   rl_app_token_cached             print the App installation token, memoised
#                                   for the shell (mint at most once/dispatch);
#                                   non-zero + no output when no App creds (#1149)
#   rl_gh <gh-args...>              run `gh` under the wtp-sge App token (15k/hr
#                                   App tier) when available, else the ambient
#                                   PAT (5k/hr, warned once). App-auth-by-default
#                                   transport — biggest rate-limit lever (#1149)
#   rl_post_verdict <pr> <event> [body]
#                                   post the verdict (APPROVE|REQUEST_CHANGES|
#                                   COMMENT) as a REAL App-authored review when in
#                                   app mode, else the PAT path with the
#                                   self-authored --comment fallback (#862).
#                                   Refuses (exit 6) a verdict declaring
#                                   findings whose findings_comment is not
#                                   `inline` or a verified URL (#1858)
#   rl_post_findings_comment <pr> [file|-]
#                                   post the findings comment and read it back
#                                   by id before printing its URL; non-zero +
#                                   no output on ANY failure — the caller must
#                                   then fold the findings into the verdict
#                                   body (`findings_comment: inline`), never
#                                   post the verdict as if they landed (#1858)
#   rl_verdict_findings_total <body> print blockers+majors+minors from the
#                                   sge-verdict block ("" = no count triple)
#   rl_verdict_findings_ref <body>  print the findings_comment: value ("" =
#                                   field absent)
#   rl_verdict_findings_unverified <pr> <body>
#                                   exit 0 ("block") when declared findings
#                                   have no verified delivery route (#1858)
#   rl_is_rate_limit_error <text>   print 1|0 — does a `gh` stderr/output blob
#                                   look like a GitHub rate-limit response
#                                   (403 + "rate limit"/"API rate limit
#                                   exceeded"/"secondary rate limit", or a 429)?
#                                   (#1147) Pure string match, no network call.
#   rl_rate_limit_status            print "<remaining> <limit> <reset_epoch>"
#                                   for the REST core quota via the cheap
#                                   GraphQL `rateLimit{remaining,limit,
#                                   resetAt}` field (cost 0-1, #1147) — this is
#                                   the SAME quota bucket `gh api`/`gh pr view`
#                                   REST calls draw from. Non-zero exit + no
#                                   output on any fetch/parse failure (the
#                                   caller must treat that as unknown, not as
#                                   "quota is fine").
#   rl_rate_limit_exhausted [floor] print 1|0 — REST remaining <= floor
#                                   (default 50, SGE_REVIEW_RATE_LIMIT_FLOOR)?
#                                   Fails closed to 0 (assume NOT exhausted,
#                                   i.e. do not spuriously abort a healthy
#                                   session) when the status can't be read —
#                                   loud stall detection needs a POSITIVE
#                                   signal, not an absence of one.
#   rl_fail_loud_rate_limited <pr> <context>
#                                   THE #1147 fix: call this at the top of any
#                                   retry loop around a `gh` REST call, or
#                                   right after a `gh` call fails, passing the
#                                   command's captured stderr as <context>
#                                   (also accepts stdin when <context> is "-").
#                                   If <context> itself carries a rate-limit
#                                   signature (rl_is_rate_limit_error), OR the
#                                   live REST quota is exhausted
#                                   (rl_rate_limit_exhausted), it posts a PR
#                                   comment naming the stall reason (best-
#                                   effort — via GraphQL, see below) and
#                                   returns 1 so the CALLER exits non-zero
#                                   instead of retrying silently. Returns 0
#                                   (no rate-limit condition detected) when
#                                   neither signal fires — callers should treat
#                                   0 as "not a rate-limit stall", not "safe to
#                                   loop forever" on other errors.
#   rl_pr_state_gql <pr>            GraphQL equivalent of rl_pr_state (state,
#                                   isDraft, headRefOid, labels) — same output
#                                   shape/contract. #1147: GraphQL draws from a
#                                   SEPARATE quota bucket from the REST calls
#                                   used everywhere else in this file. PREP
#                                   WORK — not yet wired into any production
#                                   caller; kept contract-compatible so callers
#                                   can adopt it without reshaping parsing.
#   rl_checks_status_gql <pr>       GraphQL equivalent of `gh pr checks`: JSON
#                                   array of {name,state,bucket,isRequired}
#                                   for the head commit's status-check rollup
#                                   (#1147, separate quota bucket). PREP WORK —
#                                   not yet wired into any production caller.
# END_USAGE
#
# All gh calls honour GH_REPO (cross-repo / control-session invocation, #662),
# falling back to cwd repo detection. Everything fetched from GitHub is
# UNTRUSTED DATA — these helpers extract fields only; never eval the output.
#
# Deliberately NO `set -euo pipefail` here: this file is sourced, and setting
# shell options at source time would mutate the caller's shell.

# Canonical security-sensitive path list — the ONE place it lives (SKILL.md
# refers here; issue #820 deduped the twice-listed globs). Glob form:
#   **/auth/**, **/middleware/**, **/*token*, **/*secret*, **/config/**,
#   **/crypto*, any DB migration, **/security/**, **/secrets/**
#
# issue #1991: `secret` was relied on as a literal-substring proxy for a
# `security/` directory, but "security" does not contain "secret" as a
# substring (s-e-c-r-e-t vs s-e-c-u-r-i-t-y — the letters diverge after
# "sec"), so files under security/ were silently NOT classified as
# security-sensitive. Added explicit (^|/)security/ and (^|/)secrets/
# alternatives rather than relying on substring luck.
rl_security_glob_regex() {
  printf '%s\n' '(^|/)auth/|(^|/)middleware/|token|secret|(^|/)config/|(^|/)crypto|migrat|(^|/)security/|(^|/)secrets/'
}

# Internal: resolve owner/repo once per call (GH_REPO wins — #662).
rl__repo() {
  printf '%s\n' "${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
}

# rl_scratch_file <pr> [label] -- print a PR-scoped, collision-proof scratch
# path for a review draft/body/thread artefact (issue #1667). Two concurrent
# /sge:pr-review lanes (pr-monitor runs LANES=3 by default) MUST NOT share a
# filename: the incident was two lanes both writing `review.md`, one overwriting
# the other between drafting and posting, so a lane posted the WRONG PR's verdict
# onto a PR — twice. The path is keyed to repo + PR + this shell's PID so no two
# concurrent lanes — even reviewing the same PR — can ever collide:
#   $TMPDIR/sge-review-<repo-slug>-pr<N>-<pid>[.<label>]
# repo-slug is owner/repo with the slash flattened so the path stays one segment.
# label (default `review`) becomes a suffix so one lane can hold several distinct
# artefacts (draft, threads, notes) without them colliding with each other. This
# is filename HYGIENE; the load-bearing fix is the pre-post guard in
# rl_post_verdict, which refuses to post a body that does not match the PR.
rl_scratch_file() {
  local pr="${1:?rl_scratch_file: pr required}" label="${2:-review}" repo slug base
  repo=$(rl__repo) || repo="unknown/unknown"
  # Flatten every path-hostile char (slash, etc.) so the slug is one segment.
  slug=$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '-')
  base="sge-review-${slug}-pr${pr}-$$"
  [ "$label" = "review" ] || base="${base}.${label}"
  printf '%s\n' "${TMPDIR:-/tmp}/${base}"
}

# Changed files at the PR head matching the security globs. Empty output (and
# exit 0) = no security-sensitive files in the diff. Non-zero exit = the file
# list could not be fetched — FAIL CLOSED: callers (rl_diff_risk, the Layer 1
# /security-review trigger) must treat that as unverifiable, never as "no
# security-sensitive files". The gh call's status is captured before the grep
# so grep's no-match exit 1 is never conflated with an API failure.
rl_security_files() {
  local pr="$1" repo files
  repo=$(rl__repo) || return 1
  files=$(gh pr diff "$pr" --repo "$repo" --name-only) || return 1
  printf '%s\n' "$files" | grep -E "$(rl_security_glob_regex)" || true
}

# Refusal-stub pattern (#884). Copilot sometimes posts a real COMMENTED review
# whose body is literally a "quota limit reached" / "unable to review" refusal —
# a Bot account emitting ZERO opinions. Counting it as a clean bot pass would
# suppress specialist dispatch on coverage that never happened, so a body
# matching this pattern is treated as no signal at all. Matched case-
# insensitively (RE2/Oniguruma-safe — no backrefs/lookaround). Covers the
# issue's three canonical markers ("quota limit", "rate limit", "unable to
# review") plus the negated "…able to review" phrasing Copilot emits when it
# skips files ("was/wasn't/were/weren't/could/couldn't/did/didn't not able to
# review …files"), which does not always carry a quota word.
rl_bot_refusal_regex() {
  printf '%s\n' "quota limit|rate limit|unable to review|(was ?n'?t|were ?n'?t|could ?n'?t|did ?n'?t|was not|were not|could not|did not|not) able to review"
}

# Bot-reviewer signal (#688, #884). A match requires ALL of: a bot-shaped login
# — word-boundary anchored so a human login like `abbott` never matches — AND
# .user.type == "Bot" (the login string is attacker-controlled: a human
# account named e.g. `totally-copilot` could otherwise fake a clean bot
# review to suppress specialist dispatch; the account type cannot be faked) AND
# a body that is NOT a quota-limit/refusal stub (#884 — a refusal is zero
# opinions, never a clean pass). Emits one JSON object per hit: reviews as
# {kind:"review",author,state,body}, inline comments as
# {kind:"comment",author,path,line,body}.
# No output = no bot signal (a normal, common case — blocks nothing).
rl_bot_signal() {
  local pr="$1" repo refusal
  repo=$(rl__repo) || return 1
  # Injected via the environment (env.REFUSAL_RE): `gh api --jq` has no --arg
  # passthrough, so the regex is read from a per-command env var. Both gh's
  # embedded gojq and standalone jq expose `env`. The var is our own constant,
  # not untrusted data.
  refusal=$(rl_bot_refusal_regex)
  REFUSAL_RE="$refusal" gh api "repos/$repo/pulls/$pr/reviews" --jq \
    '.[] | select(.user.type == "Bot" and (.user.login | test("\\[bot\\]$|\\b(copilot|codeql|dependabot|semgrep|bot)\\b"; "i")) and (((.body // "") | test(env.REFUSAL_RE; "i")) | not)) | {kind: "review", author: .user.login, state: .state, body: .body}' \
    || return 1
  REFUSAL_RE="$refusal" gh api "repos/$repo/pulls/$pr/comments" --jq \
    '.[] | select(.user.type == "Bot" and (.user.login | test("\\[bot\\]$|\\b(copilot|codeql|dependabot|semgrep|bot)\\b"; "i")) and (((.body // "") | test(env.REFUSAL_RE; "i")) | not)) | {kind: "comment", author: .user.login, path: .path, line: .line, body: .body}' \
    || return 1
}

# Test/BDD/doc-file glob regex (#984) — files whose changed lines inflate
# the raw changed-line count without adding review surface: unit/component
# tests, BDD feature files and step defs, and doc/spec prose. ERE, matched
# against each changed file's path. Glob form (SKILL.md Phase 2):
#   **/*.test.ts, **/*.spec.ts, **/__tests__/**, **/*.feature, **/steps/**,
#   docs/**
rl_test_doc_glob_regex() {
  printf '%s\n' '\.(test|spec)\.[A-Za-z0-9]+$|(^|/)__tests__/|\.feature$|(^|/)steps/|(^|/)docs/'
}

# Weighted vs. raw changed-line counts for diff-risk tiering (#984). Prints
# "<weighted> <raw>" (space-separated, one gh call plus one cheap --jq
# filter — no new tool). `weighted` = raw additions+deletions MINUS the
# additions+deletions of every changed file matching rl_test_doc_glob_regex
# — a test/doc-heavy diff no longer trips the high-tier line-count trapdoor
# on line count alone. FAILS CLOSED: any fetch/parse failure on the per-file
# breakdown falls back to weighted==raw (the larger, more conservative
# value) rather than guessing a discount — a diff that can't be weighted is
# never silently downgraded out of `high`.
rl_diff_weighted_lines() {
  local pr="$1" repo raw testdoc re
  repo=$(rl__repo) || return 1
  raw=$(gh api "repos/$repo/pulls/$pr" --jq '.additions + .deletions') || return 1
  re=$(rl_test_doc_glob_regex)
  testdoc=$(RE="$re" gh pr view "$pr" --repo "$repo" --json files --jq \
    '([.files[] | select(.path | test(env.RE)) | (.additions + .deletions)] | add // 0)' 2>/dev/null)
  case "$testdoc" in
    ''|*[!0-9]*) printf '%s %s\n' "$raw" "$raw"; return 0 ;;
  esac
  testdoc=$((raw - testdoc))
  [ "$testdoc" -lt 0 ] && testdoc=0
  printf '%s %s\n' "$testdoc" "$raw"
}

# Diff-risk tier (#688) — drives Phase 2 dispatch scaling.
#   high:   any changed file matches the security globs, OR > 400
#           test/doc-WEIGHTED changed lines (#984 — see
#           rl_diff_weighted_lines; a diff that is mostly new tests/BDD/docs
#           no longer trips this leg on raw line count alone), OR bot_hot=1
#           (BOT_FINDINGS carries a major/blocker)
#   low:    <= 150 RAW changed lines AND no security match AND bot_hot != 1
#           (unchanged by #984 — only the high-tier leg is weighted)
#   medium: everything else
rl_diff_risk() {
  local pr="$1" bot_hot="${2:-0}" repo wl weighted raw sec
  repo=$(rl__repo) || return 1
  wl=$(rl_diff_weighted_lines "$pr") || return 1
  weighted=${wl%% *}
  raw=${wl##* }
  sec=$(rl_security_files "$pr") || return 1
  if [ -n "$sec" ] || [ "$weighted" -gt 400 ] || [ "$bot_hot" = "1" ]; then
    echo high
  elif [ "$raw" -le 150 ]; then
    echo low
  else
    echo medium
  fi
}

# Canonical dependency-lockfile basename list — single source, reused by
# rl_diff_trivial. Matches by basename so nested workspace paths still hit
# (e.g. packages/foo/package-lock.json).
rl_lockfile_glob_regex() {
  printf '%s\n' '(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Gemfile\.lock|poetry\.lock|Cargo\.lock|go\.sum|composer\.lock)$'
}

# `trivial` risk tier gate (issue #973). Narrower and cheaper than `low`:
# returns 1 ONLY when the diff is provably non-semantic, by one of two
# independently-sufficient tests. FAILS CLOSED to 0 on any error — this
# gate skips specialist dispatch entirely when it fires, so a wrong "1" is
# far more costly than a missed "1" (which just falls back to normal `low`
# tier dispatch scaling, never a correctness gap).
#
#   1. Whitespace-only: `git diff -w -b` between the PR's merge-base and
#      head, restricted to the PR's own changed files, leaves an empty
#      diff. This is a MECHANICAL check (git's own whitespace-aware diff
#      algorithm), not a heuristic — it never misclassifies a diff that
#      also touches a comment/logic line, because -w/-b only ignores
#      whitespace, not comment or token content. A diff whose comment
#      block accompanies a real logic change (the PR #2207 case in #973)
#      always has non-whitespace hunks left over, so it is correctly
#      rejected here.
#   2. Single-file lockfile change with a passing check: exactly one
#      changed file, its basename matches rl_lockfile_glob_regex, AND at
#      least one check on the PR head is currently SUCCESS (a bare
#      "no failing checks yet" is not enough — something must have
#      actually run and passed).
#
# Requires CWD inside a clone of the PR's repo with the PR's merge-base
# reachable (the same assumption pr-labels.sh's head-convergence check
# makes) — control-session/non-clone callers fall back to 0 (never-trivial,
# fail closed) rather than guessing.
rl_diff_trivial() {
  local pr="$1" repo base head files f nonws checks
  repo=$(rl__repo) || { echo 0; return 0; }

  base=$(gh api "repos/$repo/pulls/$pr" --jq '.base.sha' 2>/dev/null) || { echo 0; return 0; }
  head=$(gh api "repos/$repo/pulls/$pr" --jq '.head.sha' 2>/dev/null) || { echo 0; return 0; }
  [ -n "$base" ] && [ -n "$head" ] || { echo 0; return 0; }

  files=$(gh pr diff "$pr" --repo "$repo" --name-only 2>/dev/null) || { echo 0; return 0; }
  [ -n "$files" ] || { echo 0; return 0; }

  # Read the changed-file list into an array so the `git diff` pathspec is
  # passed as EXPLICIT separate arguments — never relying on the caller's
  # shell to word-split an unquoted `$files` (issue #1492). This file is
  # SOURCED, so it runs under whatever shell the operator uses: bash splits an
  # unquoted parameter on IFS, but zsh does NOT split unquoted parameters by
  # default, so under a zsh-default box `-- $files` stayed a single newline-
  # joined pathspec that matched no file — `git diff -w -b` then saw an empty
  # diff and a multi-file change was misclassified trivial=1, silently skipping
  # specialist (incl. @security-auditor) dispatch. Split on NEWLINES only (gh
  # --name-only is newline-delimited) so paths containing spaces survive intact.
  local -a filesarr=()
  while IFS= read -r f; do
    [ -n "$f" ] && filesarr+=("$f")
  done <<EOF
$files
EOF

  # Test 1: whitespace-only diff (git's own -w/-b, not a text heuristic).
  if [ "${#filesarr[@]}" -gt 0 ] \
      && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      && git cat-file -e "$base" 2>/dev/null && git cat-file -e "$head" 2>/dev/null; then
    nonws=$(git diff -w -b --numstat "$base" "$head" -- "${filesarr[@]}" 2>/dev/null | wc -l) || nonws=""
    if [ -n "$nonws" ] && [ "$nonws" -eq 0 ]; then
      echo 1
      return 0
    fi
  fi

  # Test 2: single-file lockfile-only change with a passing check.
  if [ "$(printf '%s\n' "$files" | grep -c .)" = "1" ] \
      && printf '%s' "$files" | grep -qE "$(rl_lockfile_glob_regex)"; then
    checks=$(gh pr checks "$pr" --repo "$repo" --json state --jq \
      '[.[] | select(.state == "SUCCESS")] | length' 2>/dev/null) || checks=""
    if [ -n "$checks" ] && [ "$checks" -gt 0 ]; then
      echo 1
      return 0
    fi
  fi

  echo 0
}

# Canonical location of the repo-level generated-artefact manifest (issue #1757).
# One record per line, TAB-separated: <artefact-path>\t<generator-command>\t
# <published 0|1>. Lines starting with `#` and blank lines are ignored. The
# classifier (rl_diff_generated) reads only the artefact-path column; the
# generator command and published flag are consumed by pr-review's Phase 2
# regenerate-and-byte-diff / content-safety steps (see SKILL.md).
rl_generated_manifest_path() {
  printf '%s\n' '.sge/generated-artefacts.tsv'
}

# `generated` risk-tier gate (issue #1757). Prints 1 ONLY when EVERY file in the
# diff is a generated artefact DECLARED in the base-ref manifest — i.e. the diff
# is entirely mechanically-reproducible output whose correctness is settled by
# regenerate-and-byte-diff (a Phase-2 dispatch step), not line-by-line review.
# Like rl_diff_trivial this is a MECHANICAL classifier that runs NO generator
# code itself; it only decides the tier. FAILS CLOSED to 0 (never-generated) on
# any error, an empty diff, an absent/unreadable manifest, or ANY changed file
# not declared — so an unverifiable "generated" file is never downgraded, and a
# diff that also touches the generator (never a declared artefact path) keeps its
# own normal tier (acceptance criteria 3 & 4).
#
# SECURITY: the manifest is read from the PR's BASE sha, never the PR head, so a
# PR cannot add a manifest entry for its own changed file to earn the cheaper
# path. That guarantee only holds when the base ref is a REVIEW-GATED branch, so
# the gate additionally requires the PR to target the repo's DEFAULT branch
# (`.base.ref == .default_branch`) — otherwise an actor with push access to some
# unprotected branch could land a self-serving manifest there and open/retarget a
# PR against it. A PR targeting any non-default branch falls back to 0 (never
# downgraded) rather than trusting a manifest at an ungated ref. Requires CWD
# inside a clone of the PR's repo with the base sha reachable (same assumption as
# rl_diff_trivial); a non-clone/control-session caller falls back to 0.
#
# SECURITY (high-risk always wins): a declared artefact may still sit on a
# security-sensitive path (a generated auth/config/migration file). Byte-diff
# proves the output matches its generator; it proves NOTHING about whether that
# output is safe. So the gate ALSO fails closed to 0 when ANY changed file
# matches rl_security_glob_regex — the diff then keeps its normal tier, which
# rl_diff_risk classifies `high` on that same security match. A generated
# artefact can never downgrade a security-sensitive diff.
rl_diff_generated() {
  local pr="$1" repo base base_ref default_branch files manifest decl f sec
  repo=$(rl__repo) || { echo 0; return 0; }

  base=$(gh api "repos/$repo/pulls/$pr" --jq '.base.sha' 2>/dev/null) || { echo 0; return 0; }
  [ -n "$base" ] || { echo 0; return 0; }

  # Trust the base-ref manifest only when the PR targets the review-gated
  # default branch (see SECURITY note). Any fetch failure -> fail closed.
  base_ref=$(gh api "repos/$repo/pulls/$pr" --jq '.base.ref' 2>/dev/null) || { echo 0; return 0; }
  default_branch=$(gh api "repos/$repo" --jq '.default_branch' 2>/dev/null) || { echo 0; return 0; }
  [ -n "$base_ref" ] && [ -n "$default_branch" ] && [ "$base_ref" = "$default_branch" ] \
    || { echo 0; return 0; }

  files=$(gh pr diff "$pr" --repo "$repo" --name-only 2>/dev/null) || { echo 0; return 0; }
  [ -n "$files" ] || { echo 0; return 0; }

  # HIGH RISK ALWAYS WINS: any security-sensitive path in the diff -> never
  # `generated`, so rl_diff_risk classifies it `high` on the same match and it
  # gets the full treatment (see SECURITY note above). Fail closed on lookup
  # failure too — rl_security_files already fails closed for an unfetchable list.
  sec=$(rl_security_files "$pr") || { echo 0; return 0; }
  [ -z "$sec" ] || { echo 0; return 0; }

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo 0; return 0; }
  git cat-file -e "$base" 2>/dev/null || { echo 0; return 0; }

  # Trusted manifest from the BASE ref. MSYS_NO_PATHCONV keeps the `<ref>:<path>`
  # colon-arg intact on git-bash/Windows (raw-git pitfall — see gh-repo SKILL).
  # Absent/unreadable at the base ref -> fail closed.
  manifest=$(MSYS_NO_PATHCONV=1 git show "$base:$(rl_generated_manifest_path)" 2>/dev/null) \
    || { echo 0; return 0; }
  [ -n "$manifest" ] || { echo 0; return 0; }

  # Declared artefact paths = first TAB-delimited field of each non-comment,
  # non-blank line (CRs stripped for cross-platform manifests).
  decl=$(printf '%s\n' "$manifest" | tr -d '\r' \
    | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | cut -f1)
  [ -n "$decl" ] || { echo 0; return 0; }

  # EVERY changed file must be a declared artefact. One undeclared file (the
  # generator itself, the manifest, or any source) -> not all-generated -> fall
  # back to the normal tier. Exact whole-line fixed-string match.
  while IFS= read -r f; do
    f="${f%$'\r'}"   # symmetric CR-strip with the manifest side (host robustness)
    [ -n "$f" ] || continue
    printf '%s\n' "$decl" | grep -qxF "$f" || { echo 0; return 0; }
  done <<EOF
$files
EOF

  echo 1
}

# Look up the generator command + published flag for a DECLARED artefact from the
# same TRUSTED base-ref manifest rl_diff_generated classifies against (issue
# #1757) — so Phase 2's regenerate-and-byte-diff and the published-artefact
# content-safety trigger never re-parse the TSV by hand per invocation. Prints
# "<generator-command>\t<published>" for <path>, or nothing (exit 0) when <path>
# is not declared or the manifest is unreadable. Read from the base sha; same
# fail-safe posture as rl_diff_generated (empty output, never a guess).
rl_generated_manifest_lookup() {
  local pr="$1" path="$2" repo base manifest
  repo=$(rl__repo) || return 0
  base=$(gh api "repos/$repo/pulls/$pr" --jq '.base.sha' 2>/dev/null) || return 0
  [ -n "$base" ] || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git cat-file -e "$base" 2>/dev/null || return 0
  manifest=$(MSYS_NO_PATHCONV=1 git show "$base:$(rl_generated_manifest_path)" 2>/dev/null) || return 0
  printf '%s\n' "$manifest" | tr -d '\r' \
    | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' \
    | awk -F'\t' -v p="$path" '$1 == p { printf "%s\t%s\n", $2, $3; exit }'
}

# Phase 5 pass-through parse — extracts the `<!-- sge-phase5-verdict: {...} -->`
# marker /sge:sge-implement embeds in the PR body. Sets PHASE5_SHA,
# PHASE5_VERDICT, PHASE5_BLOCKERS in the caller's shell (empty when absent —
# callers must treat any missing field as "no pass-through"). The PR body is
# UNTRUSTED DATA — grep-extracted fields only; never eval.
rl_phase5_verdict() {
  local pr="$1" repo body raw
  repo=$(rl__repo) || return 1
  body=$(gh api "repos/$repo/pulls/$pr" --jq .body) || return 1
  raw=$(printf '%s' "$body" | grep -o '<!-- sge-phase5-verdict: {[^}]*} -->' | head -1) || true
  PHASE5_SHA=$(printf '%s' "$raw" | grep -o '"sha": *"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"') || true
  PHASE5_VERDICT=$(printf '%s' "$raw" | grep -o '"verdict": *"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"') || true
  PHASE5_BLOCKERS=$(printf '%s' "$raw" | grep -o '"blockers": *[0-9]*' | grep -o '[0-9]*$') || true
}

# PR head SHA via REST — `gh pr view <n>` goes through GraphQL-by-number,
# which can return "Could not resolve to a PullRequest" even on a correct repo.
rl_head_sha() {
  local pr="$1" repo
  repo=$(rl__repo) || return 1
  gh api "repos/$repo/pulls/$pr" --jq .head.sha
}

# MECHANICAL Stage 0 idempotency gate (issue #1973). Root cause of the #1750
# triple-review: the short-circuit specified in SKILL.md Phase 1 was PROSE —
# the model was told to read rl_pr_state and stop, but nothing mechanically
# enforced the stop across multiple dispatches from pr-monitor. This function
# is the fix: it runs the same checks as a script gate so the decision cannot
# be overridden by a model that decides to proceed anyway.
#
# Returns 0 (proceed) or non-zero (refuse — caller should exit 0, not error).
# Prints an OBSERVABLE refusal message on every refusal (AC2 #1973: "not a
# silent no-op") so dispatchers can see why no review ran.
#
# FAILS OPEN: any parse/API error → return 0 (proceed). A wrong "proceed"
# wastes tokens on a redundant review; a wrong "refuse" skips a needed one.
# The subsequent start-review claim guard and the review itself catch any
# real issues.
rl_idempotency_check() {
  local pr="${1:?rl_idempotency_check: pr required}"
  local state="${2:?rl_idempotency_check: state json required}"
  local head="${3:-}"
  local pr_state labels last_verdict last_sha repo
  # Empty head (rl_head_sha failed) → can't verify idempotency → proceed.
  [ -n "$head" ] || return 0

  # 1. MERGED / CLOSED — no review needed.
  pr_state=$(printf '%s' "$state" | jq -r '.state // ""' 2>/dev/null) || pr_state=""
  case "$pr_state" in
    MERGED|CLOSED|merged|closed)
      echo "rl_idempotency_check: PR #${pr} is ${pr_state} — no review dispatched (issue #699, mechanical gate #1973)"
      return 1 ;;
  esac

  # 2. pr-reviewed present AND latest sge-verdict commit matches head.
  labels=$(printf '%s' "$state" | jq -r '.labels[]? // empty' 2>/dev/null) || labels=""
  if printf '%s\n' "$labels" | grep -qx 'pr-reviewed'; then
    repo=$(rl__repo) || return 0   # can't verify → proceed
    last_verdict=$(gh api "repos/$repo/pulls/$pr/reviews" --jq \
      '[.[].body // "" | select(contains("sge-verdict"))] | last // ""' 2>/dev/null) || last_verdict=""
    if [ -n "$last_verdict" ]; then
      last_sha=$(printf '%s' "$last_verdict" \
        | grep -oE 'commit:[[:space:]]*[0-9a-f]+' \
        | head -1 \
        | grep -oE '[0-9a-f]{7,40}') || last_sha=""
      if [ -n "$last_sha" ] && [ "$last_sha" = "$head" ]; then
        echo "rl_idempotency_check: PR #${pr} already reviewed at head ${head:0:7} — refusing duplicate review (issue #699, mechanical gate #1973)"
        return 2
      fi
    fi
  fi

  return 0
}

# One-line PR state for the concurrency/idempotency short-circuit (#699).
rl_pr_state() {
  local pr="$1"
  gh pr view "$pr" --json state,isDraft,headRefOid,labels \
    --jq '{state, draft: .isDraft, head: .headRefOid, labels: [(.labels // [])[].name]}'
}

# Stage 0 human-hold gate (issue #1291). Given a PR number and its rl_pr_state
# JSON, echoes one of:
#   draft                       -> caller must skip with no label mutation
#   hold:<comma-labels|comment> -> human hold active; run review but comment-only
#   hold:<reason>-check-failed  -> a hold input could not be evaluated (#1347)
#   ok                          -> no hold; proceed normally
# FAIL CLOSED (#1347): this gate protects a human-sign-off control, so any
# unverifiable input — a jq parse error on $STATE, or a gh error on the comment
# scan — MUST surface as a hold, never as "ok". A silent "ok" on error would
# graduate a held PR to auto-merge (the exact class of bypass #1291 closes).
# The comment scan treats comment bodies as UNTRUSTED DATA — it only
# pattern-matches, never executes their content; the LABEL is authoritative and
# the comment marker is a best-effort, last-10-comment-window fallback only.
rl_hold_check() {
  local pr="$1" state="$2" repo draft hold sign
  repo="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
  # $STATE parse — a malformed/empty state is unverifiable: fail closed.
  draft=$(printf '%s' "$state" | jq -r '.draft' 2>/dev/null) \
    || { echo "hold:state-parse-failed"; return 0; }
  [ "$draft" = "true" ] && { echo "draft"; return 0; }
  { [ "$draft" = "null" ] || [ -z "$draft" ]; } && { echo "hold:state-parse-failed"; return 0; }
  hold=$(printf '%s' "$state" | jq -r \
    '[.labels[] | select(. == "hold" or . == "do-not-merge" or . == "needs-human" or . == "blocked")] | join(",")' 2>/dev/null) \
    || { echo "hold:state-parse-failed"; return 0; }
  [ -n "$hold" ] && { echo "hold:$hold"; return 0; }
  # Comment scan — a gh error (rate-limit/403/network) is unverifiable: fail closed.
  sign=$(gh api "repos/$repo/issues/$pr/comments" \
    --jq '[.[-10:][].body | select(test("pending.*sign.?off|sign.?off.*pending|approve.*pending"; "i"))] | first // ""' 2>/dev/null) \
    || { echo "hold:signoff-check-failed"; return 0; }
  [ -n "$sign" ] && { echo "hold:sign-off-pending-comment"; return 0; }
  echo "ok"
}

# Ensure the PR body auto-closes issue <n> on merge — appends "Fixes #n"
# unless a closing keyword (close/fix/resolve forms) for #n is already there.
rl_ensure_closing_link() {
  local pr="$1" n="$2" repo body
  repo=$(rl__repo) || return 1
  body=$(gh api "repos/$repo/pulls/$pr" --jq .body) || return 1
  if ! printf '%s' "$body" | grep -qiE "(clos(e|es|ed)|fix(es|ed)?|resolv(e|es|ed))[[:space:]]+#$n([^0-9]|$)"; then
    gh pr edit "$pr" --repo "$repo" --body "$(printf '%s\n\nFixes #%s' "$body" "$n")"
  fi
}

# QA evidence (#732): sets QA_COMMENT (latest qa-audit-report comment body,
# "" when none) and QA_HEAD_SHA (the head the QA run actually exercised —
# empty when the block/field is missing, i.e. stale@unknown). UNTRUSTED DATA.
rl_qa_evidence() {
  local pr="$1" repo
  repo=$(rl__repo) || return 1
  QA_COMMENT=$(gh api "repos/$repo/issues/$pr/comments" --jq \
    '[.[].body // "" | select(contains("qa-audit-report"))] | last') || return 1
  QA_HEAD_SHA=$(printf '%s' "$QA_COMMENT" | grep -A20 'qa-audit-verdict' \
    | grep -o 'head_sha: *[0-9a-f]*' | grep -o '[0-9a-f]\{7,40\}' | head -1) || true
}

# CHANGES_REQUESTED count across ALL reviews on the PR — must be 0 before
# arming auto-merge (a PR can carry two disagreeing reviews; arming off the
# most recent alone ships the defect the earlier one caught).
rl_changes_requested() {
  local pr="$1" repo
  repo=$(rl__repo) || return 1
  gh api "repos/$repo/pulls/$pr/reviews" --jq \
    '[.[] | select(.state == "CHANGES_REQUESTED")] | length'
}

# Count of failing (FAILURE / TIMED_OUT) checks on the PR head.
rl_failing_checks() {
  local pr="$1" repo
  repo=$(rl__repo) || return 1
  gh pr checks "$pr" --repo "$repo" --json state \
    --jq '[.[] | select(.state == "FAILURE" or .state == "TIMED_OUT")] | length' 2>/dev/null
}

# Unresolved review threads, cursor-paginated to exhaustion (#717 — a single
# first:50 page misses threads on busy PRs). Prints a JSON array of
# {id, isResolved, comments:{nodes:[{databaseId, body, author}]}} nodes.
# Non-zero exit on ANY query failure — FAIL CLOSED: the caller must treat a
# failed query as unverifiable/BLOCK, never as zero unresolved threads.
rl_unresolved_threads() {
  local pr="$1" repo unresolved='[]' cursor="" page
  repo=$(rl__repo) || return 1
  # Cheap pre-check (issue #973): most PRs carry zero review threads at all.
  # A single `first:1 { totalCount }` query is ~1 API call vs. the full
  # cursor-paginated walk below; when totalCount is exactly 0 there is
  # nothing to page through, so return the empty array immediately. This
  # does NOT weaken the fail-closed contract above: if the pre-check itself
  # fails (transport error, unparsable response, non-numeric totalCount) we
  # fall straight through to the full paginated walk — a failed pre-check
  # is never read as "0 unresolved", only a successful totalCount==0 is.
  local precheck
  if precheck=$(gh api graphql -f query='
      query($owner:String!,$repo:String!,$pr:Int!){
        repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
          reviewThreads(first:1){ totalCount } } } }' \
      -f owner="${repo%/*}" -f repo="${repo#*/}" -F pr="$pr" \
      --jq '.data.repository.pullRequest.reviewThreads.totalCount' 2>/dev/null); then
    if [[ "$precheck" =~ ^[0-9]+$ ]] && [ "$precheck" -eq 0 ]; then
      printf '%s\n' '[]'
      return 0
    fi
  fi
  while :; do
    local args=(-f owner="${repo%/*}" -f repo="${repo#*/}" -F pr="$pr")
    [ -n "$cursor" ] && args+=(-f cursor="$cursor")
    page=$(gh api graphql -f query='
      query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
        repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
          reviewThreads(first:50, after:$cursor){
            pageInfo{ hasNextPage endCursor }
            nodes{ id isResolved
              comments(first:1){ nodes{ databaseId body author{ login } } } } } } } }' \
      "${args[@]}" --jq '.data.repository.pullRequest.reviewThreads') || return 1
    unresolved=$(jq -c --argjson acc "$unresolved" \
      '$acc + [.nodes[] | select(.isResolved==false)]' <<<"$page") || return 1
    [ "$(jq -r '.pageInfo.hasNextPage' <<<"$page")" = "true" ] || break
    cursor=$(jq -r '.pageInfo.endCursor' <<<"$page")
  done
  printf '%s\n' "$unresolved"
}

# Internal: from a subagent's raw reply (stdin), print the last fenced
# (```-delimited) block that parses as a JSON ARRAY — or the whole reply if it
# is itself a bare JSON array — and exit 0. Prints nothing and exits 1 when no
# parseable structured findings array is present. CR-stripped so it behaves
# identically on CRLF and LF checkouts. UNTRUSTED DATA: the reply is parsed
# for shape only, never eval'd.
rl__findings_array() {
  local text block last=""
  text=$(cat)
  # awk emits each CLOSED fenced block's content, blocks separated by \x1e.
  # An unterminated fence emits nothing (fail toward not-run). Fence lines
  # (``` optionally + language) toggle in/out; \r is stripped per line.
  while IFS= read -r -d $'\x1e' block; do
    # skip empty/whitespace-only blocks before the (cheap) jq parse
    [ -n "${block//[$' \t\r\n']/}" ] || continue
    if jq -e 'type=="array"' >/dev/null 2>&1 <<<"$block"; then last="$block"; fi
  done < <(printf '%s\n' "$text" | awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*```/ { if (inb) { printf "\x1e"; inb=0 } else { inb=1 }; next }
    inb { print }
  ')
  if [ -n "$last" ]; then jq -c . <<<"$last"; return 0; fi
  # Fallback: the entire reply is itself a bare JSON array.
  if jq -e 'type=="array"' >/dev/null 2>&1 <<<"${text//$'\r'/}"; then
    jq -c . <<<"${text//$'\r'/}"; return 0
  fi
  return 1
}

# Verify a dispatched review subagent ACTUALLY RAN before its (non-)result is
# folded into the Phase 5 aggregate verdict (#883). Observed twice in one
# session: a spawned specialist returned ZERO tool calls and a stray fragment
# of its own opening reasoning as its "result" — not a refusal, not an error,
# just silent non-work — and the parent's verdict trusted it as a clean pass,
# so the PR merged with an inaccurate section. Execution is judged by two
# signals, branched on whether the tool-count is known (see #1314 note below):
# a KNOWN 0-tool-call return is NON-EXECUTION; when the tool-count is unknown,
# a reply with no parseable structured findings array is NON-EXECUTION; either
# must be re-run (or the check done inline), never counted as a clean pass.
#
#   rl_reviewer_ran <tool_uses> [reply_file]
#     tool_uses  : the harness-reported tool-call count for the dispatched
#                  agent (integer), or "" / a non-numeric token when the
#                  dispatch surface reported none (then only the findings-array
#                  signal is used — the count cannot condemn what it cannot see)
#     reply_file : file holding the agent's raw reply; "-" or omitted = stdin
#
#   Prints:  ran | not-run:zero-tools | not-run:no-findings
#   Exit  :  0 when it ran (trustworthy); 1 otherwise (RE-RUN / do inline)
#
# FAILS CLOSED toward re-run: a wrong "ran" ships an unverified verdict (the
# exact #883 defect); a wrong "not-run" costs only one honest re-run. A genuine
# empty findings array `[]` from an agent that DID run tools is a real clean
# pass and is trusted — it is `[]` PLUS a zero tool count that is the trap.
# When tool_uses > 0 and the reply has non-whitespace content, a prose-only
# response (no JSON array) is ALSO accepted as ran — fixes the "[] -findings
# deadlock" where a truthful clean reviewer was blocked by not-run:no-findings
# even though it demonstrably ran tools and produced a coherent reply (#1314).
rl_reviewer_ran() {
  local tool_uses="${1:-}" reply_src="${2:--}" text
  # 1. Definitive non-execution: a KNOWN tool-use count of exactly 0.
  if [[ "$tool_uses" =~ ^[0-9]+$ ]] && [ "$tool_uses" -eq 0 ]; then
    echo "not-run:zero-tools"; return 1
  fi
  if [ "$reply_src" = "-" ]; then
    text=$(cat)
  else
    text=$(cat "$reply_src" 2>/dev/null) || { echo "not-run:no-findings"; return 1; }
  fi
  # 2. Known positive tool count + non-empty reply: the reviewer ran and
  #    produced a real response — accept it even without a JSON findings array.
  #    Fixes the "[] -findings deadlock" (#1314): a truthful clean reviewer
  #    that used tools but wrote prose (no JSON array) was blocked as
  #    not-run:no-findings even though it demonstrably executed.
  #    A 0-byte / whitespace-only reply is still treated as not-run regardless
  #    of tool count (a silent dispatch failure, not a clean verdict).
  if [[ "$tool_uses" =~ ^[0-9]+$ ]] && [ "$tool_uses" -gt 0 ]; then
    if [ -n "${text//[$' \t\r\n']/}" ]; then
      echo "ran"; return 0
    fi
    echo "not-run:no-findings"; return 1
  fi
  # 3. Unknown tool count: the structured findings array is the only execution
  #    signal — no array means the reply is the #883 stray-reasoning fragment
  #    or a 0-byte dispatch failure.
  if ! printf '%s' "$text" | rl__findings_array >/dev/null; then
    echo "not-run:no-findings"; return 1
  fi
  echo "ran"; return 0
}

# --- Mechanical attestation ledger (issue #883) ------------------------------
# rl_reviewer_ran is a correct pure function, but NOTHING forced the review
# procedure to call it: pr-labels.sh — the only real merge-gate script — had
# zero reference to it, so an orchestrating agent could skip the check exactly
# as in the original #883 incident and `pass` would still succeed. Prose-only
# "you must call the guard" restrictions demonstrably fail on dispatched agents
# (the same lesson as #754). These helpers make the guard MECHANICAL: every
# dispatched Layer 2/3 reviewer is recorded as PENDING when dispatched, and can
# only be cleared to ATTESTED by clearing rl_reviewer_ran. `pr-labels.sh pass`
# refuses (exit 5) while any PENDING reviewer remains — the same shape as the
# SGE_REVIEW_ADVISORY exit-4 backstop that #754 added to this exact flow.
#
# The ledger is a per-PR append-only file keyed by repo+PR under a session-
# stable dir (SGE_REVIEW_STATE_DIR, else TMPDIR/TEMP, else /tmp). A reviewer is
# PENDING when it has a `dispatch` line with no later `attest` line for the same
# id. NO dispatch record => 0 pending => an inline / no-fan-out review passes
# untouched (small PRs reviewed without specialists are unaffected). pr-labels.sh
# reads this same file+format directly (it does not source this lib); the path
# and awk logic are mirrored there and MUST stay in sync — see pr-labels.sh
# `_attest_pending` / `_ATTEST_FILE`.
rl__attest_file() {
  local pr="${1:?rl__attest_file: pr required}"
  local dir="${SGE_REVIEW_STATE_DIR:-${TMPDIR:-${TEMP:-/tmp}}}"
  local repo="${GH_REPO:-local}"
  repo="${repo//[^A-Za-z0-9._-]/_}"   # flatten owner/repo → owner_repo for a filename
  printf '%s/sge-review-attest.%s.%s' "$dir" "$repo" "$pr"
}

# rl_attest_reset <pr> — start a clean ledger for a fresh review pass.
rl_attest_reset() {
  local pr="${1:?rl_attest_reset: pr required}" f
  f=$(rl__attest_file "$pr") || return 1
  : > "$f" 2>/dev/null || return 1
}

# rl_reviewer_dispatch <pr> <agent_id> — record a dispatched reviewer as PENDING.
# Call this in the SAME message that spawns each Layer 2/3 specialist.
rl_reviewer_dispatch() {
  local pr="${1:?rl_reviewer_dispatch: pr required}" id="${2:?rl_reviewer_dispatch: agent id required}" f
  f=$(rl__attest_file "$pr") || return 1
  printf 'dispatch\t%s\n' "$id" >> "$f" || return 1
}

# rl_reviewer_attest <pr> <agent_id> <tool_uses> [reply_file] — verify + clear.
# Runs rl_reviewer_ran; on `ran` marks the reviewer ATTESTED (exit 0). Otherwise
# leaves it PENDING and returns 1 (so `pass` stays blocked until it is re-run).
# Prints the rl_reviewer_ran verdict (ran | not-run:zero-tools | not-run:no-findings).
rl_reviewer_attest() {
  local pr="${1:?rl_reviewer_attest: pr required}" id="${2:?rl_reviewer_attest: agent id required}"
  local tool_uses="${3:-}" reply="${4:--}" f verdict rc
  f=$(rl__attest_file "$pr") || return 1
  verdict=$(rl_reviewer_ran "$tool_uses" "$reply"); rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'attest\t%s\n' "$id" >> "$f" || return 1
  fi
  printf '%s\n' "$verdict"
  return "$rc"
}

# rl_attest_pending <pr> — count reviewers dispatched but not yet attested.
rl_attest_pending() {
  local pr="${1:?rl_attest_pending: pr required}" f
  f=$(rl__attest_file "$pr") || { echo 0; return 0; }
  [ -f "$f" ] || { echo 0; return 0; }
  awk -F'\t' '
    $1=="dispatch" { pend[$2]=1 }
    $1=="attest"   { delete pend[$2] }
    END { n=0; for (a in pend) n++; print n }
  ' "$f" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# App-identity review mode (issue #862).
#
# The whole pipeline builds AND reviews under one shared human gh identity, so
# GitHub blocks self-approval: every verdict degrades to a comment + the
# pr-reviewed label, and required-review branch protection is unusable because
# builder and reviewer are the same account. When the wtp-sge GitHub App's
# credentials are present in the environment, these helpers post the verdict as
# a REAL PR review authored by the App — a distinct identity from the human
# builder — so an APPROVE satisfies required-review branch protection and the
# builder != reviewer separation is visible in GitHub's own review model. When
# no App credentials are present the helpers fall back automatically (and
# loudly) to the current PAT/bot path.
#
# SECURITY: every credential is read from the environment ONLY (Doppler-style);
# nothing is hardcoded. Recognised vars (any one route enables App mode):
#   SGE_REVIEW_APP_TOKEN            a pre-minted installation access token
#                                   (e.g. from actions/create-github-app-token) --
#                                   preferred; needs no private-key handling here.
#   SGE_REVIEW_APP_ID +            mint-it-here route: App (client) id, the App
#   SGE_REVIEW_APP_PRIVATE_KEY      private key as literal PEM in the env, OR
#     (or _PRIVATE_KEY_FILE) +      SGE_REVIEW_APP_PRIVATE_KEY_FILE pointing at it,
#   SGE_REVIEW_APP_INSTALLATION_ID  and the installation id on the target org.
# The private key, if passed literally, is written to a umask-077 temp file only
# for the openssl call and removed immediately. Tokens are passed to a single
# child process via GH_TOKEN and never echoed.

# Back-compat alias (SGD -> SGE rebrand): the App-credential secrets on this
# repo (and any consumer that hasn't rotated yet) are still provisioned under
# the pre-rename SGD_REVIEW_APP_* names -- a secret rename is an out-of-band
# admin action, not something a source diff can do. Alias them into the
# canonical SGE_REVIEW_APP_* names here, ONCE, so every helper below keeps
# working under either naming convention without a silent, unannounced
# downgrade to PAT mode (which would quietly disable the builder != reviewer
# separation-of-duties control, issue #862).
: "${SGE_REVIEW_APP_TOKEN:=${SGD_REVIEW_APP_TOKEN:-}}"
: "${SGE_REVIEW_APP_ID:=${SGD_REVIEW_APP_ID:-}}"
: "${SGE_REVIEW_APP_PRIVATE_KEY:=${SGD_REVIEW_APP_PRIVATE_KEY:-}}"
: "${SGE_REVIEW_APP_PRIVATE_KEY_FILE:=${SGD_REVIEW_APP_PRIVATE_KEY_FILE:-}}"
: "${SGE_REVIEW_APP_INSTALLATION_ID:=${SGD_REVIEW_APP_INSTALLATION_ID:-}}"

# rl_review_identity -- print the review identity mode: "app" or "pat".
# app  = a complete App credential route is present in the env.
# pat  = no (or incomplete) App credentials -- fall back to the shared gh user;
#        the fallback is LOGGED to stderr (issue #862 asks for it to be logged).
rl_review_identity() {
  if [ -n "${SGE_REVIEW_APP_TOKEN:-}" ]; then
    echo "pr-review: App-token mode -- pre-minted installation token present; verdict posts as the wtp-sge App (builder != reviewer, issue #862)" >&2
    printf 'app\n'; return 0
  fi
  if [ -n "${SGE_REVIEW_APP_ID:-}" ] \
     && { [ -n "${SGE_REVIEW_APP_PRIVATE_KEY:-}" ] || [ -n "${SGE_REVIEW_APP_PRIVATE_KEY_FILE:-}" ]; } \
     && [ -n "${SGE_REVIEW_APP_INSTALLATION_ID:-}" ]; then
    echo "pr-review: App-token mode -- will mint an installation token from wtp-sge App credentials (builder != reviewer, issue #862)" >&2
    printf 'app\n'; return 0
  fi
  echo "pr-review: no complete wtp-sge App credentials in env -- falling back to PAT/bot review identity; self-approval is blocked so the verdict lands as comment + pr-reviewed label (issue #862)" >&2
  printf 'pat\n'
}

# rl__b64url -- read stdin, emit base64url with no padding (JWT segment encoding).
rl__b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# rl_app_jwt -- print an RS256-signed GitHub App JWT built from SGE_REVIEW_APP_ID
# and the App private key (PEM literal in SGE_REVIEW_APP_PRIVATE_KEY, or the file
# named by SGE_REVIEW_APP_PRIVATE_KEY_FILE). exp is 9 minutes out (< GitHub's
# 10-minute max) with a 60s backdated iat for clock skew. Fails CLOSED (non-zero,
# no output) when openssl, the App id, or the key is missing / signing fails.
rl_app_jwt() {
  local app_id keyfile cleanup="" now iat exp header payload signing_input sig
  app_id="${SGE_REVIEW_APP_ID:-}"
  [ -n "$app_id" ] || { echo "rl_app_jwt: SGE_REVIEW_APP_ID unset -- cannot build App JWT" >&2; return 1; }
  command -v openssl >/dev/null 2>&1 || { echo "rl_app_jwt: openssl not found -- cannot sign App JWT" >&2; return 1; }
  if [ -n "${SGE_REVIEW_APP_PRIVATE_KEY_FILE:-}" ]; then
    keyfile="${SGE_REVIEW_APP_PRIVATE_KEY_FILE}"
    [ -r "$keyfile" ] || { echo "rl_app_jwt: private-key file not readable: $keyfile" >&2; return 1; }
  elif [ -n "${SGE_REVIEW_APP_PRIVATE_KEY:-}" ]; then
    keyfile="$(mktemp)" || return 1
    cleanup="$keyfile"
    ( umask 077; printf '%s\n' "${SGE_REVIEW_APP_PRIVATE_KEY}" > "$keyfile" )
  else
    echo "rl_app_jwt: no private key (set SGE_REVIEW_APP_PRIVATE_KEY or _PRIVATE_KEY_FILE)" >&2; return 1
  fi
  now=$(date +%s); iat=$((now - 60)); exp=$((now + 540))
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | rl__b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$iat" "$exp" "$app_id" | rl__b64url)
  signing_input="${header}.${payload}"
  sig=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$keyfile" 2>/dev/null | rl__b64url)
  [ -n "$cleanup" ] && rm -f "$cleanup"
  [ -n "$sig" ] || { echo "rl_app_jwt: openssl signing failed (bad/unsupported key?)" >&2; return 1; }
  printf '%s.%s\n' "$signing_input" "$sig"
}

# rl_app_installation_token -- print an installation access token for the wtp-sge
# App. If SGE_REVIEW_APP_TOKEN is set it is returned verbatim (no network). Else
# it mints a JWT (rl_app_jwt) and exchanges it at
# POST /app/installations/{id}/access_tokens via curl. Fails CLOSED on any error.
rl_app_installation_token() {
  if [ -n "${SGE_REVIEW_APP_TOKEN:-}" ]; then
    printf '%s\n' "${SGE_REVIEW_APP_TOKEN}"; return 0
  fi
  local inst jwt resp tok api
  inst="${SGE_REVIEW_APP_INSTALLATION_ID:-}"
  [ -n "$inst" ] || { echo "rl_app_installation_token: SGE_REVIEW_APP_INSTALLATION_ID unset" >&2; return 1; }
  command -v curl >/dev/null 2>&1 || { echo "rl_app_installation_token: curl not found -- cannot exchange JWT for a token" >&2; return 1; }
  jwt=$(rl_app_jwt) || return 1
  api="${GITHUB_API_URL:-https://api.github.com}"
  resp=$(curl -sS -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${api}/app/installations/${inst}/access_tokens" 2>/dev/null) || {
      echo "rl_app_installation_token: token-exchange request failed" >&2; return 1; }
  tok=$(printf '%s' "$resp" | jq -r '.token // empty' 2>/dev/null)
  [ -n "$tok" ] || { echo "rl_app_installation_token: token exchange returned no token (check App perms/installation id)" >&2; return 1; }
  printf '%s\n' "$tok"
}

# ---------------------------------------------------------------------------
# App-auth by DEFAULT for gh transport (issue #1149, fix #1 — the biggest
# lever). #862 already mints the wtp-sge App installation token, but only
# rl_post_verdict consumes it; every other gh call in the pipeline still draws
# on the shared human PAT's 5000/hr REST quota. The wtp-sge App installation
# token carries the 15000/hr App-installation tier — 3x headroom before any
# other rate-limit mitigation matters. These two helpers let any call site
# route a gh call through the App token when it is available, falling back
# (loudly, once) to the ambient PAT when it is not — WITHOUT changing the
# review IDENTITY contract: rl_review_identity / rl_post_verdict still decide
# who AUTHORS a review; this only decides which token pays for the API calls.
#
# SECURITY: the token is obtained via rl_app_installation_token (env-only
# credentials, #862) and passed to a single child gh process via GH_TOKEN. It
# is never echoed to stdout, logged, or written to disk here.
#
# rl_app_token_cached -- print a usable App installation token, memoised for
# the life of this shell so a burst of rl_gh calls mints at most one token
# (installation tokens are valid ~1h; a single dispatch is far shorter). Prints
# nothing and returns non-zero when no App credentials are present OR minting
# fails — the caller then falls back to the ambient PAT. The cache holds only a
# SUCCESSFUL token; a failure is not memoised, so a transient mint error does
# not wedge the whole run onto the PAT path.
rl_app_token_cached() {
  if [ -n "${RL_APP_TOKEN_CACHE:-}" ]; then
    printf '%s\n' "${RL_APP_TOKEN_CACHE}"; return 0
  fi
  # Only attempt when App mode is actually configured (avoid a doomed mint +
  # noisy fallback log on every single gh call in a PAT-only environment).
  [ "$(rl_review_identity 2>/dev/null)" = "app" ] || return 1
  local tok
  tok=$(rl_app_installation_token 2>/dev/null) || return 1
  [ -n "$tok" ] || return 1
  RL_APP_TOKEN_CACHE="$tok"
  printf '%s\n' "$tok"
}

# rl_gh <gh-args...> -- run `gh` with the wtp-sge App installation token as
# GH_TOKEN when available (15k/hr App tier), else transparently with the
# ambient auth (PAT/GH_TOKEN already in the environment — 5k/hr). Drop-in for a
# bare `gh` call: `rl_gh api ...`, `rl_gh pr view ...`. The fallback to PAT is
# logged ONCE per shell (RL_APP_TOKEN_PAT_WARNED guard) so a PAT-only run does
# not spam a line per call. Exit status and stdout/stderr are gh's, untouched,
# so existing capture/parse logic at call sites is unaffected.
rl_gh() {
  local tok
  if tok=$(rl_app_token_cached); then
    GH_TOKEN="$tok" gh "$@"
    return $?
  fi
  if [ -z "${RL_APP_TOKEN_PAT_WARNED:-}" ]; then
    echo "rl_gh: no wtp-sge App token available -- using ambient PAT auth (5000/hr REST tier). Set SGE_REVIEW_APP_* to get the 15000/hr App tier (issue #1149)." >&2
    RL_APP_TOKEN_PAT_WARNED=1
  fi
  gh "$@"
}

# rl_verdict_body_pr <body> -- print the PR number the verdict body declares in
# its machine-readable `sge-verdict` block (`pr: <number>` line, SKILL.md Phase
# 5), or nothing if the body carries no such marker (issue #1667). Reads the
# FIRST `pr:` line only — the verdict block is authoritative and appears once.
# Tolerant of leading whitespace and `pr:`/`pr :` spacing; extracts digits only.
rl_verdict_body_pr() {
  local body="${1:-}"
  printf '%s\n' "$body" \
    | grep -ioE '^[[:space:]]*pr[[:space:]]*:[[:space:]]*#?[0-9]+' \
    | head -n1 \
    | grep -oE '[0-9]+' || true
}

# rl_verdict_pr_mismatch <pr> <body> -- exit 0 (TRUE, "mismatch") when the body
# declares a `pr:` marker that is a DIFFERENT PR from <pr>; exit 1 (FALSE) when
# it matches OR when the body carries no marker at all (issue #1667). Fails
# CLOSED only on a positive mismatch — a marker-less body (advisory one-liner,
# ad-hoc comment) is never blocked, so the guard cannot wedge legitimate posts.
rl_verdict_pr_mismatch() {
  local pr="${1:?rl_verdict_pr_mismatch: pr required}" body="${2:-}" body_pr
  body_pr=$(rl_verdict_body_pr "$body")
  [ -n "$body_pr" ] || return 1        # no marker → not a mismatch
  [ "$body_pr" = "$pr" ] && return 1   # marker matches → not a mismatch
  return 0                             # marker names a different PR → mismatch
}

# rl__verdict_block <body> -- print the content of the FIRST fenced
# sge-verdict block in <body>, nothing when no such fence exists. Field
# parsers below scope to this block so a matching-shaped line elsewhere in the
# body (quoted issue text, an earlier example) can never spoof a parsed value.
# The opener matches the FULL CommonMark fence family -- three-or-more
# backticks OR tildes (```sge-verdict, ````sge-verdict, ~~~sge-verdict) --
# case-insensitively and tolerating a trailing info string, so no valid
# GitHub-rendered fence variant can silently opt the guard out (the PR #1924
# review found tilde/long fences failed the guard OPEN). The closer must use
# the SAME delimiter character with at least the opener's run length (the
# CommonMark closing rule), so a stray ``` line inside a ~~~ block stays
# content. NOTE: first-fence extraction alone is spoofable by a DECOY fence
# placed before the real one -- rl_verdict_findings_unverified therefore fails
# closed on any multi-fence body (see rl__verdict_fence_count).
# The body is UNTRUSTED DATA -- extracted lines only, never eval'd.
rl__verdict_block() {
  printf '%s\n' "${1:-}" | awk '
    { sub(/\r$/, "") }
    !inb {
      if (tolower($0) ~ /^[[:space:]]*(```+|~~~+)sge-verdict([[:space:]].*)?$/) {
        line = $0; sub(/^[[:space:]]*/, "", line)
        dc = substr(line, 1, 1); dl = 0
        while (substr(line, dl + 1, 1) == dc) dl++
        inb = 1
      }
      next
    }
    {
      line = $0; sub(/^[[:space:]]*/, "", line)
      rl = 0
      while (substr(line, rl + 1, 1) == dc) rl++
      if (rl >= dl && rl >= 3 && substr(line, rl + 1) ~ /^[[:space:]]*$/) exit
      print
    }
  '
}

# rl__verdict_fence_count <body> -- print the number of sge-verdict fence
# openers in <body> across the WHOLE fence family (```+ or ~~~+ openers,
# case-insensitive, info-string tolerant). >1 means the body is ambiguous: a
# decoy fence with clean counts placed before the real verdict -- including a
# MIXED-delimiter decoy (a ~~~ decoy before a ``` real fence) -- would control
# the first-fence parse, so the findings guard treats any multi-fence body as
# unverifiable (fail closed).
rl__verdict_fence_count() {
  printf '%s\n' "${1:-}" | awk '
    { sub(/\r$/, "") }
    tolower($0) ~ /^[[:space:]]*(```+|~~~+)sge-verdict([[:space:]].*)?$/ { n++ }
    END { print n + 0 }
  '
}

# rl_verdict_findings_total <body> -- print blockers+majors+minors summed from
# the body's sge-verdict block, or nothing when the block carries no complete
# count triple (marker-less/advisory/legacy bodies). Digits-only extraction of
# the FIRST occurrence of each field inside the fence; counts are forced
# decimal (10#) so a zero-padded `blockers: 08` can neither error the
# arithmetic (emptying the total and failing the guard OPEN) nor miscount as
# octal.
rl_verdict_findings_total() {
  local body="${1:-}" block b m n
  block=$(rl__verdict_block "$body")
  [ -n "$block" ] || return 0
  b=$(printf '%s\n' "$block" | grep -ioE '^[[:space:]]*blockers[[:space:]]*:[[:space:]]*[0-9]+' | head -n1 | grep -oE '[0-9]+')
  m=$(printf '%s\n' "$block" | grep -ioE '^[[:space:]]*majors[[:space:]]*:[[:space:]]*[0-9]+'   | head -n1 | grep -oE '[0-9]+')
  n=$(printf '%s\n' "$block" | grep -ioE '^[[:space:]]*minors[[:space:]]*:[[:space:]]*[0-9]+'   | head -n1 | grep -oE '[0-9]+')
  [ -n "$b" ] && [ -n "$m" ] && [ -n "$n" ] || return 0
  printf '%s\n' "$((10#$b + 10#$m + 10#$n))"
}

# rl_verdict_findings_ref <body> -- print the `findings_comment:` value declared
# in the body's sge-verdict block (issue #1858): a comment URL, `inline`, or
# `none`; nothing when the field is absent (legacy bodies) or there is no fence.
rl_verdict_findings_ref() {
  local body="${1:-}"
  rl__verdict_block "$body" \
    | grep -ioE '^[[:space:]]*findings_comment[[:space:]]*:[[:space:]]*[^[:space:]]+' \
    | head -n1 \
    | sed -E 's/^[[:space:]]*[Ff][Ii][Nn][Dd][Ii][Nn][Gg][Ss]_[Cc][Oo][Mm][Mm][Ee][Nn][Tt][[:space:]]*:[[:space:]]*//'
}

# rl_post_findings_comment <pr> [file|-] -- post the findings comment and VERIFY
# it exists before reporting success (issue #1858). The #1849 residual: a
# dispatch that succeeds posts its verdict, but the SEPARATE findings-comment
# POST fails silently -- the daemon's artefact check requires only the
# sge-verdict fence, so the run reads as complete while the actionable findings
# were never delivered. Verification norm: a POST that "ran" is not a comment
# that EXISTS -- so after the POST this reads the comment back by id
# (independent GET) and only then prints the comment URL. FAILS CLOSED (non-zero,
# no output) on POST failure, a response with no numeric id, read-back failure,
# an empty read-back body, or an empty input body. The caller (SKILL.md Phase 6)
# must react to a failure by folding the findings INTO the verdict body
# (`findings_comment: inline`) -- never by posting the verdict as if the
# findings had landed.
rl_post_findings_comment() {
  local pr="${1:?rl_post_findings_comment: pr required}" src="${2:--}" repo body resp cid readback url
  repo=$(rl__repo) || return 1
  if [ "$src" = "-" ]; then
    body=$(cat)
  else
    body=$(cat "$src" 2>/dev/null) || return 1
  fi
  [ -n "${body//[$' \t\r\n']/}" ] || return 1
  resp=$(rl_gh api --method POST "repos/${repo}/issues/${pr}/comments" -f body="$body" 2>/dev/null) || return 1
  cid=$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null)
  [[ "$cid" =~ ^[0-9]+$ ]] || return 1
  readback=$(rl_gh api "repos/${repo}/issues/comments/${cid}" --jq '.body // empty' 2>/dev/null) || return 1
  [ -n "${readback//[$' \t\r\n']/}" ] || return 1
  url=$(printf '%s' "$resp" | jq -r '.html_url // empty' 2>/dev/null)
  # Fallback must stay URL-shaped: its only consumer is the anchored-URL check
  # in rl_verdict_findings_unverified, which a bare "issuecomment-<id>" string
  # would always fail (PR #1924 review finding).
  [ -n "$url" ] || url="https://github.com/${repo}/pull/${pr}#issuecomment-${cid}"
  printf '%s\n' "$url"
}

# rl_verdict_findings_unverified <pr> <body> -- exit 0 (TRUE, "block the post")
# when the body's sge-verdict block declares findings (blockers+majors+minors
# > 0) whose delivery cannot be proven: findings_comment absent, `none`, or a
# URL that is not this repo+PR's own verified findings comment (issue #1858).
# Exit 1 (FALSE, safe to post) when the verdict is clean (total 0), declares
# `findings_comment: inline` (self-contained body), declares a URL that
# read-back-verifies AGAINST THIS PR, or carries no count triple at all
# (marker-less/advisory/legacy bodies -- like the #1667 guard, this blocks
# only on a positive signal so it can never wedge a legitimate non-verdict
# post). Two deliberate fail-closed hardenings:
#   * multi-fence bodies block outright -- a decoy ```sge-verdict fence with
#     clean counts placed before the real one would otherwise control the
#     first-fence parse and fail the guard OPEN;
#   * the URL must be anchored to https://github.com/<repo>/pull/<pr> AND its
#     comment's issue_url must read back as this PR -- existence of SOME
#     readable comment anywhere is not delivery of THESE findings.
rl_verdict_findings_unverified() {
  local pr="${1:?rl_verdict_findings_unverified: pr required}" body="${2:-}" fcount total ref refnorm cid repo rjson rbody iurl
  fcount=$(rl__verdict_fence_count "$body")
  [ "$fcount" -gt 1 ] && return 0      # decoy-fence ambiguity -> block
  if [ "$fcount" -eq 0 ]; then
    # Substring backstop (PR #1924 review): the downstream artefact check
    # (check-review-independence.sh) accepts a verdict on a bare
    # contains("sge-verdict") substring test. A body the consumer would read
    # as a verdict but this guard cannot parse into a fence (a blockquoted
    # fence, a future delimiter variant) must fail CLOSED, not fall through
    # the "not a verdict body" path. Truly marker-less bodies still pass.
    case "$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')" in
      *sge-verdict*) return 0 ;;       # consumer-visible marker, unparseable fence -> block
      *) return 1 ;;                   # marker-less body -> not a verdict
    esac
  fi
  total=$(rl_verdict_findings_total "$body")
  [ -n "$total" ] || return 1          # fenced but no count triple -> legacy verdict body
  [ "$total" -gt 0 ] || return 1       # clean verdict -> nothing to deliver
  ref=$(rl_verdict_findings_ref "$body")
  # Normalise the VALUE for the literal comparisons (the field NAME already
  # matches case-insensitively): `INLINE`/`None` must behave like their
  # lowercase forms, not fall through to the URL branch.
  refnorm=$(printf '%s' "$ref" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  [ "$refnorm" = "inline" ] && return 1  # findings are in the verdict body itself
  case "$refnorm" in
    ""|none) return 0 ;;               # findings declared but no delivery route
  esac
  # A URL reference: it must name THIS repo and THIS PR (anchored -- scheme,
  # host, owner, repo, PR number all fixed), carry an `issuecomment-<id>`
  # fragment (bare trailing digits would let a plain PR URL misparse the PR
  # number as a comment id), and the comment must read back non-empty WITH an
  # issue_url binding it to this PR. Fail closed on every mismatch or error.
  repo=$(rl__repo) || return 0
  [ -n "$repo" ] || return 0           # rl__repo can emit empty on exit 0 -- still fail closed
  case "$ref" in
    "https://github.com/${repo}/pull/${pr}#issuecomment-"*) : ;;
    *) return 0 ;;                     # foreign host/repo/PR or malformed -> block
  esac
  cid=$(printf '%s' "$ref" | grep -oE '#issuecomment-[0-9]+$' | grep -oE '[0-9]+')
  [ -n "$cid" ] || return 0
  rjson=$(rl_gh api "repos/${repo}/issues/comments/${cid}" 2>/dev/null) || return 0
  rbody=$(printf '%s' "$rjson" | jq -r '.body // empty' 2>/dev/null)
  [ -n "${rbody//[$' \t\r\n']/}" ] || return 0
  iurl=$(printf '%s' "$rjson" | jq -r '.issue_url // empty' 2>/dev/null)
  case "$iurl" in
    "https://api.github.com/repos/${repo}/issues/${pr}") : ;;
    *) return 0 ;;                     # comment exists but belongs to another issue/PR -> block
  esac
  return 1
}

# rl_post_verdict <pr> <event> [body] -- post the review verdict.
#   event: APPROVE | REQUEST_CHANGES | COMMENT
#   body:  positional arg, or read from stdin when omitted.
# App mode (rl_review_identity == app): posts a REAL review authored by the
# wtp-sge App via POST repos/{repo}/pulls/{pr}/reviews using the installation
# token (GH_TOKEN). On any App-side failure it falls back -- logged -- to the PAT
# path. PAT mode: `gh pr review`, retrying as --comment (with the recommendation
# stated in-body) when GitHub rejects --approve/--request-changes on a
# self-authored PR (the existing behaviour). Returns non-zero if the verdict
# could not be posted by any route.
rl_post_verdict() {
  local pr="${1:?rl_post_verdict: pr required}" event="${2:?rl_post_verdict: event required}" body="${3:-}"
  case "$event" in
    APPROVE|REQUEST_CHANGES|COMMENT) ;;
    *) echo "rl_post_verdict: event must be APPROVE|REQUEST_CHANGES|COMMENT, got '$event'" >&2; return 2 ;;
  esac
  local repo mode flag tok
  repo=$(rl__repo) || return 1
  [ -n "$body" ] || body="$(cat)"
  # Pre-post draft-vs-PR guard (issue #1667). The load-bearing fix: BEFORE any
  # network write, prove the body being posted belongs to THIS PR, so a stale or
  # foreign draft (e.g. a concurrent lane's `review.md` that overwrote ours)
  # can NEVER be posted onto the wrong PR. The verdict block already carries a
  # `pr: <number>` line (SKILL.md Phase 5); a body that names a DIFFERENT PR is
  # a collision and we refuse loudly rather than post the wrong verdict. A body
  # with no `pr:` marker at all is passed through (advisory one-liners, ad-hoc
  # comments) — the guard fails CLOSED only on a positive mismatch, never on
  # absence, so it cannot wedge a legitimate marker-less comment.
  if rl_verdict_pr_mismatch "$pr" "$body"; then
    echo "rl_post_verdict: REFUSING to post — the draft body names PR #$(rl_verdict_body_pr "$body") but the target is PR #${pr} (issue #1667: stale/foreign draft collision). Re-draft against PR #${pr} and retry." >&2
    return 5
  fi
  # Findings-delivery guard (issue #1858). A verdict that DECLARES findings must
  # prove they are reachable: `findings_comment: inline` (self-contained body)
  # or a URL whose comment read-back-verifies. Otherwise the verdict is refused
  # BEFORE any network write — the #1849 residual was a successful dispatch
  # whose findings-comment POST failed silently, leaving a fenced verdict the
  # daemon accepts with no findings anywhere.
  if rl_verdict_findings_unverified "$pr" "$body"; then
    echo "rl_post_verdict: REFUSING to post — the verdict declares $(rl_verdict_findings_total "$body") finding(s) but findings_comment is '$(rl_verdict_findings_ref "$body")' and no verified findings comment exists (issue #1858). Post the findings via rl_post_findings_comment first, or fold them into the verdict body and set 'findings_comment: inline'." >&2
    return 6
  fi
  mode=$(rl_review_identity)
  if [ "$mode" = "app" ]; then
    if tok=$(rl_app_installation_token); then
      if GH_TOKEN="$tok" gh api --method POST "repos/${repo}/pulls/${pr}/reviews" \
           -f "event=${event}" -f "body=${body}" >/dev/null 2>&1; then
        echo "rl_post_verdict: posted ${event} review on PR #${pr} as the wtp-sge App -- real approval, builder != reviewer (issue #862)" >&2
        return 0
      fi
      echo "rl_post_verdict: App-authored review POST failed -- falling back to PAT identity (issue #862)" >&2
    else
      echo "rl_post_verdict: could not obtain an App installation token -- falling back to PAT identity (issue #862)" >&2
    fi
  fi
  # PAT / bot fallback -- the current behaviour (self-approval blocked).
  case "$event" in
    APPROVE)         flag="--approve" ;;
    REQUEST_CHANGES) flag="--request-changes" ;;
    COMMENT)         flag="--comment" ;;
  esac
  if gh pr review "$pr" --repo "$repo" "$flag" --body "$body" >/dev/null 2>&1; then
    echo "rl_post_verdict: posted ${event} review on PR #${pr} via PAT/bot identity" >&2
    return 0
  fi
  if [ "$event" != "COMMENT" ]; then
    echo "rl_post_verdict: ${flag} rejected (self-authored PR?) -- posting as --comment with the recommendation stated in-body" >&2
    gh pr review "$pr" --repo "$repo" --comment --body "Recommendation: ${event}"$'\n\n'"${body}"
    return $?
  fi
  echo "rl_post_verdict: could not post the verdict on PR #${pr} by any route" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Rate-limit detection + fail-loud stall reporting (issue #1147).
#
# INCIDENT: a /sge:pr-review dispatch against PR #1144 ran 3+ hours and burned
# 268k tokens because it silently wedged retrying rate-limited `gh` (REST)
# calls — `gh api rate_limit` independently confirmed `remaining: 0` during the
# same window — instead of failing loudly or switching to GraphQL, which had a
# SEPARATE, non-exhausted quota bucket at the time (4365/5000 remaining). This
# skill's own doctrine elsewhere is fail-loud (the thread gate, the required-
# checks gate, the follow-up gate all refuse loudly on ambiguity, never retry
# silently into an unbounded loop) — a rate-limited retry loop tripped none of
# those gates because nothing recognised the condition in the first place.
#
# These helpers are ADDITIVE: they give call sites a mechanical way to detect
# exhaustion and fail loud, and a GraphQL-first alternative for state reads
# that would otherwise draw on the same REST bucket. They do not touch or
# weaken any existing fail-closed gate (thread resolution, required-checks,
# follow-up preservation, claim-check) in this file or in pr-labels.sh.

# rl_is_rate_limit_error <text> — print 1|0. Pure string match (case-
# insensitive) against the canonical GitHub rate-limit signatures: a 403 body
# containing "rate limit" (primary or secondary), "API rate limit exceeded",
# or an HTTP 429. No network call — safe to run on any already-captured
# stderr/stdout blob from a failed `gh` invocation.
rl_is_rate_limit_error() {
  local text="${1:-}"
  if printf '%s' "$text" | grep -qiE '(^|[^0-9])403([^0-9]|$).*rate limit|rate limit.*(^|[^0-9])403([^0-9]|$)|api rate limit exceeded|secondary rate limit|(^|[^0-9])429([^0-9]|$)'; then
    echo 1
  else
    echo 0
  fi
}

# rl_rate_limit_status — print "<remaining> <limit> <reset_epoch>" for the
# REST core quota, read via the GraphQL `rateLimit` field (cost 0-1 points —
# this check does not meaningfully spend the budget it is checking). This is
# the SAME bucket every `gh api`/`gh pr view`/`gh pr diff`/`gh pr checks` REST
# call in this file draws from — GraphQL queries (the thread-resolution walk,
# and the *_gql helpers below) draw from a SEPARATE bucket and are unaffected.
# Non-zero exit + no output on any fetch/parse failure.
rl_rate_limit_status() {
  local raw remaining limit reset
  raw=$(gh api graphql -f query='query { rateLimit { remaining limit resetAt } }' \
    --jq '"\(.data.rateLimit.remaining) \(.data.rateLimit.limit) \(.data.rateLimit.resetAt)"' 2>/dev/null) || return 1
  remaining=$(printf '%s' "$raw" | awk '{print $1}')
  limit=$(printf '%s' "$raw" | awk '{print $2}')
  reset=$(printf '%s' "$raw" | awk '{print $3}')
  [[ "$remaining" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ && -n "$reset" ]] || return 1
  local reset_epoch
  reset_epoch=$(date -u -d "$reset" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$reset" +%s 2>/dev/null) || reset_epoch=""
  printf '%s %s %s\n' "$remaining" "$limit" "${reset_epoch:-0}"
}

# rl_rate_limit_exhausted [floor] — print 1|0. remaining <= floor (default 50,
# override via SGE_REVIEW_RATE_LIMIT_FLOOR)? FAILS CLOSED TO 0 (assume not
# exhausted) when rl_rate_limit_status itself can't be read — this helper
# feeds a LOUD-FAILURE decision, so it must never fabricate a positive signal
# from an absence of data; an unreadable quota is a separate, unrelated
# problem the caller's normal error handling already covers.
rl_rate_limit_exhausted() {
  local floor="${1:-${SGE_REVIEW_RATE_LIMIT_FLOOR:-50}}" status remaining
  status=$(rl_rate_limit_status) || { echo 0; return 0; }
  remaining=$(printf '%s' "$status" | awk '{print $1}')
  [[ "$remaining" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
  if [ "$remaining" -le "$floor" ]; then echo 1; else echo 0; fi
}

# rl_fail_loud_rate_limited <pr> <context> — THE #1147 fix. Call at the top of
# any retry loop wrapping a `gh` REST call (or right after one fails),
# <context> being that command's captured stderr/output ("-" or omitted reads
# stdin instead). Detects EITHER signal independently:
#   1. <context> itself carries a rate-limit signature (rl_is_rate_limit_error)
#   2. the live REST quota is exhausted (rl_rate_limit_exhausted) — this catches
#      the case where the NEXT call would 403 even though the one that just
#      failed didn't (e.g. it failed for an unrelated reason moments before
#      quota actually hit zero)
# On EITHER firing: posts a PR comment (best-effort, via rl_post_verdict's
# GraphQL-first identity path is not required here — a plain issue comment
# suffices and costs one write, not a review) stating the stall reason and the
# quota snapshot, then returns 1 so the CALLER exits non-zero instead of
# retrying silently. The whole point is FAIL LOUD, NOT RETRY — this function
# never loops, sleeps, or retries itself.
# Returns 0 (no rate-limit condition detected) when neither signal fires.
rl_fail_loud_rate_limited() {
  local pr="${1:?rl_fail_loud_rate_limited: pr required}" ctx_src="${2:--}" ctx repo status hit=0 reason=""
  if [ "$ctx_src" = "-" ]; then
    ctx=$(cat 2>/dev/null)
  else
    ctx="$ctx_src"
  fi
  if [ "$(rl_is_rate_limit_error "$ctx")" = "1" ]; then
    hit=1
    reason="a gh call returned a rate-limit response (403/429 rate-limit signature)"
  fi
  status=$(rl_rate_limit_status 2>/dev/null) || status=""
  if [ "$(rl_rate_limit_exhausted)" = "1" ]; then
    hit=1
    if [ -n "$reason" ]; then
      reason="$reason; REST quota is also exhausted (${status:-unknown})"
    else
      reason="REST rate-limit quota is exhausted (${status:-unknown} remaining/limit/reset-epoch)"
    fi
  fi
  [ "$hit" -eq 1 ] || { echo 0; return 0; }

  echo "rl_fail_loud_rate_limited: PR #${pr} — STALLING ON RATE LIMIT: ${reason}. Failing loud instead of retrying silently (issue #1147)." >&2
  repo=$(rl__repo 2>/dev/null) || repo=""
  local msg
  msg=$(printf 'pr-review stopped: GitHub rate-limit exhaustion detected (%s).\n\nQuota snapshot (remaining limit reset_epoch): `%s`\n\nThis run is failing loud instead of silently retrying/wedging (issue #1147). Re-run once the quota window resets. (GraphQL draws from a separate bucket — `rl_pr_state_gql` / `rl_checks_status_gql` exist as contract-compatible prep helpers but are not yet wired into dispatch.)' \
    "$reason" "${status:-unknown}")
  if [ -n "$repo" ]; then
    gh api "repos/$repo/issues/$pr/comments" -f body="$msg" >/dev/null 2>&1 \
      || echo "rl_fail_loud_rate_limited: could not post the stall-reason PR comment (best-effort only — the loud stderr message above is the primary signal)" >&2
  fi
  echo 1
  return 1
}

# ---------------------------------------------------------------------------
# GraphQL state-read helpers (issue #1147) — PREP WORK, not yet wired.
#
# Most reads in this file (rl_head_sha, rl_pr_state, rl_changes_requested,
# rl_failing_checks, label reads in pr-labels.sh) go through REST, which
# shares ONE 5000/hr quota across every automation in the org — this session,
# other agents, CI itself. GraphQL has a SEPARATE bucket. These are GraphQL
# equivalents for two of the read shapes called out in #1147 (PR state reads,
# check-run status), kept to the SAME output contracts as their REST
# counterparts (rl_pr_state, `gh pr checks --json name,state,bucket`) so
# future callers can swap them in without reshaping downstream parsing.
# STATUS: no production call site consumes these yet — the only #1147 GraphQL
# path that is live today is pr-labels.sh label_status's inline fallback
# (deliberately inline there, NOT shared from here: pr-labels.sh must not
# source review-lib.sh per the #883 ledger convention documented in that
# file). A previous rl_label_status_gql helper here was removed for exactly
# that reason — it duplicated the live inline fallback with no possible
# caller. Behaviour is pinned by skills/tests/review-lib-rate-limit.test.sh.

# rl_pr_state_gql <pr> — GraphQL equivalent of rl_pr_state. Same one-line JSON
# shape: {state, draft, head, labels}.
rl_pr_state_gql() {
  local pr="${1:?rl_pr_state_gql: pr required}" repo
  repo=$(rl__repo) || return 1
  gh api graphql -f query='
    query($owner:String!,$repo:String!,$pr:Int!){
      repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
        state
        isDraft
        headRefOid
        labels(first:20){ nodes{ name } } } } }' \
    -f owner="${repo%/*}" -f repo="${repo#*/}" -F pr="$pr" \
    --jq '.data.repository.pullRequest | {state: (.state|ascii_downcase), draft: .isDraft, head: .headRefOid, labels: [.labels.nodes[].name]}'
}

# rl_checks_status_gql <pr> — GraphQL equivalent of `gh pr checks`: JSON array
# of {name,state,bucket,isRequired} for the head commit's combined status-check
# rollup (statusCheckRollup). `isRequired` mirrors `gh pr checks --required`'s
# filter input so a future caller can narrow to genuinely-required checks.
# `bucket` mirrors gh's own pass/fail/pending/skipping
# buckets so the required-check guard (assert_required_checks_green) — which
# treats ANY bucket other than "pass"/"skipping" as blocking — can consume it
# unchanged. CRITICAL (fail-safe): only genuinely-neutral/skipped terminal
# conclusions map to "skipping"; every other non-success terminal state
# (CANCELLED, ACTION_REQUIRED, STARTUP_FAILURE, STALE, TIMED_OUT, FAILURE)
# maps to "fail" so a cancelled/errored required check can never be mistaken
# for a clean one and arm auto-merge (issue #1147).
rl_checks_status_gql() {
  local pr="${1:?rl_checks_status_gql: pr required}" repo
  repo=$(rl__repo) || return 1
  gh api graphql -f query='
    query($owner:String!,$repo:String!,$pr:Int!){
      repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
        commits(last:1){ nodes{ commit{ statusCheckRollup{ contexts(first:100){
          nodes{
            __typename
            ... on CheckRun { name conclusion status isRequired(pullRequestNumber:$pr) }
            ... on StatusContext { context state isRequired(pullRequestNumber:$pr) }
          } } } } } } } } }' \
    -f owner="${repo%/*}" -f repo="${repo#*/}" -F pr="$pr" \
    --jq '[.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[] |
      if .__typename == "CheckRun" then
        { name: .name,
          state: (.conclusion // .status // "PENDING" | ascii_upcase),
          bucket: ((.conclusion // "" | ascii_upcase) as $c |
                   if $c == "SUCCESS" then "pass"
                   elif $c == "" then "pending"
                   elif $c == "NEUTRAL" or $c == "SKIPPED" then "skipping"
                   else "fail" end),
          isRequired: (.isRequired // false) }
      else
        { name: .context,
          state: (.state | ascii_upcase),
          bucket: ((.state | ascii_upcase) as $s |
                   if $s == "SUCCESS" then "pass"
                   elif $s == "PENDING" or $s == "EXPECTED" then "pending"
                   else "fail" end),
          isRequired: (.isRequired // false) }
      end]'
}
