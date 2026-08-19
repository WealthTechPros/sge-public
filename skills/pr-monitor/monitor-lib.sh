#!/usr/bin/env bash
# monitor-lib.sh â€” the mechanical (bash) half of /sge:pr-monitor.
#
# Bundled, SOURCED library (pr-labels.sh pattern â€” scripts cost zero context):
# every embedded function body that used to be restated inline in
# skills/pr-monitor/SKILL.md lives here instead, and the skill sources this
# file at startup:
#
#   source "${CLAUDE_PLUGIN_ROOT}/skills/pr-monitor/monitor-lib.sh"
#
# The SKILL.md keeps the *judgement* (when to call what, priority order,
# escalation rules); this file keeps the *mechanics*. Behaviour-preserving
# extraction of issue #819 â€” the function bodies are verbatim from the skill.
#
# Functions (in dependency order):
#   is_spec_pr <pr>              0 iff every changed file matches $SPEC_GLOB_RE
#                                (caller MUST set SPEC_GLOB_RE from the repo's
#                                CLAUDE.md spec globs before calling)
#   fetch_candidate_prs          oldest-first open, unclaimed PR numbers
#                                (drafts only via the #755 orphan carve-out)
#   fetch_claimed_prs            oldest-first open PR numbers holding a claim
#                                label â€” the pool the stale-claim takeover
#                                re-examines
#   claim_labeled_epoch <pr>     epoch seconds of the MOST RECENT claim-label
#                                `labeled` timeline event â€” when the current
#                                claim was taken (issue #1252); empty = unknown
#   is_stale_claim <pr>          0 iff a claim is STALE: it was TAKEN more than
#                                $STALE_CLAIM_MINUTES ago per claim_labeled_epoch
#                                (issue #396, timeline-based since #1252)
#   reclaim_if_stale <pr>        on a stale claim: log loudly, swap
#                                pr-reviewing to this session via pr-labels.sh
#                                start-review, return 0 (enter the lane);
#                                fresh claim -> return 1 (strict mutex)
#   pr_ready_for_merge <pr>      echoes READY / GATE_FAIL:<reason> for the
#                                three merge gates (linked, reviewed, CI green)
#   named_failing_checks <pr>    prints the NAMES of failing required checks,
#                                one per line (see $FAILING_CHECK_JQ for the
#                                terminal-red state set) â€” so a stall can be
#                                surfaced by check name, not just count
#   held_review_stall <pr>       0 iff a PR holds a FRESH pr-reviewing claim
#                                (is_stale_claim says fresh) AND has >=1 failing
#                                required check â€” a live review lane stuck on a
#                                fixable red check (issue #1148); distinct from
#                                the dead-session stale-claim takeover above
#   post_stall_comment <pr>      idempotently post a status comment naming the
#                                failing checks so a held pr-reviewing PR isn't
#                                a silent stall (issue #1148); skips if already
#                                posted for the current head
#   is_stale_draft <pr>          0 iff a PR is an ABANDONED draft (issue #1248):
#                                draft, label-less, head commit older than
#                                $STALE_DRAFT_MINUTES, AND no check in flight
#   stale_draft_lane <pr>        act on an abandoned draft (never silently):
#                                CI green -> gh pr ready + log + audit comment;
#                                CI red -> idempotent abandonment comment naming
#                                the failing check(s); never readies a red draft
#   is_infra_failure <run_id>    0 iff the failed run looks infra-shaped
#                                (<30s with no real work) â€” rerun, don't fix
#   is_setup_step_html_error <run_id>
#                                0 iff any setup step in the run emitted
#                                `<!DOCTYPE html>` in its log â€” second outage
#                                signal for GITHUB DEGRADED classification
#                                (GitHub API degradation returns HTML instead
#                                of JSON, poisoning setup steps before any real
#                                work runs)
#   post_github_degraded_comment <pr>
#                                idempotently park a PR blocked by a GitHub
#                                degradation event with ONE `github-degraded`
#                                comment (issue #1434). Idempotent per head SHA
#                                AND per indicator; fail-safe (unreachable status
#                                -> "error" -> still parks; never fail-open)
#   check_systemic_failure [N]   0 iff >=67% of the oldest-N eligible PRs are
#                                failing (one bug wearing many hats)
#   is_blast_radius_pr <pr>      0 iff the PR matches a global-blast-radius
#                                carve-out; echoes a one-word reason
#                                (SKILL.md Appendix A is the canonical
#                                condition list)
#
# Environment (all optional unless noted):
#   SPEC_GLOB_RE          REQUIRED by is_spec_pr / check_systemic_failure â€”
#                         alternation built from the repo CLAUDE.md spec globs
#   CLAIM_LABELS_RE       in-flight claim labels (default: pr-reviewing|pr-fixing)
#   DRAFT_ORPHAN_MINUTES  draft orphan carve-out quiet window (default: 30)
#   STALE_DRAFT_MINUTES   abandoned-draft window for the stale-draft lane, in
#                         minutes (default: 45) â€” is_stale_draft / stale_draft_lane
#   STALE_CLAIM_MINUTES   claim lease length in minutes (default: 30)
#   MERGE_GATE_LABEL      repo merge-gate label (default: pr-reviewed)
#   CLAUDE_PLUGIN_ROOT    plugin root â€” reclaim_if_stale shells out to
#                         skills/pr-review/pr-labels.sh under it
#
# This file is sourced, so it deliberately sets no shell options
# (`set -euo pipefail` here would clobber the caller's shell).
# Run `bash -n` and skills/tests/pr-monitor-stale-claim-takeover.test.sh
# after any change.

# CLAIM_LABELS_RE: alternation of in-flight claim labels â€” "pr-reviewing" (the
# review mutex, #699) and "pr-fixing" (the fix-in-flight mutex owned by
# /sge:pr-fix, #1174), plus any further claim label named in the repo's CLAUDE.md.
# Both defaults are honoured so a lane skips a PR another session is reviewing OR
# fixing â€” without pr-fixing here, two monitors would each dispatch a fix agent
# onto the same red PR (issue #1174).
CLAIM_LABELS_RE="${CLAIM_LABELS_RE:-pr-reviewing|pr-fixing}"

# DRAFT_ORPHAN_MINUTES: how long a label-less draft must be quiet (no `updatedAt`
# activity) before the orphan carve-out (issue #755) makes it eligible for a first
# /sge:pr-review pass. A draft the author is actively pushing to stays excluded.
DRAFT_ORPHAN_MINUTES="${DRAFT_ORPHAN_MINUTES:-30}"

# A claim is a LEASE. Default 30 min â€” long enough that a live review (which
# pushes commits / posts comments) keeps resetting it, short enough that a dead
# session frees the lane within one coffee break.
STALE_CLAIM_MINUTES="${STALE_CLAIM_MINUTES:-30}"

# STALE_DRAFT_MINUTES: how old a draft's LAST COMMIT must be â€” with no CI in
# flight â€” before the stale-draft lane (issue #1248) presumes the implementer
# that opened it died mid-run and the draft is abandoned. Longer than
# DRAFT_ORPHAN_MINUTES on purpose: this lane takes a terminal action
# (`gh pr ready`, or an abandonment comment), so it waits out the whole window an
# implementer plausibly needs to finish and mark ready itself. A draft with a
# newer commit â€” or any queued/running check â€” is presumed still alive.
STALE_DRAFT_MINUTES="${STALE_DRAFT_MINUTES:-45}"

# Resolved at startup from the repo's CLAUDE.md if it names one differently.
MERGE_GATE_LABEL="${MERGE_GATE_LABEL:-pr-reviewed}"

# The known-flake registry (issue #1571). See .sge/known-flakes.yaml's own header
# for the full contract and the load-bearing invariant: this registry NEVER
# authorises merging over a red required check â€” it only lets a failing check be
# CLASSIFIED (reporting-only) or targeted for a rerun. An unregistered OR expired
# failing check is ALWAYS HOLD. KNOWN_FLAKES_REPO scopes matches to this repo when
# an entry names one; leave it unset (or an entry's repo empty) to match any repo.
KNOWN_FLAKES_FILE="${KNOWN_FLAKES_FILE:-.sge/known-flakes.yaml}"

# A PR is spec-only if EVERY changed file matches the repo's spec globs.
is_spec_pr() {
  local pr=$1
  local non_spec
  # SPEC_GLOB_RE: alternation built from the globs found in the repo's CLAUDE.md
  non_spec=$(gh pr diff "$pr" --name-only 2>/dev/null \
    | grep -vE "$SPEC_GLOB_RE" | grep -v '^$' | wc -l)
  [[ "$non_spec" -eq 0 ]]
}

fetch_candidate_prs() {
  gh pr list --state open --json number,createdAt,updatedAt,isDraft,labels \
    --jq --arg claim "$CLAIM_LABELS_RE" --arg reviewed 'pr-reviewing|pr-reviewed' \
         --argjson mins "$DRAFT_ORPHAN_MINUTES" '
      sort_by(.createdAt)
      | .[]
      # Draft carve-out (issue #755): a non-draft is always in scope; a draft is
      # only in scope if it has NEITHER pr-reviewing NOR pr-reviewed AND has been
      # quiet (no updatedAt activity) for at least $mins minutes.
      | select(
          (.isDraft | not)
          or (
            ([.labels[].name] | any(test($reviewed)) | not)
            and ((now - (.updatedAt | fromdateiso8601)) >= ($mins * 60))
          )
        )
      | select([.labels[].name] | any(test($claim)) | not)
      | .number'
}

# Companion query: open PRs that ARE currently claimed â€” the pool the stale-claim
# takeover re-examines (the inverse of the skip above). No draft filter here: a
# draft only ever reaches "claimed" by first passing the orphan carve-out above
# (or by being a normal non-draft PR mid-review), so any claimed PR â€” draft or
# not â€” is fair game for reclaim_if_stale's own freshness check.
fetch_claimed_prs() {
  gh pr list --state open --json number,createdAt,isDraft,labels \
    --jq --arg claim "$CLAIM_LABELS_RE" 'sort_by(.createdAt)
          | .[] | select([.labels[].name] | any(test($claim)))
          | .number'
}

# Epoch seconds of the MOST RECENT claim-label `labeled` event on a PR â€” i.e.
# when the current claim was actually taken (issue #1252). Reads the GitHub
# issue timeline (server-side, so it survives pod restarts) and takes the LAST
# matching event, not the first: a released-and-re-applied claim on the same
# head emits a NEW `labeled` event, so `tail -n 1` naturally re-arms the clock.
# Prints nothing when no such event exists or the timestamp is unreadable â€” the
# caller MUST treat empty output as "unknown â†’ FRESH" (never reclaim on missing
# data). Mirrors the proven pr-labels.sh start-review timeline read (issue #699).
claim_labeled_epoch() {
  local pr=$1 repo_full claimed_at claimed_epoch
  repo_full="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}"
  [ -n "$repo_full" ] || return 0
  # jq's --arg is unavailable through gh's --jq (filter-string only), so the
  # claim-label alternation is inlined. CLAIM_LABELS_RE is a controlled
  # "pr-reviewing|pr-fixing"-shaped string (no jq metacharacters).
  claimed_at=$(gh api "repos/$repo_full/issues/$pr/timeline" --paginate \
    --jq ".[] | select(.event==\"labeled\" and (.label.name | test(\"^(${CLAIM_LABELS_RE})\$\"))) | .created_at" \
    2>/dev/null | tail -n 1)
  [ -n "$claimed_at" ] && [ "$claimed_at" != "null" ] || return 0
  # GNU date (-d) || BSD/macOS date (-j) â€” gh emits ISO-8601 trailing-Z UTC.
  claimed_epoch=$(date -u -d "$claimed_at" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$claimed_at" +%s 2>/dev/null) || return 0
  printf '%s' "$claimed_epoch"
}

# Returns 0 (stale) when a claimed PR's claim is dead and may be reclaimed.
# STALE iff the claim was TAKEN more than STALE_CLAIM_MINUTES ago, measured from
# the most recent claim-label `labeled` timeline event (issue #1252). This is
# the authoritative signal: it resets the instant the claim is re-applied on the
# same head (a fresh `labeled` event â†’ a fresh clock), and it survives pod
# restarts (the timeline is server-side, not pod-local state). Unknown claim age
# â†’ FRESH â†’ strict mutex (return 1); never reclaim on missing data.
#
# Historical note: this used to proxy claim age via head committedDate +
# updatedAt. That proxy could not distinguish a released-then-re-claimed head
# from a claim that had simply held since the last commit, so a fresh re-claim
# on a quiet head was instantly (mis)read as stale and force-reclaimed while its
# live review ran (issue #1252). The timeline read has no such ambiguity.
is_stale_claim() {
  local pr=$1 cutoff claimed_epoch
  # GNU date (-d) || BSD/macOS date (-v) â€” bound the freshness window.
  cutoff=$(date -u -d "-${STALE_CLAIM_MINUTES} min" +%s 2>/dev/null \
        || date -u -v-"${STALE_CLAIM_MINUTES}"M +%s)
  claimed_epoch=$(claim_labeled_epoch "$pr")
  # No readable claim-labeled event â†’ treat as FRESH (never reclaim on missing
  # data). This also covers a claim applied before the timeline was reachable.
  [ -n "$claimed_epoch" ] || return 1
  # The claim is stale only if it was taken strictly before the cutoff.
  [ "$claimed_epoch" -lt "$cutoff" ]
}

# Re-examine a skipped (claimed) PR before honouring the skip. On a stale claim:
# log loudly, RECLAIM (swap pr-reviewing to THIS session), and ENTER the lane.
reclaim_if_stale() {
  local pr=$1
  if is_stale_claim "$pr"; then
    # LOG IT LOUDLY â€” a dead session's claim is being taken over.
    echo "WARNING: PR #$pr â€” stale pr-reviewing claim (>${STALE_CLAIM_MINUTES}m, no new commit AND no activity); reclaiming for this session" >&2
    # RECLAIM: swap pr-reviewing to this session and ENTER THE LANE rather than
    # skipping forever. start-review re-adds pr-reviewing (now owned by us) and
    # clears any stale pr-reviewed â€” the canonical, mutex-safe way to take over.
    ${CLAUDE_PLUGIN_ROOT}/skills/pr-review/pr-labels.sh start-review "$pr"
    return 0   # eligible â€” enter the lane and review it
  fi
  return 1     # FRESH claim â†’ strict mutex: skip and re-check next cycle
}

# The set of gh-check states that count as a terminal RED required check. Kept as
# one jq boolean expression (bound to `.state`) so the taxonomy is defined once
# and reused by every failing-check query below, rather than drifting per call
# site (issue #1206). Beyond FAILURE/TIMED_OUT this also catches the other
# terminal-failure states gh can report â€” CANCELLED, ACTION_REQUIRED,
# STARTUP_FAILURE, STALE â€” so a held review stuck on any of them is still seen.
FAILING_CHECK_JQ='(.state == "FAILURE" or .state == "TIMED_OUT" or .state == "CANCELLED" or .state == "ACTION_REQUIRED" or .state == "STARTUP_FAILURE" or .state == "STALE")'

# Print the NAMES of failing required checks, one per line. Empty output â†’ no
# failing checks. Used to surface WHICH check is red so a held review lane's
# stall is legible without spelunking the Actions log (issue #1148).
named_failing_checks() {
  local pr=$1
  gh pr checks "$pr" --json name,state \
    --jq ".[] | select($FAILING_CHECK_JQ) | .name" 2>/dev/null
}

# ---- known-flake registry (issue #1571) -----------------------------------
# Emit one row per known_flakes entry, fields joined by the ASCII Unit Separator
# (0x1F / \037) â€” NOT a tab: tab is bash IFS-whitespace, so an empty field (e.g.
# the documented `repo: ""` = any-repo wildcard) would COLLAPSE under `read` and
# shift every later field left, silently mis-dating an entry. \037 never appears
# in a YAML scalar and is not IFS-whitespace, so empty fields survive intact.
#   check \037 repo \037 owner \037 expires \037 policy \037 evidence
# Dependency-free (no yq/python) â€” the same constrained-YAML awk style as the
# .sge/test-map.yml loader. Only lines inside the top-level `known_flakes:` block
# are read; a new top-level key (column-0 `key:`) ends the block. A record starts
# at ANY new `- ` list item (keys may be in any order) and accumulates its keys
# until the next item or the block end; a record with no `check:` is dropped.
known_flakes_rows() { # $1=registry file
  awk '
    function clean(s) {
      sub(/[[:space:]]+#.*$/, "", s)          # strip a REAL trailing comment (space before #)
      gsub(/^[[:space:]]*/, "", s)            # leading space
      gsub(/[[:space:]]+$/, "", s)            # trailing space
      gsub(/^"|"$/, "", s); gsub(/^'"'"'|'"'"'$/, "", s)  # surrounding quotes
      return s
    }
    function flush() {
      if (have && c != "") print c "\037" r "\037" o "\037" e "\037" p "\037" v
    }
    function assign(line) {
      if      (line ~ /^check:/)    { sub(/^check:[[:space:]]*/,    "", line); c = clean(line) }
      else if (line ~ /^repo:/)     { sub(/^repo:[[:space:]]*/,     "", line); r = clean(line) }
      else if (line ~ /^owner:/)    { sub(/^owner:[[:space:]]*/,    "", line); o = clean(line) }
      else if (line ~ /^expires:/)  { sub(/^expires:[[:space:]]*/,  "", line); e = clean(line) }
      else if (line ~ /^policy:/)   { sub(/^policy:[[:space:]]*/,   "", line); p = clean(line) }
      else if (line ~ /^evidence:/) { sub(/^evidence:[[:space:]]*/, "", line); v = clean(line) }
    }
    $0 ~ /^known_flakes:/ { infield = 1; next }
    infield && /^[A-Za-z_]/ { infield = 0 }   # a new col-0 key ends the block
    !infield { next }
    {
      line = $0
      if (line ~ /^[[:space:]]*-[[:space:]]/) {          # a new list item -> new record
        flush(); c = r = o = e = p = v = ""; have = 1
        sub(/^[[:space:]]*-[[:space:]]*/, "", line)      # strip "- " -> leaves "key: value"
      } else {
        sub(/^[[:space:]]+/, "", line)                   # a continuation key -> strip indent
      }
      assign(line)
    }
    END { flush() }
  ' "$1" 2>/dev/null
}

# Classify one failing check NAME against the registry. Prints exactly one of:
#   KNOWN:<policy>   a valid (unexpired), in-scope entry matches â€” reporting-only
#   EXPIRED          a matching entry exists but its expiry has passed
#   UNREGISTERED     no matching entry (the fail-safe HOLD default)
# The invariant: NONE of these authorises merging over the red check. Callers MUST
# HOLD on EXPIRED and UNREGISTERED, and treat KNOWN as reporting/rerun only.
# Matching = exact check name AND (entry repo empty OR, when KNOWN_FLAKES_REPO is
# set, entry repo == KNOWN_FLAKES_REPO). ISO dates sort lexically: an entry is
# valid iff expires >= today (an entry expiring today is still valid that day).
classify_failing_check() { # $1=check name  [$2=today YYYY-MM-DD]  [$3=registry file]
  local name="$1"
  local today="${2:-$(date -u +%Y-%m-%d)}"
  local file="${3:-$KNOWN_FLAKES_FILE}"
  [ -f "$file" ] || { echo "UNREGISTERED"; return 0; }
  local check repo owner expires policy evidence found_expired=""
  # \x1f (Unit Separator) delimiter â€” see known_flakes_rows(): a non-whitespace
  # separator so an empty field (e.g. an any-repo entry's blank repo) is not
  # collapsed by read and cannot shift expires/policy into the wrong column.
  while IFS=$'\x1f' read -r check repo owner expires policy evidence; do
    [ "$check" = "$name" ] || continue
    if [ -n "$repo" ] && [ -n "${KNOWN_FLAKES_REPO:-}" ] && [ "$repo" != "$KNOWN_FLAKES_REPO" ]; then
      continue
    fi
    if [ -z "$expires" ] || [[ "$expires" < "$today" ]]; then
      found_expired=1; continue
    fi
    echo "KNOWN:${policy:-unspecified}"; return 0
  done < <(known_flakes_rows "$file")
  [ -n "$found_expired" ] && { echo "EXPIRED"; return 0; }
  echo "UNREGISTERED"; return 0
}

# Returns 0 (stall) when a PR holds a FRESH pr-reviewing claim AND has >=1 failing
# required check (issue #1148). This is the case the dead-session stale-claim
# takeover deliberately does NOT catch: a LIVE review lane (recent commit or
# activity â†’ is_stale_claim returns 1 â†’ fresh) that saw red CI and, per
# pr-review Phase 7, should have handed off to /sge:pr-fix but did not â€” leaving
# the PR held indefinitely with no visible failure reason. A fresh claim with all
# checks green is a healthy in-flight review â†’ NOT a stall (return 1).
held_review_stall() {
  local pr=$1 claimed failing
  # Must currently carry a claim label â€” else there is no held review to stall.
  claimed=$(gh pr view "$pr" --json labels \
    --jq --arg claim "$CLAIM_LABELS_RE" '[.labels[].name] | any(test($claim))' 2>/dev/null)
  [ "$claimed" = "true" ] || return 1
  # A DEAD claim is the stale-claim takeover's job, not this one â€” only a FRESH
  # (still-live) claim that is stuck on red CI is the issue #1148 stall.
  if is_stale_claim "$pr"; then
    return 1
  fi
  failing=$(gh pr checks "$pr" --json state \
    --jq "[.[] | select($FAILING_CHECK_JQ)] | length" 2>/dev/null)
  # Fail closed on any non-numeric jq/gh output (a transient API error must not
  # throw here or be read as a stall) â€” issue #1206.
  [[ "$failing" =~ ^[0-9]+$ ]] || failing=0
  [ "$failing" -gt 0 ]
}

# Idempotently post a status comment naming the failing checks on a held-review
# PR, so a "pr-reviewing" PR stuck on red CI announces WHY instead of sitting
# silently (issue #1148). Idempotent per head SHA: the marker embeds the head so
# a fresh failure after new commits posts again, but repeated cycles at the same
# head do not spam. No-op when there are no failing checks.
post_stall_comment() {
  local pr=$1 head names marker existing
  names=$(named_failing_checks "$pr")
  [ -n "$names" ] || return 0
  head=$(gh pr view "$pr" --json headRefOid --jq '.headRefOid' 2>/dev/null)
  marker="<!-- sge:held-review-stall ${head} -->"
  # Paginate the marker lookup over ALL comments â€” `gh pr view --json comments`
  # returns only the default (first) page, so on a busy PR the per-head marker
  # could fall off the end and this idempotency check would post a duplicate
  # every cycle. `gh api --paginate` walks every page (issue #1206). The marker
  # is a controlled `<!-- sge:held-review-stall <hex-sha> -->` string (no
  # jq-metacharacters), so it is inlined into the filter â€” gh's --jq takes only
  # a filter string, not jq's --arg.
  existing=$(gh api --paginate "repos/{owner}/{repo}/issues/$pr/comments" \
    --jq "[.[] | select(.body | contains(\"$marker\"))] | length" 2>/dev/null \
    | awk '{s+=$1} END{print s+0}')
  if [ "${existing:-0}" -gt 0 ]; then
    return 0
  fi
  local body
  body=$(printf '%s\n**Held review â€” red required check(s), no forward progress (issue #1148).** This PR holds a `pr-reviewing` claim but has failing required check(s):\n\n%s\n\nThe review gate cannot open over red CI. Per `pr-review` Phase 7, this must hand off to `/sge:pr-fix` (spec-drift / lint / format failures are control-preserving-resolvable there). Surfacing the check name so this is not a silent stall.' "$marker" "$(printf '%s\n' "$names" | sed 's/^/- /')")
  gh pr comment "$pr" --body "$body" >/dev/null 2>&1
}

# Returns 0 (stale draft) when a PR is an ABANDONED draft the stale-draft lane
# (issue #1248) should act on. STALE iff ALL of:
#   - the PR is a draft (isDraft true), AND
#   - it carries NEITHER pr-reviewing NOR pr-reviewed (a claimed/gated draft is
#     someone else's lane â€” the #755 orphan carve-out / normal review flow), AND
#   - its head commit is older than STALE_DRAFT_MINUTES (the implementer that
#     opened it stopped pushing long enough ago to presume it died), AND
#   - NO check is in flight (no PENDING / QUEUED / IN_PROGRESS / REQUESTED /
#     WAITING) â€” a running check means the implementer's CI may still finish and
#     mark it ready itself; never pre-empt a live run.
# A non-draft, a draft with a newer commit, a claimed draft, a draft with CI in
# flight, or a draft with a missing/unreadable commit timestamp -> FRESH
# (return 1). Never act on missing data.
is_stale_draft() {
  local pr=$1 is_draft labels committed cutoff committed_s inflight
  is_draft=$(gh pr view "$pr" --json isDraft --jq '.isDraft' 2>/dev/null)
  [ "$is_draft" = "true" ] || return 1
  labels=$(gh pr view "$pr" --json labels \
    --jq '[.labels[].name] | any(test("pr-reviewing|pr-reviewed"))' 2>/dev/null)
  [ "$labels" = "true" ] && return 1
  committed=$(gh pr view "$pr" --json commits --jq '[.commits[].committedDate] | last' 2>/dev/null)
  # Missing commit timestamp -> never act (treat as FRESH).
  [ -n "$committed" ] && [ "$committed" != "null" ] || return 1
  cutoff=$(date -u -d "-${STALE_DRAFT_MINUTES} min" +%s 2>/dev/null \
        || date -u -v-"${STALE_DRAFT_MINUTES}"M +%s)
  committed_s=$(date -u -d "$committed" +%s 2>/dev/null \
             || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$committed" +%s)
  [ "${committed_s:-9999999999}" -lt "$cutoff" ] || return 1
  # Any check still in flight means the implementer's run may not be dead yet.
  inflight=$(gh pr checks "$pr" --json state \
    --jq '[.[] | select(.state == "PENDING" or .state == "QUEUED" or .state == "IN_PROGRESS" or .state == "REQUESTED" or .state == "WAITING")] | length' 2>/dev/null)
  [[ "$inflight" =~ ^[0-9]+$ ]] || inflight=1   # unreadable -> assume in flight (FRESH)
  [ "$inflight" -eq 0 ] || return 1
  return 0
}

# Act on an abandoned draft (issue #1248) â€” NEVER silently.
#   CI GREEN (no failing required check)  -> `gh pr ready` (it was one command
#       from done) + loud log + an audit comment recording the auto-ready.
#   CI RED / incomplete                   -> an idempotent (per-head-SHA)
#       abandonment comment naming the failing check(s), so the draft is
#       surfaced to the fleet instead of aging invisibly. Never marks it ready.
# Idempotent per head SHA (post_stall_comment's marker convention): a fresh
# commit re-arms; repeated cycles at the same head do not spam.
# SELF-GUARDS on is_stale_draft first: this is a terminal action (readying a
# live implementer's draft would disrupt an active run), so "never touch an
# active draft" is an invariant of THIS function, not merely the caller's â€” a
# mis-wire can't ready a draft whose implementer is still alive. Returns 1
# (no-op) when the PR is not, in fact, a stale draft.
stale_draft_lane() {
  local pr=$1 head marker existing failing body
  is_stale_draft "$pr" || return 1
  head=$(gh pr view "$pr" --json headRefOid --jq '.headRefOid' 2>/dev/null)
  marker="<!-- sge:stale-draft-lane ${head} -->"
  failing=$(gh pr checks "$pr" --json state \
    --jq "[.[] | select($FAILING_CHECK_JQ)] | length" 2>/dev/null)
  [[ "$failing" =~ ^[0-9]+$ ]] || failing=1   # unreadable -> treat as red (do not auto-ready)
  if [ "$failing" -eq 0 ]; then
    # GREEN â€” mark ready, log loudly, and leave an audit trail.
    echo "WARNING: PR #$pr â€” abandoned GREEN draft (no commit for >${STALE_DRAFT_MINUTES}m, CI green, no in-flight checks); marking ready for review" >&2
    gh pr ready "$pr" >/dev/null 2>&1
    body=$(printf '%s\n**Abandoned draft â€” auto-marked ready (issue #1248).** This draft had no new commit for over %s minutes and its CI is green with no checks in flight, so its implementer is presumed to have died before running `gh pr ready`. Marking it ready for review so a review lane will pick it up. If this was premature, convert it back to a draft.' "$marker" "$STALE_DRAFT_MINUTES")
    gh pr comment "$pr" --body "$body" >/dev/null 2>&1
    return 0
  fi
  # RED / incomplete â€” surface it (idempotent per head), never mark ready.
  existing=$(gh api --paginate "repos/{owner}/{repo}/issues/$pr/comments" \
    --jq "[.[] | select(.body | contains(\"$marker\"))] | length" 2>/dev/null \
    | awk '{s+=$1} END{print s+0}')
  if [ "${existing:-0}" -gt 0 ]; then
    return 0
  fi
  local names
  names=$(named_failing_checks "$pr")
  echo "WARNING: PR #$pr â€” abandoned RED draft (no commit for >${STALE_DRAFT_MINUTES}m, failing check(s)); flagging, not readying" >&2
  body=$(printf '%s\n**Abandoned draft â€” red CI (issue #1248).** This draft had no new commit for over %s minutes and has failing required check(s):\n\n%s\n\nIts implementer is presumed to have died mid-run, leaving it invisible to every review/merge lane (drafts are excluded). It is NOT being auto-readied over red CI â€” route it to `/sge:pr-fix` (or fix and re-push), then it will be readied on the next pass. Surfacing so it is not a silent zero-cost cycle.' "$marker" "$STALE_DRAFT_MINUTES" "$(printf '%s\n' "$names" | sed 's/^/- /')")
  gh pr comment "$pr" --body "$body" >/dev/null 2>&1
  return 0
}

# $MERGE_GATE_LABEL is resolved at startup from the repo's CLAUDE.md (fallback: "pr-reviewed").
pr_ready_for_merge() {
  local pr=$1
  local body labels failing

  # Gate 1 â€” issue linked
  body=$(gh pr view "$pr" --json body --jq '.body' 2>/dev/null)
  # This gate asserts the PR is LINKED to an issue, not that it closes one.
  # `Part of #N` (#2241) is the deliberate non-closing link written when a PR
  # lands part of a multi-AC issue or the issue is a `tracking`/`epic` umbrella.
  # Rejecting it made every correctly-formed partial PR unmergeable, and the
  # documented remedy was to append `Fixes #N` — reintroducing the defect.
  # No cross-repo prefix: a reference to an issue in ANOTHER repo is not a
  # link to this PR's own tracked issue and must not satisfy this gate.
  if ! printf '%s' "$body" | grep -iqE '(clos(e|es|ed)|fix(es|ed)?|resolv(e|es|ed)|(^|[^[:alnum:]])part[[:space:]]+of)[[:space:]]+#[0-9]+'; then
    echo "GATE_FAIL:not_linked"; return 1
  fi

  # Gate 2 â€” merge-gate label present
  labels=$(gh pr view "$pr" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null)
  if ! printf '%s' "$labels" | grep -q "$MERGE_GATE_LABEL"; then
    echo "GATE_FAIL:not_reviewed"; return 1
  fi

  # Gate 3 â€” CI green. Use the SHARED terminal-red set ($FAILING_CHECK_JQ, defined
  # above) rather than a hand-rolled FAILURE/TIMED_OUT pair: a CANCELLED required
  # check (the #1665 scenario) shows in `gh pr checks` as a red row, and the old
  # narrow pair let it PASS Gate 3 â€” the PR would report READY and arm after the
  # settle window over a cancelled check. The shared set catches CANCELLED /
  # ACTION_REQUIRED / STARTUP_FAILURE / STALE too, matching held_review_stall and
  # stale_draft_lane. Non-numeric jq/gh output -> treat as failing (fail-closed).
  failing=$(gh pr checks "$pr" --json state \
    --jq "[.[] | select($FAILING_CHECK_JQ)] | length" 2>/dev/null)
  [[ "$failing" =~ ^[0-9]+$ ]] || failing=1
  if [[ "$failing" -gt 0 ]]; then
    echo "GATE_FAIL:ci_failing"; return 1
  fi

  echo "READY"; return 0
}

# Returns 0 (true) when a run was CANCELLED or TIMED_OUT â€” a structural
# non-outcome, NOT a code failure (issue #1665). This is the decisive,
# duration-independent signal the old <30s heuristic missed entirely: two real
# runs cancelled after 30m+ (one after `Test Files 156 passed`, one with the
# suite `skipped` because `actions/checkout` died) both classified as CODE FAIL
# and burned a /sge:pr-fix agent hunting a bug that did not exist. A fix agent is
# the single most expensive action the monitor takes, so this check gates it.
#
# The signal is the RUN's own `conclusion` (`cancelled`/`timed_out`), plus the
# job-level tell: a `Run tests`-shaped step left `skipped` because an earlier
# setup/checkout step was `cancelled` â€” the suite never executed, so there is no
# code verdict to act on. Either is decisive regardless of how long the run ran.
#
# Load-bearing consequence for the caller: a cancelled run can NEVER be cleared
# by `gh run rerun --failed` â€” re-running its failed jobs leaves the RUN's
# conclusion `cancelled` and the check red (observed: three `--failed` reruns,
# one cancelled run at head, zero progress). The escape is a FRESH run â€”
# `gh pr update-branch` (also fixes the usually-stale base) or a full
# `gh run rerun` (no `--failed`) â€” see the CANCELLED row in SKILL.md.
#
# Fail-safe: an unreadable conclusion (network/auth/run-gone) returns 1 (not
# cancelled) so a transient API error never mis-routes a genuine red to "rerun".
is_cancelled_run() {
  local run_id=$1 conclusion skipped_after_cancel
  conclusion=$(gh run view "$run_id" --json conclusion --jq '.conclusion' 2>/dev/null)
  case "$conclusion" in
    cancelled|timed_out) return 0 ;;
  esac
  # Job-level tell: any step is `cancelled` (e.g. checkout killed) AND a
  # test-shaped step is `skipped` in the same job â€” the suite never ran, so this
  # is a structural non-outcome even if the run's own conclusion is `failure`.
  skipped_after_cancel=$(gh run view "$run_id" --json jobs \
    --jq '[.jobs[] | select(
             ([.steps[]? | select(.conclusion == "cancelled")] | length) > 0
             and ([.steps[]? | select(.conclusion == "skipped"
                    and (.name | ascii_downcase | test("test")))] | length) > 0
           )] | length' 2>/dev/null)
  [[ "$skipped_after_cancel" =~ ^[0-9]+$ ]] || skipped_after_cancel=0
  [ "$skipped_after_cancel" -gt 0 ]
}

# Returns 0 (true) when a failed run looks infra-shaped and a plain
# `gh run rerun --failed` is the right cheap action â€” a runner casualty, NOT a
# cancellation. A CANCELLED/TIMED_OUT run is deliberately EXCLUDED here (it is
# its own state â€” `is_cancelled_run`, CANCELLED row â€” because `--failed` can
# never clear it); this predicate is only the fast runner-died signal:
#   - the run's conclusion is not cancelled/timed_out, AND
#   - no job in the run lasted 30s (started work but died before doing any).
# The duration test is kept only as a WEAK secondary hint per issue #1665 â€”
# the primary infra-vs-code signal is now the conclusion-based cancellation
# check above, which callers MUST consult first (SKILL.md classification order).
is_infra_failure() {
  local run_id=$1 max_duration
  # A cancelled/timed-out run is NOT rerun-with-failed infra â€” route it to the
  # CANCELLED state instead. Exclude it here so this stays the runner-died signal.
  if is_cancelled_run "$run_id"; then
    return 1
  fi
  max_duration=$(gh run view "$run_id" --json jobs \
    --jq '[.jobs[] | select(.completedAt != null and .startedAt != null)
           | ((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601))]
          | if length > 0 then max else 999 end' 2>/dev/null)
  [[ "${max_duration:-999}" -lt 30 ]]   # <30s with no real work â†’ INFRA FAIL
}

# Escape a cancelled/timed-out run â€” force a FRESH run rather than reruning failed
# jobs on a run whose conclusion can never flip green (issue #1665, Defect 3).
# Prefers `gh pr update-branch` (also fixes the usually-stale base that provoked
# the cancellation), which pushes a new head and triggers CI from scratch; falls
# back to a full `gh run rerun <run_id>` (NO `--failed`) when there is nothing to
# rebase onto. Callers MUST heed issue #1666: do NOT update-branch a branch a
# local worktree holds (`update_branch_safe` guards it) â€” a rebase would strand
# that worktree; re-sync it (see `worktree_sync_state`) before further work.
#
# Rerun cap (issue #1665): a cancelled run must not be retried indefinitely â€” the
# field report hit the same run id three times with zero progress. ENFORCED here
# (not merely documented): a per-run-id attempt ledger under $CANCELLED_RERUN_STATE
# (default a tmp dir) counts `fresh-rerun` actions per run id, and once
# CANCELLED_RERUN_CAP (default 2) is reached this refuses to rerun that run again
# and echoes `noop:rerun-cap-reached` â€” the caller must escalate (a genuinely new
# head, or human triage) rather than resurrect the dead run. The update-branch path
# is NOT capped: it produces a NEW run on a new head, which is the sanctioned
# escape, not a same-run retry. Echoes the action (`update-branch` / `fresh-rerun`
# / `noop:<reason>`) so the caller can log it.
CANCELLED_RERUN_CAP="${CANCELLED_RERUN_CAP:-2}"
CANCELLED_RERUN_STATE="${CANCELLED_RERUN_STATE:-${TMPDIR:-/tmp}/sge-prmon-rerun-attempts}"
escape_cancelled_run() {
  local pr=$1 run_id=$2 ledger attempts
  # Prefer a rebase-driven fresh run: fixes the stale base AND re-triggers CI on a
  # new head (uncapped â€” it is not a same-run retry).
  if gh pr update-branch "$pr" >/dev/null 2>&1; then
    echo "update-branch"; return 0
  fi
  [ -n "$run_id" ] || { echo "noop:no-fresh-run-available"; return 1; }
  # Same-run rerun path â€” enforce the cap per run id via the ledger.
  mkdir -p "$CANCELLED_RERUN_STATE" 2>/dev/null
  ledger="$CANCELLED_RERUN_STATE/$run_id"
  attempts=$(cat "$ledger" 2>/dev/null)
  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
  if [ "$attempts" -ge "$CANCELLED_RERUN_CAP" ]; then
    echo "noop:rerun-cap-reached"; return 1
  fi
  # Force a full, non-`--failed` rerun so the whole run is recreated rather than
  # resurrecting the cancelled one; record the attempt only on a successful launch.
  if gh run rerun "$run_id" >/dev/null 2>&1; then
    printf '%s' "$(( attempts + 1 ))" > "$ledger" 2>/dev/null
    echo "fresh-rerun"; return 0
  fi
  echo "noop:no-fresh-run-available"; return 1
}

# ---- worktree-vs-remote sync (issue #1666) --------------------------------
# `gh pr update-branch` rebases the REMOTE branch and does NOT touch a local
# worktree checked out on that branch â€” the worktree silently stays on the
# pre-rebase commit. The monitor's CONFLICTING row runs update-branch, and its
# lanes dispatch agents that work inside worktrees, so the documented happy path
# can leave an agent's worktree behind the ref it will push to. Committing from
# that state force-pushes a tree missing everything the rebase pulled in â€” the
# observed near-miss would have reverted six merged PRs' worth of work (80 files
# of newer base content the local tree lacked). The worktree looks perfectly
# healthy â€” clean status, right branch â€” the only tell is a HEAD that disagrees
# with origin, which nothing checked. These helpers make that the mechanical,
# fail-loud rule the skill enforces.

# Echo the remote tip SHA of <branch> on origin (one `git ls-remote` call), or
# nothing if it cannot be read. Kept separate so callers can compare cheaply.
# Runs in <dir> (default: cwd) so it queries the worktree's OWN origin, not
# whatever repo the process cwd happens to be â€” the sync helpers pass the same
# dir they operate on.
remote_branch_sha() { # $1=branch  [$2=dir]
  local branch=$1 dir="${2:-$PWD}"
  git -C "$dir" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1{print $1}'
}

# Return 0 iff the worktree rooted at <dir> (default: cwd) is checked out on
# <branch> AND its HEAD equals origin's tip for that branch â€” i.e. it is safe to
# commit and push. Returns 1 on ANY mismatch OR unreadable state (fail-closed:
# an unknowable sync state must be treated as unsafe, never assumed synced).
# This is the cheap one-call preflight the issue asks lane dispatch to run before
# handing a worktree to an agent, and that a dispatched agent runs before its
# first commit.
worktree_synced_with_remote() { # $1=branch  [$2=worktree dir]
  # Point-in-time snapshot: the ls-remote read races a concurrent push, but the
  # race is benign â€” this helper only READS (no fetch/reset follows it), and a
  # stale "synced"/"stale" verdict self-corrects on the next monitor pass. The
  # caller acts on the verdict, never mutates off the SHA read here.
  local branch=$1 dir="${2:-$PWD}" local_sha remote_sha cur_branch
  cur_branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 1
  [ "$cur_branch" = "$branch" ] || return 1
  local_sha=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || return 1
  remote_sha=$(remote_branch_sha "$branch" "$dir")
  [ -n "$local_sha" ] && [ -n "$remote_sha" ] || return 1   # unknowable -> unsafe
  [ "$local_sha" = "$remote_sha" ]
}

# Guard `gh pr update-branch` on a branch that is checked out in a local worktree
# â€” the PREVENTION rule for issue #1666 (chosen over an autonomous in-library
# hard-reset repair, which is both a flagged destructive-action pattern in a skill
# and the more fragile mechanic). Rebasing the remote while a worktree sits on that
# branch is what strands the worktree; the safe rule is: **don't run update-branch
# on such a branch from the monitor â€” resolve the conflict without it, or have the
# human re-sync the worktree first.**
#
# Returns 0 (SAFE to update-branch) iff NO local worktree is currently checked out
# on <branch>; returns 1 (UNSAFE â€” a worktree holds it) otherwise, echoing the
# holding worktree path so the caller can name it. Reads `git worktree list
# --porcelain` (read-only). Fail-closed: on unreadable worktree state it returns 1
# (assume a worktree may hold the branch) so a broken read never green-lights the
# hazardous rebase. Run in <dir> (default cwd) to scope to that checkout's repo.
update_branch_safe() { # $1=branch  [$2=dir]
  local branch=$1 dir="${2:-$PWD}" wl holder
  wl=$(git -C "$dir" worktree list --porcelain 2>/dev/null) || return 1
  [ -n "$wl" ] || return 1   # unreadable -> fail-closed (assume held)
  # Walk porcelain records: a `worktree <path>` line followed by a matching
  # `branch refs/heads/<branch>` line means that worktree holds the branch.
  holder=$(printf '%s\n' "$wl" | awk -v b="refs/heads/$branch" '
    /^worktree /  { path = substr($0, 10) }
    /^branch /    { if (substr($0, 8) == b) { print path; exit } }
  ')
  if [ -n "$holder" ]; then
    echo "unsafe:worktree-holds-branch:$holder"; return 1
  fi
  return 0
}

# Surface a CONFLICTING PR that the monitor CANNOT `update-branch` because a local
# worktree holds its branch (issue #1666). Prevention without surfacing would be a
# SILENT STALL: the PR just sits unrebased every cycle with no trace for a human,
# unlike every other blocked case here (post_stall_comment, stale_draft_lane's
# abandonment comment, post_github_degraded_comment), which all leave an idempotent
# per-head-SHA comment naming why. This mirrors that pattern exactly.
#
# Idempotent per head SHA: the marker embeds the head, so a fresh push re-arms but
# repeated cycles at the same head don't spam. Also logs a WARNING to stderr. Pass
# the holder path (as echoed by update_branch_safe) so the comment names WHICH
# worktree to re-sync. Fail-safe: an unreadable head still logs the WARNING.
post_update_branch_blocked_comment() { # $1=pr  [$2=holder worktree path]
  local pr=$1 holder="${2:-}" head marker existing body
  echo "WARNING: PR #$pr â€” CONFLICTING but update-branch is UNSAFE: a local worktree holds its branch${holder:+ ($holder)}; not rebasing (would strand that worktree, issue #1666). Re-sync the worktree, then it rebases next cycle." >&2
  head=$(gh pr view "$pr" --json headRefOid --jq '.headRefOid' 2>/dev/null)
  marker="<!-- sge:update-branch-blocked ${head} -->"
  existing=$(gh api --paginate "repos/{owner}/{repo}/issues/$pr/comments" \
    --jq "[.[] | select(.body | contains(\"$marker\"))] | length" 2>/dev/null \
    | awk '{s+=$1} END{print s+0}')
  if [ "${existing:-0}" -gt 0 ]; then
    return 0
  fi
  body=$(printf '%s\n**CONFLICTING â€” update-branch withheld (issue #1666).** This PR is behind its base, but the monitor is **not** running `gh pr update-branch` because a local worktree is checked out on its branch%s. Rebasing the remote while a worktree holds the branch strands that worktree on the pre-rebase commit â€” an agent could then push a tree that reverts merged work (the #1666 near-miss). **Action:** re-sync (or free) that worktree to the branch tip, then the monitor rebases on the next cycle. Surfaced once per head-SHA so this is not a silent stall.' "$marker" "${holder:+ (\`$holder\`)}")
  gh pr comment "$pr" --body "$body" >/dev/null 2>&1
}

# Report whether the worktree at <dir> needs a manual re-sync after an
# update-branch that already happened elsewhere â€” a READ-ONLY diagnostic (no
# mutation, so no destructive action lives in this library). Echoes exactly one
# of: `synced` (HEAD == origin tip â€” safe to commit/push), `stale:<remote_sha>`
# (behind origin â€” the caller/human must re-sync this worktree to <remote_sha>
# before any further work; see SKILL.md), `dirty` (uncommitted changes â€” never
# auto-touch), or `unknown` (unreadable â€” treat as unsafe). Fail-closed: anything
# but `synced` means "do not commit/push from here yet".
worktree_sync_state() { # $1=branch  [$2=worktree dir]
  local branch=$1 dir="${2:-$PWD}" remote_sha dirty
  if worktree_synced_with_remote "$branch" "$dir"; then
    echo "synced"; return 0
  fi
  dirty=$(git -C "$dir" status --porcelain 2>/dev/null)
  [ -n "$dirty" ] && { echo "dirty"; return 1; }
  remote_sha=$(remote_branch_sha "$branch" "$dir")
  [ -n "$remote_sha" ] || { echo "unknown"; return 1; }
  echo "stale:$remote_sha"; return 1
}

# Returns 0 (true) when this repo ships the dedicated "SGD/SGE Auto-Approve &
# Merge" workflow. pr-monitor's READY fallback must skip its local
# `gh pr merge --squash --auto` arm in that case (issue #2084), otherwise it can
# race the dedicated bot and reintroduce human-attributed merges.
repo_has_dedicated_automerge_bot() {
  local toplevel hit
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -d "$toplevel/.github/workflows" ] || return 1
  hit="$(find "$toplevel/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) \
    -exec grep -lq "Standing automation for WealthTech Pros' Model-B autonomous review loop" {} \; -print -quit 2>/dev/null)"
  [ -n "$hit" ]
}
# ---- auto-merge disarm + settle (issue #1668) -----------------------------
# `gh pr merge --squash --auto` is IRREVERSIBLE by label removal: once armed,
# GitHub keeps the auto-merge request and merges the PR the instant checks go
# green, whatever the gate label now says. Retracting the merge-gate label does
# NOT disarm it. So an irreversible action needs a compensating reversal (a
# disarm pass) AND a settle guard, or the gate is one-way. Observed on a real PR:
# label applied 17:37:53, armed 17:38:22 (29s later), label RETRACTED 17:42:05 â€”
# and the PR stayed armed for 27 minutes, merging held off only by luck (a
# separate failing required check), not by design.

# Seconds since the merge-gate label was last APPLIED to <pr>, from the issue
# timeline's most recent labeled/unlabeled event for that label. Echoes the age
# in whole seconds, or nothing if the label is not currently applied (last event
# was `unlabeled`) or the timeline is unreadable â€” the caller MUST treat empty as
# "not settled" (fail-closed: never arm on unknown age). Uses `date -u` for BOTH
# the parse and `now`: parsing a UTC 'Z' timestamp without -u reads it as LOCAL
# time and inflates every age by the UTC offset, silently defeating the settle
# guard (the issue's documented trap: a 40s-old label logged as "stable 3640s").
merge_gate_label_age_seconds() { # $1=pr  [$2=label]  [$3=repo]
  local pr=$1 label="${2:-$MERGE_GATE_LABEL}" repo_full="${3:-}"
  repo_full="${repo_full:-${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}}"
  [ -n "$repo_full" ] || return 0
  local last_event last_at now_epoch at_epoch
  # Take the LAST labeled/unlabeled event for this exact label. If it is an
  # `unlabeled`, the label is not currently applied -> emit nothing (not settled).
  last_event=$(gh api "repos/$repo_full/issues/$pr/timeline" --paginate \
    --jq ".[] | select((.event==\"labeled\" or .event==\"unlabeled\") and .label.name==\"$label\") | .event + \" \" + .created_at" \
    2>/dev/null | tail -n 1)
  [ -n "$last_event" ] || return 0
  case "$last_event" in
    labeled\ *) last_at="${last_event#labeled }" ;;
    *) return 0 ;;   # last event was unlabeled -> label gone -> not settled
  esac
  at_epoch=$(date -u -d "$last_at" +%s 2>/dev/null \
          || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_at" +%s 2>/dev/null) || return 0
  now_epoch=$(date -u +%s)
  printf '%s' "$(( now_epoch - at_epoch ))"
}

# Return 0 iff the merge-gate label has been CONTINUOUSLY present on <pr> for at
# least AUTOMERGE_SETTLE_SECONDS (default 300) â€” the window a self-correcting
# reviewer needs to retract before an irreversible arm fires (issue #1668,
# Defect 2: the armer fired 29s after the label appeared). Fail-closed: an
# unreadable/absent label age is NOT settled (return 1). Callers gate the READY
# row's `gh pr merge --auto` on this.
AUTOMERGE_SETTLE_SECONDS="${AUTOMERGE_SETTLE_SECONDS:-300}"
automerge_settle_ok() { # $1=pr
  local age
  age=$(merge_gate_label_age_seconds "$1")
  [[ "$age" =~ ^[0-9]+$ ]] || return 1
  [ "$age" -ge "$AUTOMERGE_SETTLE_SECONDS" ]
}

# Echo the numbers of open PRs that are ARMED for auto-merge but no longer carry
# the merge-gate label â€” the disarm worklist (issue #1668, Defect 1). One
# `gh pr list` call; the caller runs `gh pr merge <n> --disable-auto` per row.
# This is the compensating reversal that makes arming safe at all.
armed_without_gate_label() { # [$1=label]
  local label="${1:-$MERGE_GATE_LABEL}"
  gh pr list --state open --json number,labels,autoMergeRequest \
    --jq ".[] | select(.autoMergeRequest != null)
          | select([.labels[].name] | index(\"$label\") | not) | .number" 2>/dev/null
}

# Disarm every PR that is armed-but-unlabelled: for each number from
# armed_without_gate_label, disable auto-merge and log loudly. Idempotent â€” a PR
# already disarmed simply is not in the list next cycle. Echoes one
# `disarmed:<n>` line per PR acted on so the caller/heartbeat can record it.
disarm_stale_automerge() { # [$1=label]
  local label="${1:-$MERGE_GATE_LABEL}" pr
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    if gh pr merge "$pr" --disable-auto >/dev/null 2>&1; then
      echo "WARNING: PR #$pr â€” auto-merge was ARMED but the '$label' gate label is gone; disarming (issue #1668)" >&2
      echo "disarmed:$pr"
    else
      # Disarm FAILED â€” the PR is still armed with no gate label. Never swallow
      # this: an armed-but-unlabelled PR that resisted --disable-auto is exactly
      # the state that merges unreviewed. Surface it loudly for the operator.
      echo "WARNING: PR #$pr â€” FAILED to disable auto-merge (still ARMED without the '$label' gate label); needs operator attention (issue #1668)" >&2
      echo "disarm-failed:$pr"
    fi
  done < <(armed_without_gate_label "$label")
}

# Returns 0 (true) when any setup step in the failed run emitted `<!DOCTYPE html>`
# in its log â€” a second outage signal for the GITHUB DEGRADED classification
# (issue #1379). During a GitHub API degradation, API responses served as HTML
# rather than JSON poison setup steps (e.g. actions/checkout, actions/setup-node)
# long before any real work runs. This is distinct from is_infra_failure's
# duration heuristic: a setup step that fetches an API response and receives HTML
# will fail quickly (<30s) and match BOTH signals, but a degradation that slows
# rather than breaks the API may only match this one.
#
# Detection strategy: `gh run view --log-failed` streams the combined log of all
# failed steps. Grepping for `<!DOCTYPE html>` in that output catches the
# HTML-response pattern without requiring per-step API calls. Only setup-step
# names (case-insensitive match on "set up" or "setup") are considered, to avoid
# false positives from test fixtures or snapshot output that legitimately contains
# HTML. If the log fetch itself fails (network error, run too old), we return 1
# (not degraded) to avoid false positives â€” never classify GITHUB DEGRADED on
# missing data.
is_setup_step_html_error() {
  local run_id=$1 log_output
  # Fetch the failed-step log. On error (run gone, auth issue) we get nothing.
  log_output=$(gh run view "$run_id" --log-failed 2>/dev/null) || return 1
  [ -n "$log_output" ] || return 1
  # Filter to setup-step lines (step names starting with "Set up" or "Setup"),
  # then look for the <!DOCTYPE html> sentinel. The combined log format is:
  #   <job-name>  <step-name>  <log-line>
  # so we match on the step-name column (second tab-separated field).
  printf '%s\n' "$log_output" \
    | awk -F'\t' 'tolower($2) ~ /^set.?up/ && tolower($3) ~ /<!doctype html/ {found=1} END{exit !found}'
}

# Resolve scripts/github-status.sh (the shared outage predicate) so the park
# helper can read the CURRENT degradation indicator. Overridable via
# GITHUB_STATUS_SCRIPT (tests point it at a stub); else ${CLAUDE_PLUGIN_ROOT}/
# scripts/github-status.sh; else resolve relative to THIS library file
# (skills/pr-monitor/ -> ../../scripts/), so it works sourced or executed.
_github_status_script_path() {
  if [ -n "${GITHUB_STATUS_SCRIPT:-}" ]; then
    printf '%s' "$GITHUB_STATUS_SCRIPT"; return 0
  fi
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/github-status.sh" ]; then
    printf '%s' "${CLAUDE_PLUGIN_ROOT}/scripts/github-status.sh"; return 0
  fi
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || return 0
  printf '%s' "$here/../../scripts/github-status.sh"
}

# Print the CURRENT top-level GitHub degradation indicator ("none"/"minor"/
# "major"/"critical"/"error"). FAIL-SAFE, never fail-open (cf. #1390): any
# unreachable/unresolvable predicate maps to "error" â€” a degraded state â€” so a
# status-API blip can never silence the park step by masquerading as "none".
# github-status.sh keeps the no-jq (grep/awk) extraction; we only read its
# already-computed indicator here.
_github_degraded_indicator() {
  local script ind=""
  script=$(_github_status_script_path)
  if [ -n "$script" ] && [ -f "$script" ]; then
    ind=$(bash "$script" --indicator 2>/dev/null | tr -d '[:space:]')
  fi
  [ -n "$ind" ] || ind="error"   # unreachable/unresolvable -> degraded (fail-safe)
  printf '%s' "$ind"
}

# Idempotently park a PR blocked by a GitHub degradation event (issue #1434,
# runbook docs/fleet-deployment-config.md) with ONE `github-degraded` comment,
# so the GITHUB DEGRADED action is a mechanical helper instead of hand-done
# prose. While degraded, reruns and /sge:pr-fix / /sge:pr-review dispatch are
# suppressed (the SKILL.md GITHUB DEGRADED row) â€” the failure has no diff cause.
#
# Idempotent PER HEAD SHA **and** PER INDICATOR: the marker embeds both the head
# oid and the current indicator, so repeated cycles at the same head under the
# same indicator do NOT spam, but a NEW head (author pushed) or an ESCALATION
# (minor -> major -> critical) posts exactly once more. Mirrors
# post_stall_comment's paginated gh-api marker lookup (gh's --jq is a filter
# string, so the controlled marker â€” no jq metacharacters â€” is inlined).
#
# FAIL-SAFE, not fail-open (#1390): a healthy indicator ("none") is the only
# no-op; an unreachable status API derives to "error" and STILL parks.
post_github_degraded_comment() {
  local pr=$1 indicator head marker existing body
  indicator=$(_github_degraded_indicator)
  # Only a genuinely healthy indicator is a no-op â€” everything else parks.
  [ "$indicator" = "none" ] && return 0
  head=$(gh pr view "$pr" --json headRefOid --jq '.headRefOid' 2>/dev/null)
  marker="<!-- sge:github-degraded ${head} ${indicator} -->"
  existing=$(gh api --paginate "repos/{owner}/{repo}/issues/$pr/comments" \
    --jq "[.[] | select(.body | contains(\"$marker\"))] | length" 2>/dev/null \
    | awk '{s+=$1} END{print s+0}')
  if [ "${existing:-0}" -gt 0 ]; then
    return 0
  fi
  body=$(printf '%s\n**Parked â€” GitHub degraded (`%s`).** Per the outage runbook (`docs/fleet-deployment-config.md`), reruns and `/sge:pr-fix` / `/sge:pr-review` dispatch are suppressed while GitHub is degraded â€” the failure has no diff cause. This monitor re-checks each cycle and resumes routing (with a single rerun) once `scripts/github-status.sh` reports full recovery (`none`). Posted once per head-SHA + indicator, so it is not re-posted every cycle.' "$marker" "$indicator")
  gh pr comment "$pr" --body "$body" >/dev/null 2>&1
}

# Returns 0 (systemic) when >= 67% of the oldest-N eligible PRs are failing.
check_systemic_failure() {
  local failing=0 total=0 N=${1:-3} pr has_failure
  while IFS= read -r pr; do
    is_spec_pr "$pr" && continue
    ((total++)); [[ $total -gt $N ]] && break
    has_failure=$(gh pr checks "$pr" --json state \
      --jq 'if any(.[]; .state == "FAILURE" or .state == "TIMED_OUT") then "yes" else "no" end' 2>/dev/null)
    [[ "$has_failure" == "yes" ]] && ((failing++))
  done < <(fetch_candidate_prs)
  [[ $total -gt 0 && $((failing * 100 / total)) -ge 67 ]]
}

# Returns 0 (true) when PR is a blast-radius carve-out.
# Echoes a one-word reason string before returning 0 so callers can log it.
# The canonical carve-out condition list lives in SKILL.md Appendix A â€”
# keep this function and that table in lockstep.
is_blast_radius_pr() {
  local pr=$1
  # Cache the file list â€” one API call, not four.
  local files
  files=$(gh pr diff "$pr" --name-only 2>/dev/null)
  printf '%s' "$files" | grep -qE \
    'package\.json$|pnpm-lock\.yaml$|package-lock\.json$|yarn\.lock$|\.npmrc$|^patches/|pyproject\.toml$|poetry\.lock$|uv\.lock$|requirements[^/]*\.txt$|(^|/)requirements/[^/]+\.txt$|(^|/)setup\.(py|cfg)$|(^|/)Pipfile(\.lock)?$' \
    && { echo "lockfile"; return 0; }
  printf '%s' "$files" | grep -qE \
    'tsconfig[^/]*\.json$|vite\.config\.[^/]+$|vitest\.config\.[^/]+$' \
    && { echo "shared-config"; return 0; }
  printf '%s' "$files" | grep -qE \
    '^\.github/workflows/[^/]+\.ya?ml$' \
    && { echo "ci-workflow"; return 0; }
  printf '%s' "$files" | grep -qE \
    '\.prisma$|(^|/)migrations/|(^|/)alembic/|(^|/)alembic\.ini$|codegen\.[^/]+$' \
    && { echo "codegen-schema"; return 0; }
  printf '%s' "$files" | grep -qE \
    '(^|/)Dockerfile|docker-compose[^/]*\.ya?ml$' \
    && { echo "container"; return 0; }
  local author
  author=$(gh pr view "$pr" --json author --jq '.author.login' 2>/dev/null)
  echo "$author" | grep -qE '\[bot\]$|^dependabot|/dependabot|^renovate' \
    && { echo "bot-author"; return 0; }
  return 1
}

