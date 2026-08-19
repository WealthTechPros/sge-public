# Phase 1 Discovery — staging detail (issue #1158)

Full detail for `../SKILL.md` Phase 1. Phase 1 is **not** a flat serial chain — the discovery
calls split into stages by their **read/write set**. Only calls proven mutually independent share
a stage; calls that gate the dispatch, or that read/write the PR body, are ordered.

## Read/write-set map (the contract this staging enforces)

| Call | GH resource | R/W | Ordering constraint |
|---|---|---|---|
| `rl_pr_state` | `pulls/$PR` (state/draft/head/labels) | READ | gates all spend (#699) — evaluate first |
| `rl_head_sha` | `pulls/$PR` `.head.sha` | READ | pins reviewed head; immutable in Phase 1 |
| `rl_phase5_verdict` | `pulls/$PR` `.body` | READ **body** | feeds pass-through gate; must precede the body WRITE |
| `gh pr diff --name-only` | diff | READ | independent |
| `gh issue view` (linked) | `issues/N` | READ | independent |
| `gh api .../pulls/$PR/comments` | PR comments | READ | independent |
| `rl_bot_signal` | `pulls/$PR/reviews` + `/comments` | READ | independent; produces `BOT_FINDINGS` (feeds `rl_diff_risk`) |
| `rl_ensure_closing_link` | `pulls/$PR` `.body` + `issues/$N` `.labels` → `gh pr edit --body` | **conditional WRITE (body)** | must run AFTER every body reader — no read-after-write race; skips on existing keyword, `Part of #N`, or a `tracking`/`epic` issue (#2241) |
| `rl_diff_risk` | `pulls/$PR`, files, security globs | READ | needs `BOT_FINDINGS`; body-insensitive |
| `rl_diff_trivial` | `pulls/$PR`, diff, checks, local git | READ | body-insensitive |

## Stage 0 — resolve + gate (blocking; batch the two pure `pulls/$PR` reads)

These read immutable-in-Phase-1 fields and gate whether any further call is made — a short-circuit
here spends nothing downstream:

```bash
source "${CLAUDE_PLUGIN_ROOT}/skills/pr-review/review-lib.sh"   # rl_* helpers
REPO="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"; export GH_REPO="$REPO"
PR="${1:-$(gh pr view --json number --jq .number 2>/dev/null)}"   # orchestrators pass it positionally
[ -n "$PR" ] || { echo "NO_PR — pass a PR number"; exit 1; }
REVIEW_MODE="default"                                             # issue #754
case " $ARGUMENTS " in
  *" --advisory "*)     REVIEW_MODE="advisory"; export SGE_REVIEW_ADVISORY=1 ;;
  *" --no-fix "*)       REVIEW_MODE="no-fix" ;;
  *" --no-automerge "*) REVIEW_MODE="no-automerge" ;;
esac
# rl_pr_state (short-circuit gate) and rl_head_sha both READ pulls/$PR only —
# mutually independent, so issue them concurrently, then evaluate the gate.
rl_pr_state "$PR" &                                              # short-circuit inputs (#699)
REVIEWED_HEAD=$(rl_head_sha "$PR")                               # pin the reviewed head
wait
```

Evaluate the short-circuit / delta / pass-through gates (see SKILL.md) **before** Stage 1 — a fired
gate stops here and spends nothing further. `rl_phase5_verdict` (a body READ that feeds the
pass-through) belongs to this gate evaluation and MUST complete before Stage 2's body write.

## Stage 1 — parallel read fan-out (only if no gate fired)

These four calls are pure, mutually-independent READs (distinct resources; none touches the body
write). Issue them concurrently and join:

```bash
gh pr diff "$PR" --repo "$REPO" --name-only &                                            # changed files
gh issue view <ISSUE_NUMBER> --repo "$REPO" --json number,title,body,labels,comments &   # linked issue
gh api "repos/$REPO/pulls/$PR/comments" --jq '.[]|{path,line,body,author:.user.login}' & # PR comments
BOT_SIGNAL=$(rl_bot_signal "$PR")                                                         # bot reviews (#688)
wait
```

**Bot-signal detail (issue #688).** `rl_bot_signal "$PR"` returns Copilot/CodeQL/Dependabot/Semgrep/`[bot]` reviews+comments (validated login + `.user.type`; drops quota/refusal stubs, #884). Normalize hits into the findings shape (conservative severity); carry `BOT_FINDINGS` into Phase 2 dispatch and Phase 4/5 aggregation (`[]` blocks nothing). `rl_diff_risk` (Stage 3) consumes it, so the bot signal must resolve first. Bot-signal detection runs only if no short-circuit/pass-through ended the dispatch — it only sizes Phase 2 (#973).

## Stage 2 — conditional body WRITE (alone, after every body reader)

`rl_ensure_closing_link` is the only Phase 1 WRITE; run it only after Stages 0–1 (which include the
body readers `rl_phase5_verdict` and the comments/issue fetch) have finished, so no read-after-write
race can hand a stale body to the pass-through gate or the verdict.

If this PR *fully* implements an issue, its body should auto-close it: `rl_ensure_closing_link "$PR"
<issue-number>` appends `Fixes #N` unless (a) a closing keyword for `#N` is already present, (b) a
deliberate non-closing reference is present (`Part of #N`, `Refs #N`, `Relates to #N`), or (c) `#N`
is labelled `tracking`/`epic` — override via `SGE_TRACKING_LABELS`. Cases (b) and (c) are issue
#2241: this is the **last** write to the body, so appending a closing keyword over a slice PR's
`Part of #N` re-creates the incident where one slice auto-closed a five-AC umbrella. It fails toward
**not** appending — an unreadable label set skips the append and warns, because a manual close is
cheap and a wrongly-closed umbrella is not. **Same-repo only** — cross-repo issues (`owner/repo#N`)
don't auto-close; note those for manual closure.

## Stage 3 — diff-risk reads (parallel; after Stage 1's bot signal)

`rl_diff_risk` and `rl_diff_trivial` are body-insensitive READs, mutually independent of each other;
`rl_diff_risk` consumes `BOT_FINDINGS` from Stage 1, so it runs after. Detail in Phase 2's
classification section.

> **Fail loudly, never silently retry (GitHub REST quota, #1147).** Any staged call on a 403/429 →
> prefer `gh api graphql` for the read and re-issue; never spin a silent retry loop that stalls the
> whole stage. A background call that fails must surface — check each `wait`ed job's status, don't
> read an empty result as "clean".

> **When in doubt, keep it sequential.** Only calls proven independent above share a stage; this
> staging must not weaken any gate or introduce a read-after-write race. A new discovery call with
> an unclear read/write set goes in its own stage until proven safe.
