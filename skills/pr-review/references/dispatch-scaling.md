# Phase 1–2 dispatch sizing — extended rationale

Reference-grade rationale and incident detail for the risk-classification, trivial-tier,
dispatch-scaling, budget, and investigation-depth rules in `../SKILL.md` Phase 2. The
actionable rules, tables, and helper calls live in the SKILL; this file records *why* they
are shaped that way. Nothing here is a new control.

## Why the short-circuits run before bot-signal detection (issue #973)

The concurrency short-circuit and the delta-mode / Phase-5-passthrough checks in Phase 1 are
the cheapest, highest-leverage tests in the whole skill — each can end the dispatch outright
(no-op report, re-assert-and-stop, or Phase-2-skip). Bot-signal detection exists **solely to
size Phase 2's fresh dispatch** (issue #688) — it has no other consumer. When pass-through
applies (or a no-op/re-assert short-circuit already stopped the dispatch), Phase 2 never runs,
so bot-signal detection's only consumer never runs either, and the two paginated `gh api`
calls it makes were pure waste. Running the short-circuits first — and only reaching
bot-signal detection once neither applies — avoids that waste on the common pass-through/no-op
path without changing any of the detection logic itself (pure reordering, same calls, fewer
wasted ones).

## Bot-signal detection detail (issue #688, #884)

`rl_bot_signal` requires both a word-boundary login match AND `.user.type == "Bot"` (the login
string is attacker-controlled; the account type isn't). It **drops quota-limit/refusal stubs
(issue #884)** — a Copilot review whose body is literally "unable to review — quota limit
reached" (or a "rate limit" / "wasn't able to review" variant) is zero opinions, not a clean
pass, so it is excluded from `BOT_SIGNAL` and the diff falls back to the normal
specialist-dispatch tier for its risk level. Normalize each surviving hit into the Phase 2
structured-findings shape — `{file, line, severity, category, finding, suggestion}` —
inferring severity conservatively from the bot's own words (default `minor`; `major`/`blocker`
only for a concrete bug/vulnerability claim). `BOT_FINDINGS: []` is normal and blocks nothing.

## Test/doc-weighted line count for the `high` leg (issue #984)

Raw `additions + deletions` over-counts review surface on a diff that is mostly new tests, BDD
fixtures, or spec prose — exactly the shape `client-onboarding`'s own BDD-First Rule and
Verify-Before-Done conventions encourage alongside every fix, so a healthy test/doc-to-code
ratio shouldn't itself trip full specialist dispatch. Only the `> ~400 changed lines` leg of
`high` uses the weighted count; the security-glob match and the bot-major/blocker leg are
unconditional and unchanged, and the `low` tier's `≤ ~150` threshold still uses the raw count.
`rl_diff_weighted_lines "$PR"` prints `"<weighted> <raw>"`: `weighted` = raw minus the
additions+deletions of every changed file matching `rl_test_doc_glob_regex` — `**/*.test.ts`,
`**/*.spec.ts`, `**/__tests__/**`, `**/*.feature`, `**/steps/**`, `docs/**` — derived from one
extra cheap `gh pr view --json files` call, no new tool. `rl_diff_risk` calls this internally;
callers never need to invoke it directly. **Fails closed:** any fetch/parse failure on the
per-file breakdown falls back to `weighted == raw`, so a diff that can't be weighted is never
silently downgraded out of `high`.

## `trivial` tier — full mechanics (issue #973)

`TRIVIAL=$(rl_diff_trivial "$PR")`. Only ever `1` when the diff is **provably non-semantic** by
one of two mechanical (not heuristic) tests — fails closed to `0` (never-trivial) on any
fetch/parse error, since a wrong `1` skips specialist dispatch entirely while a missed `1` just
falls back to normal `low`-tier scaling:

1. **Whitespace-only diff:** `git diff -w -b` between the PR's base and head, scoped to the PR's
   own changed files, leaves nothing. This is git's own whitespace-aware diff algorithm, not a
   text heuristic — it never fires on a diff that pairs a comment with a real logic change (e.g.
   the `#973`-referenced client-onboarding#2207: a 10-line SQL logic fix with an explanatory
   comment is correctly **not** trivial, because the logic hunk survives `-w -b`). A diff that
   is genuinely all reformatting/whitespace is the only thing that clears this bar.
2. **Single-file dependency-lockfile change with a passing check:** exactly one changed file, its
   basename matches a lockfile (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`,
   `Gemfile.lock`, `poetry.lock`, `Cargo.lock`, `go.sum`, `composer.lock` —
   `rl_lockfile_glob_regex`), AND at least one check on the PR head has already reported
   `SUCCESS`.

`trivial` → **native Layer 1 at `low` effort only, no specialist dispatch regardless of bot
signal** — narrower than the "low risk + clean bot review" skip path, which still requires an
*existing* bot review to qualify; `trivial` needs no bot review at all (a diff that passes the
`trivial` gate has no semantic content for a bot to have found anything real in).
`specialist_dispatch: skipped`, `diff_risk: trivial`. **Phase 3, 4, and 5.5 still run in full**
— those are cheap and PR-specific (quality gates, requirements traceability, thread
resolution), not diff-content-scaled, so `trivial` never skips them. The Phase 5 pass-through,
when it applies, still takes precedence over this whole section (a pass-through PR never reaches
diff classification at all).

## `generated` tier — full mechanics (issue #1757)

`GENERATED=$(rl_diff_generated "$PR")`. A companion to `trivial`: it downgrades not
*non-semantic* diffs but *mechanically-reproducible* ones. A generated artefact — the tracked
output of a tracked generator — is verified far more cheaply and reliably by **regenerating it
and byte-diffing** than by line-by-line code review. The measured case (wtp-org#535): a 569-line
generated `field-explorer.html` classified `high` on line count drew ~140k subagent tokens, and
the single check that actually established correctness was re-running the generator and byte-
diffing (exact match, zero drift). This is **not** "review generated files less" — the security
lane on that same PR found a real content leak; it is "review them for the *right* thing".

**Classification (`rl_diff_generated`, mechanical, no code execution).** Returns `1` only when
**every** changed file is a generated artefact **declared in the base-ref manifest**
`.sgd/generated-artefacts.tsv` — one TAB-separated record per line,
`<artefact-path>\t<generator-command>\t<published 0|1>`, `#`-comments and blank lines ignored.
The manifest is read from the PR's **base sha** (`git show <base>:.sgd/generated-artefacts.tsv`,
`MSYS_NO_PATHCONV=1` on git-bash), **never the PR head** — so a PR cannot add a manifest entry
for its own changed file to earn the cheaper path; the declaration must already exist on the
target branch. That "cannot self-declare" guarantee only holds when the base ref is itself
review-gated, so the classifier additionally requires the PR to target the repo's **default
branch** (`.base.ref == .default_branch`); a PR targeting any other branch falls back to `0`
rather than trust a manifest at a potentially ungated ref. **Fails closed to `0`**
(never-generated) on any fetch/parse error, an
absent/unreadable manifest, an empty diff, or **any** changed file not declared — so an
unverifiable "generated" file is never downgraded (acceptance criterion 4). Requires CWD inside
a clone of the PR's repo with the base sha reachable; a non-clone caller falls back to `0`.

**Dispatch for a `generated` diff.**

1. **Correctness by reproduction, not line-reading.** For each declared artefact, read its
   generator command and `published` flag with `rl_generated_manifest_lookup "$PR" <path>` (the
   same TRUSTED base-ref manifest the classifier used — never hand-parse the TSV), run that
   generator command and byte-compare the result against the committed file (modulo
   documented line-ending normalisation). An exact match settles correctness — **replace** the
   `@code-reviewer` correctness lane entirely. A **byte mismatch (drift) is a blocker**, and the
   diff **falls back to the full normal-tier review** (drift means the committed output no longer
   matches its generator — a real defect, or an out-of-band hand-edit that must be reviewed as
   source).
2. **Content-safety is never skipped for published artefacts (non-negotiable — wtp-org#535).**
   When any changed artefact carries `published=1` (client-facing / published output), the
   content-safety lane — `/security-review` + `@security-auditor` scoped to the artefact content
   (redaction / PII / secrets / de-redaction / exfiltration) — **runs regardless** of the
   generated classification. Byte-diff proves the output *matches the generator*; it says nothing
   about whether the generator emitted something it shouldn't publish.
3. **The generator keeps its own tier.** If the diff also touches the generator (or any file not
   declared as an artefact), `rl_diff_generated` returns `0` and the diff is classified by the
   normal `low`/`medium`/`high` rules — semantic risk lives in the generator's diff, and it is
   reviewed there at its own tier (acceptance criterion 3).

Like `trivial`, this extends the `rl_diff_trivial` "provably non-semantic ⇒ cheaper path"
doctrine (whitespace-only / single-lockfile) — here "provably reproducible ⇒ verify by
reproduction". **Phase 3, 4, and 5.5 still run in full**, and the Phase 5 pass-through, when it
applies, still takes precedence over the whole classification.

## Per-tier budget (issues #688, #888)

Wall-clock / tokens / ~tool-calls per tier: **trivial** 2min/15k/5 · **generated** 4min/25k/12 (the regenerate-and-byte-diff run plus a conditional content-safety lane — bounded well below a full correctness review) · **low** 5min/50k/15 · **medium** 10min/150k/40 · **high** 20min/400k/80.

## Budget-exhaustion behaviour (issues #688, #888)

On budget exhaustion: **stop waiting** on outstanding lanes (never extend silently), **report
partial results**, and **explain the gate decision** in the verdict rather than guessing —
record `budget_exceeded: true`, `partial: true`. A budget-exhausted high-risk review is
**never** silently promoted to `pass` on missing lanes — treat it as failed/incomplete
(`pr-labels.sh fail`) unless the lanes that returned clear every Phase 4 requirement on their
own.

## Investigation depth & pragmatism guardrails (issue #888)

`DIFF_RISK` sets the **investigation-depth (effort) tier up front** — mirroring `/code-review`'s
low→ultra effort ladder across the three risk tiers (`high` risk escalating Layer 1 to
`max`/`ultra`) — before any Phase 2 spend, never discovered by drifting deeper mid-review. The
tier governs *investigation depth* (how far verification goes beyond the diff itself), distinct
from the Layer-1 `/code-review` effort parameter the dispatch scaling sets; the budget table is
the tier's spend envelope, so the dispatching agent can pick the right tier from PR size/risk
alone. Default tier (`low`/`medium` risk): **fewer, high-confidence findings scoped to the
diff**; reserve **deep multi-source verification only** for `high`-risk / risk-flagged PRs
(security-sensitive paths, a live/regulated data store, a "production-sensitive" marker, or a
PR-body claim with no accompanying test). At every tier, strip the overhead that adds no signal:

- **Trust the PR's own tests first.** Read them once, judge them sound: a claim the PR's own
  test suite mechanically proves needs no independent re-derivation. Escalate to
  vendor/third-party/upstream-source verification **only** when no test in the PR covers the
  claim.
- **Scope every grep/search to the diff's surface by default** — the files touched by the diff
  plus directly linked docs/issues, never a bare repo-wide sweep; always exclude vendored
  dependency trees (`node_modules`, `venv`/`site-packages`, `vendor`).
- **Read targeted excerpts, not files end-to-end** — pull the relevant section (Read
  offset/limit, `git diff` hunks) instead of paging whole large files through context.
- **Windows/git-bash:** raw `git` args containing `:` (e.g. `git show <ref>:<path>`) need the
  `MSYS_NO_PATHCONV=1` prefix — see the raw-git pitfall note in [`gh-repo`](../../gh-repo/SKILL.md);
  don't rediscover it per session.

This never makes a genuinely production-sensitive PR shallower — `high` risk always gets the
full deep pass; the guardrails cut avoidable overhead, not risk-driven depth.
