#!/usr/bin/env bash
# followups-gate.sh — the follow-up preservation gate, shared by pr-labels.sh
# (GitHub / Forgejo) and pr-labels-azdo.sh (Azure Repos, issue #2989). SOURCE it:
# it defines assert_followups_preserved only. It reads $PR, $REVIEWED,
# $_PRL_HOST, $_PRL_ORIGIN, $_PRL_ADAPTER and $_PRL_SCRIPT_DIR from the caller.
# Moved verbatim out of pr-labels.sh; the only change is the azdo body read.

# Follow-up preservation gate (issue #859).
#
# A PR that declares a "follow-up" / "deferred" item — in its body or in the
# review's own text — but closes its linked issue via `Fixes #N` auto-close on
# merge silently DESTROYS that follow-up's only durable home. PR #844 (issue
# #802) declared the sourcePaths backfill as a follow-up in its body; the issue
# would have auto-closed on merge and the follow-up would have evaporated — a
# reviewer noticed by luck and filed #847 to preserve it. Nothing in the pass
# path checked that declared follow-ups had somewhere to live before auto-merge
# was armed.
#
# This gate greps the PR body (and any review text the caller feeds via
# SGE_REVIEW_FOLLOWUP_TEXT / SGE_REVIEW_FOLLOWUP_FILE) for follow-up markers and
# REFUSES the pass (return 1 → no label swap, no auto-merge arm) if any marker
# line lacks an issue reference (#N / issues/N / GH-N) within a small lookahead
# window — a heading like "## Follow-ups" immediately above a list of items each
# carrying a #N therefore passes, while a lone prose "…as a follow-up." with no
# nearby number is blocked. The refusal names each unpreserved follow-up and
# tells the reviewer to file the issue first — exactly the manual #847
# remediation. Cheap, mechanical, fits the pr-labels.sh script-extraction
# pattern (#820). --skip-followup-check bypasses it (mirrors --skip-thread-check);
# SGE_FOLLOWUP_MARKERS / SGE_FOLLOWUP_LOOKAHEAD tune the markers and window.
# Fails CLOSED: an unreadable PR body refuses rather than arming blind.
assert_followups_preserved() {
  local body rc extra=""
  rc=0
  # Forgejo path (issue #1239): read PR body via the REST adapter instead of gh.
  if [[ "${_PRL_HOST:-github}" == "forgejo" ]]; then
    body=$("$_PRL_ADAPTER" pr-body "$_PRL_ORIGIN" "$PR" 2>/dev/null) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "refusing: PR #$PR — could not read PR body from Forgejo adapter; follow-up preservation gate fails closed (issue #859, issue #1239)" >&2
      echo "Fix adapter access (token, allow-list, network) and retry, or pass --skip-followup-check if this PR declares no follow-ups." >&2
      return 1
    fi
  elif [[ "${_PRL_HOST:-github}" == "azdo" ]]; then
    # Azure Repos (#2989): the PR description, via the adapter's gh-shaped get-pr.
    body=$(bash "$_PRL_SCRIPT_DIR/../../scripts/azdo-adapter.sh" get-pr "$_PRL_ORIGIN" "$PR" 2>/dev/null | jq -r '.body // ""') || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "refusing: PR #$PR — could not read the PR description from Azure DevOps; follow-up preservation gate fails closed (issue #859, #2989)" >&2
      echo "Fix adapter access (token, allow-list, network) and retry, or pass --skip-followup-check if this PR declares no follow-ups." >&2
      return 1
    fi
  else
    body=$(gh pr view "$PR" --json body --jq '.body // ""' 2>/dev/null) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "refusing: PR #$PR — could not read PR body; follow-up preservation gate fails closed (issue #859)" >&2
      echo "Fix gh access (auth, rate limit, network) and retry, or pass --skip-followup-check if this PR declares no follow-ups." >&2
      return 1
    fi
  fi
  # The review's own text, when the caller feeds it (Phase 8 exports it before
  # promoting) — so a follow-up declared only in the review, never in the PR
  # body, is caught too. Both channels are optional; absent = body-only scan.
  [[ -n "${SGE_REVIEW_FOLLOWUP_TEXT:-}" ]] && extra+=$'\n'"${SGE_REVIEW_FOLLOWUP_TEXT}"
  if [[ -n "${SGE_REVIEW_FOLLOWUP_FILE:-}" && -r "${SGE_REVIEW_FOLLOWUP_FILE}" ]]; then
    extra+=$'\n'"$(cat "${SGE_REVIEW_FOLLOWUP_FILE}")"
  fi

  local markers issueref look negations
  # Lowercased ERE (the awk below lowercases each line before matching).
  # "pr" markers require a word boundary after "pr"/"prs" (s?([^a-z]|$)) so
  # they match "future PR"/"separate PR"/"later PR" and their plurals
  # ("later PRs", "separate PRs") but not substrings inside ordinary words
  # like "product" or "print" (issue: false-positive on "separate product"
  # in licence-text PRs sge#2172 / sge-public#44 — awk ERE has no \b, so the
  # boundary is spelled out explicitly). The optional "s" must sit INSIDE the
  # boundary check (prs?(...)), not after it (pr(...)s?) — the latter would
  # silently stop matching plurals entirely (caught in review: the old bare
  # substring match happened to catch "PRs" by accident; a naive boundary fix
  # regressed it to zero plural matches, which is a fail-open detection gap,
  # not just a leftover false positive).
  markers="${SGE_FOLLOWUP_MARKERS:-follow[ -]?up|deferred|future prs?([^a-z]|$)|separate prs?([^a-z]|$)|later prs?([^a-z]|$)|in a follow}"
  issueref='#[0-9]+|issues/[0-9]+|gh-[0-9]+'
  look="${SGE_FOLLOWUP_LOOKAHEAD:-3}"
  [[ "$look" =~ ^[0-9]+$ ]] || look=3
  # Negation cue words (issue #1027): a marker match is NOT a declared
  # follow-up when one of these directly precedes it (within the 3 words
  # immediately before the match, e.g. "no deferred-completion exit path",
  # "not a follow-up", "no separate PR is needed"). Apostrophes are stripped
  # from the prefix BEFORE it is split into words, so contracted negations
  # ("isn't"/"doesn't"/"can't") collapse to their bare forms and match.
  negations="${SGE_FOLLOWUP_NEGATIONS:-no|not|never|isnt|arent|wasnt|werent|doesnt|dont|didnt|hasnt|havent|wont|wouldnt|cannot|cant|without}"
  # Follow-up cap (issue #2829): a MINOR finding the reviewer recorded in the
  # review comment, or declined with a reason, already has a durable home (the
  # review itself) and needs no tracking issue. A marker line that names a
  # minor AND carries one of these dispositions passes without an issue ref. A
  # line that also names a major/blocker never qualifies — majors are fixed in
  # the PR or get an issue, so the cap cannot launder one through "declined".
  local minor_disp
  minor_disp="${SGE_FOLLOWUP_MINOR_DISPOSITIONS:-recorded[ -]in[ -]review|declined}"

  local report
  report=$(printf '%s\n%s\n' "$body" "$extra" | awk \
      -v markers="$markers" -v issueref="$issueref" -v look="$look" -v negations="$negations"       -v minordisp="$minor_disp" '
    { sub(/\r$/, ""); line[NR] = $0 }
    END {
      n = NR; bad = 0; infence = 0
      negre = "^(" negations ")$"
      # Issue #2935: only an explicitly DECLARED follow-up counts. A marker
      # inside a code span / fenced block, or fused into a file name or
      # identifier (follow-up-cap.md, follow-up-cap-and-merge-lanes.test.sh),
      # is a name, not a declaration; a marker introduced by a rationale cue
      # ("Why a separate PR:") explains this PR, it defers nothing.
      whyre = "^(why|whether)$"
      idc = "abcdefghijklmnopqrstuvwxyz0123456789_/.-"
      for (i = 1; i <= n; i++) {
        if (line[i] ~ /^[ \t]*(```|~~~)/) { infence = !infence; continue }
        if (infence) continue
        lo = tolower(line[i])
        gsub(/`[^`]*`/, " ", lo)
        # Walk EVERY marker occurrence on the line (not just the first): a
        # line may both rule out one follow-up AND declare another, so the
        # negation decision is scoped to each occurrence, never the whole
        # line (issue #1027 defect 1: a whole-line skip fails OPEN when a
        # negated marker masks a later genuinely-undeclared one).
        s = lo; base = 0; active = 0
        while (match(s, markers)) {
          occ_start = base + RSTART      # 1-based offset of this match within lo
          mlen = RLENGTH
          # Negation check for THIS occurrence: is one of the (up to) 3 words
          # immediately before it a negation cue? If so this occurrence rules
          # OUT a follow-up — suppress it and keep scanning the rest of the line.
          prefix = substr(lo, 1, occ_start - 1)
          gsub(/'"'"'/, "", prefix)      # strip apostrophes: isn'"'"'t -> isnt
          nw = split(prefix, w, /[^a-z]+/)
          while (nw > 0 && w[nw] == "") nw--
          lo3 = nw - 2; if (lo3 < 1) lo3 = 1
          negated = 0
          for (k = lo3; k <= nw; k++) {
            if (w[k] ~ negre || w[k] ~ whyre) { negated = 1; break }
          }
          # #2935: a marker fused into a file name / identifier is not a
          # declaration. The pr markers consume their trailing boundary char,
          # so measure the word itself; a plural "s" stays part of the word.
          wl = mlen; if (substr(lo, occ_start + wl - 1, 1) !~ /[a-z]/) wl--
          bc = (occ_start > 1) ? substr(lo, occ_start - 1, 1) : ""
          ap = occ_start + wl; ac = substr(lo, ap, 1)
          if (ac == "s") { ap++; ac = substr(lo, ap, 1) }
          if (ac == ".") ac = substr(lo, ap + 1, 1)
          if ((bc != "" && index(idc, bc)) || (ac != "" && index(idc, ac))) negated = 1
          if (!negated) { active = 1; break }   # a real, non-negated marker
          adv = RSTART + mlen; if (adv < 1) adv = 1
          base = base + adv - 1
          s = substr(s, adv)
        }
        # #2829: a minor marked recorded-in-review / declined is dispositioned.
        if (active && lo ~ /(^|[^a-z])minor([^a-z]|$)/ && lo ~ minordisp             && lo !~ /(^|[^a-z])(major|blocker)s?([^a-z]|$)/) {
          active = 0
        }
        if (active) {
          found = 0
          hi = i + look; if (hi > n) hi = n
          for (j = i; j <= hi; j++) {
            if (tolower(line[j]) ~ issueref) { found = 1; break }
          }
          if (!found) {
            bad++
            t = line[i]; sub(/^[[:space:]]+/, "", t)
            printf("UNPRESERVED\t%s\n", substr(t, 1, 120))
          }
        }
      }
      printf("BADCOUNT\t%d\n", bad)
    }')

  local bad
  bad=$(printf '%s\n' "$report" | awk -F'\t' '$1=="BADCOUNT"{print $2}')
  [[ "$bad" =~ ^[0-9]+$ ]] || bad=0
  if [[ "$bad" -gt 0 ]]; then
    echo "refusing: PR #$PR declares $bad follow-up item(s) with no issue reference — will NOT open the $REVIEWED gate or arm auto-merge (issue #859):" >&2
    printf '%s\n' "$report" | awk -F'\t' '$1=="UNPRESERVED"{print "  - " $2}' >&2
    echo "A declared follow-up with no issue number evaporates when the linked issue auto-closes on merge (this happened on PR #844 → salvaged as #847)." >&2
    echo "File a tracking issue for each follow-up first, put its #number beside the follow-up in the PR body (or review text), then re-run pass. A MINOR may instead be marked recorded-in-review or declined on its line (issue #2829). Bypass: --skip-followup-check." >&2
    return 1
  fi
  return 0
}
