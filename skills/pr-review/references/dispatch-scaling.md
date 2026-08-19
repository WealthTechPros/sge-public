# Phase 1–2 dispatch sizing — extended rationale

Reference-grade rationale and incident detail for the risk-classification, trivial-tier,
dispatch-scaling, budget, and investigation-depth rules in `../SKILL.md` Phase 2. The
actionable rules, tables, and helper calls live in the SKILL; this file records *why* they
are shaped that way. Nothing here is a new control.

## Diff risk classification & dispatch tier table (issue #688)

Extracted from `../SKILL.md`'s *Diff risk classification & dispatch scaling* section under the
35 KB budget; content unchanged. `DIFF_RISK=$(rl_diff_risk "$PR" <bot_hot>)` (`bot_hot=1` when
`BOT_FINDINGS` has a major/blocker). The `prose`/`trivial`/`generated` gates are narrower checks
run **before** `low`, in that order. Record `diff_risk` in the verdict block.

| Tier | Criteria | Dispatch | `specialist_dispatch:` |
|---|---|---|---|
| **prose** | `rl_diff_prose`=1 — docs-only (#2215) | **nothing** — Phase 2 skipped entirely | `skipped` |
| **trivial** | `rl_diff_trivial`=1 (#973) | native Layer 1 `low` only — **no specialists ever** (not even on a bot major/blocker) | `skipped` |
| **generated** | `rl_diff_generated`=1 (#1757) | regenerate-and-byte-diff replaces the correctness lane (drift = **blocker** → full review); content-safety for published artefacts | `reduced` |
| **low** + clean bot review | ≤ ~150 **raw** lines, no security path, no bot `major`/`blocker` | **skip fresh specialist dispatch**; Layer 1 `low`/`medium`, cite the bot review | `skipped` |
| **low**, no bot review | as above | Layer 1 `low`/`medium` + **one** specialist (`@code-reviewer`) | `reduced` |
| **medium** | anything not `low` or `high` | Layer 1 `high` + both bundled specialists | `full` |
| **high risk** (auth/payments/migrations/data-isolation) | a security-sensitive path, OR > ~400 **weighted** lines, OR a bot `major`/`blocker` | Layer 1 `max`/`ultra` + both bundled + matching Layer 3 — **always full regardless of bot signal** | `full` |

**Security-sensitive paths** — the one `rl_security_glob_regex` list in `review-lib.sh`
(`rl_security_files "$PR"` prints matches) drives the risk tier, `/security-review` trigger, and
`@security-auditor` dispatch. Never downgrade a `high`-risk diff on a bot review alone.

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

## `prose` tier — full mechanics (issue #2215)

`PROSE=$(rl_diff_prose "$PR")`. The **only zero-dispatch tier**: when it fires, Phase 2 runs
nothing at all — no Layer 1 native review, no bundled specialists, no repo specialists. Checked
**first**, before `trivial`.

This changes review **depth**, not the merge gate. The lane still claims `pr-reviewing`, still
runs Phase 3 CI gates and Phase 5.5 thread resolution, still posts an `sge-verdict` (with
`diff_risk: prose`, `specialist_dispatch: skipped`) and still promotes `pr-reviewed`. A
prose-tier PR is as merge-gated as any other; it just isn't read by a reviewer.

**Why it exists.** `rl_diff_trivial` (#973) fires only on a whitespace-only diff or a single-file
lockfile bump, and even then still runs a Layer 1 pass — it skips *specialists*, not the review.
#984 de-weighted doc/test lines so they stop pushing a diff into `high`, which fixed
over-*escalation* but lands doc-only diffs in `low`/`medium`, still paying for Layer 1. A
documentation-only diff has no correctness surface for a code reviewer to examine, so the
remaining gap was a tier that dispatches nothing.

### Classification — allowlist AND denylist

Returns `1` only when **every** changed file matches the allowlist **and no** changed file
matches the denylist.

- **Allowlist (extension):** `.md`, `.mdx` — **not `.txt`**, see below
- **Denylist (path), any match forces `0`**, matched **case-insensitively** and
  anchored at **any path segment** (`(^|/)`), not just the repo root:

| Path | Why it is not prose |
|---|---|
| `**/skills/**` | `SKILL.md` **is** the executable artefact — prose-as-behaviour |
| `**/agents/**` | agent definitions are behaviour |
| `**/.claude/**` | harness config that steers agents |
| `**/.github/**` | anything CI consumes — workflows, scripts, control lists |
| `**/docs/specs/**` | governance artefacts; feed the C4 coherence check |
| `**/docs/decisions/**` | ADRs; feed C7 |
| `**/CLAUDE.md`, `**/AGENTS.md` | repo instructions that steer every agent in that subtree |

**Segment anchoring, not root anchoring.** A repo can host more than one Claude
Code root, and this one does: `platform/` carries its own
`platform/.claude/agents/*.md`, `platform/.claude/skills/*/SKILL.md` (59 tracked
files) and `platform/AGENTS.md`. A root-anchored `^\.claude/` matched only the
top-level copies, so a PR editing `platform/.claude/agents/security-auditor.md`
— the security reviewer's own instructions — classified as prose and would have
merged unreviewed. `(^|/)` still refuses false positives: `myskills/x.md` and
`docs/specs-old/x.md` need a separator immediately before the segment.

**Case-insensitive on the deny side only.** On a case-insensitive filesystem
(macOS, Windows) a file committed as `claude.md` *is* `CLAUDE.md` to every tool
that opens it. The allowlist stays case-sensitive so an odd-cased extension
(`.MD`) fails closed rather than being quietly admitted.

**Why `.txt` is not on the allowlist.** It is not a prose signal in a software
repo — it is this repo's format for CI control lists, none of which read as
documentation:

- `.github/scripts/hold-labels.txt` calls itself the *"SINGLE SOURCE OF TRUTH …
  blocks EVERY merge path"*, read by both `hold-gate.yml` and
  `sge-auto-merge.yml`. A zero-dispatch PR deleting `do-not-merge` /
  `needs-human` / `blocked` disarms the human-hold gate repo-wide — **the merge
  gate's own kill-switch, edited through the gate that guards it.**
- `publish-redact-list.txt` is the rsync `--exclude-from` for the public mirror;
  dropping a line leaks whatever it redacted.
- `requirements.txt` files are `pip install -r`'d in CI — a swapped pin is code
  execution on a runner holding repo credentials.

A `.txt` extension carries no evidence that the content is prose rather than a
manifest or a policy list, so it cannot earn the zero-dispatch tier.

**The denylist is the whole point.** A naive "`.md` ⇒ skip the review" rule is wrong in this
repo and dangerously so: a large share of tracked `.md` files live under `skills/`, where the
markdown *is* the product logic. Auto-passing those would blind the merge gate to exactly the
class of change issues #2210–#2214 are about — reviewing the reviewer's own instructions.

A **mixed** diff is not prose: one non-allowlisted file, or one denylisted path, sinks the whole
PR back to normal tiering. A docs+code PR is a code PR.

**Renames count as a change to both paths.** A name-only diff with rename detection on lists
only the *new* path — `git mv skills/x/SKILL.md README.md` shows `README.md` alone, and the
`skills/` path the denylist would have caught simply disappears. Deleting a skill, an agent
definition or a spec by renaming it to a doc would otherwise be a pure-prose diff and skip review
entirely. So `rl_diff_prose` folds every `previous_filename` from the PR's files API into the set
and judges it by the same allow/deny rules, failing closed if that lookup fails.

### Fail-closed, and high-risk still wins

Fails closed to `0` on any error — the same rationale as `trivial`, but stronger, because this
tier skips dispatch **entirely**: a wrong `1` costs far more than a missed `1`, which merely
falls back to normal `low` scaling and is never a correctness gap.

It also fails closed when **any** changed file matches `rl_security_glob_regex`, the same guard
`generated` applies. A document on a security-sensitive path keeps its normal tier.

**Shell portability (#1492).** The changed-file list is read into an array split on newlines
only, never left to the caller's shell to word-split — `review-lib.sh` is sourced, and zsh does
not split unquoted parameters, which is precisely how #1492 misclassified multi-file diffs as
`trivial` and silently skipped `@security-auditor` dispatch.

### Sizing, honestly

Sampled over the last 30 merged PRs in this repo: **3** were pure prose, 6 touched
`skills/`/`agents/`, and 21 mixed code with docs. At the cost of a review, that is roughly a
**3% saving on review spend** — worth having, since the classifier is mechanical and cheap, but
it is deliberately the small, safe half. The larger cost lever is duplicated repository reading
across lanes (#2214), which recurs on nearly every PR rather than one in ten.

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
`.sge/generated-artefacts.tsv` — one TAB-separated record per line,
`<artefact-path>\t<generator-command>\t<published 0|1>`, `#`-comments and blank lines ignored.
The manifest is read from the PR's **base sha** (`git show <base>:.sge/generated-artefacts.tsv`,
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

**High risk always wins over `generated`.** A declared artefact may still sit on a
security-sensitive path (a generated auth/config/migration file). Byte-diff proves the output
matches its generator; it proves *nothing* about whether that output is safe — and unlike
`published=1`, which only gates the content-safety lane, a security-path artefact needs the
whole `high` treatment. So `rl_diff_generated` also fails closed to `0` when **any** changed
file matches `rl_security_glob_regex`: the diff keeps its normal tier, and `rl_diff_risk`
classifies it `high` on that same security match. The `generated` tier can never downgrade a
security-sensitive diff.

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

## Test-scoping convention for CLAUDE.md (issue #2267)

Phase 3 always runs the repo's quality suite in full — that guarantee is unconditional and
correct (see `trivial`/`generated` above: *"Phase 3, 4, and 5.5 still run in full"*, twice, by
design). This section is not about skipping tests; it is about giving a repo an optional way to
tell Phase 3 which of its *already-full* suite actually needs running for a given diff, so "the
full suite" doesn't silently mean "every test file in the repo, including ones that provably
cannot be affected by the change."

**The gap this closes.** `sge`'s own `CLAUDE.md` (2026-08-17, before this fix) had no
test-command section for its `skills/tests/*.test.sh` BDD suite at all. Phase 3's instruction —
*"run the repo's quality suite (commands in CLAUDE.md)"* — had nothing authoritative to follow,
so the reviewing agent improvised: a `for t in skills/tests/*.test.sh; do timeout 120 bash "$t"
...; done` loop over all 127 files, serially, to review a 6-file, ~290-line PR touching one
script. Not a Phase 3 bug — Phase 3 correctly deferred to `CLAUDE.md`; the bug was `CLAUDE.md`
having nothing to defer to, and the agent filling that gap with the worst case instead of asking.

**The convention.** A repo MAY declare `test-scope:` marker lines in its `CLAUDE.md` — the same
HTML-comment, script-parsed marker family `tidy-worktrees`'s `rescue-guard.sh verify` already uses
(`rescue-verify:<stage>:`), not a prose table: this is deliberately the *inverse* of an
unstructured "discoverable" block, because unstructured prose parsed per-reviewer is the same
ambiguity class that caused #2267.

```markdown
<!-- test-scope: skills/pr-review/ -> skills/tests/pr-review-*.test.sh -->
<!-- test-scope: skills/worktrees/ -> skills/tests/worktrees-*.test.sh -->
<!-- test-scope: scripts/         -> skills/tests/scripts-*.test.sh -->
```

Each line is `<!-- test-scope: <source-prefix> -> <covering-test-glob> -->`, one prefix per line,
mechanically grep-able — no "equivalent structured block" latitude. A repo declares this once and
every skill that needs "run the tests that matter for this diff" (not just `pr-review`) reads the
same lines instead of inventing its own detection heuristic.

**How Phase 3 uses it, mechanically.**

1. Grep the repo's `CLAUDE.md` for `test-scope:` marker lines.
2. **No markers at all** → skip to step 4 (full-suite path).
3. Markers present: for each changed file, match its path against the declared prefixes; union
   the covering test globs across all changed files, then **expand each glob against the actual
   tree**. Run the scoped set only if **all** of: (a) every changed file matched a declared
   prefix, (b) the unioned glob expansion is **non-empty** — an empty expansion (a prefix with no
   files matching its glob, e.g. a stale/typo'd row) is treated identically to "unmatched" and
   falls through to step 4, and (c) no changed file falls under a matched prefix while also being
   outside every one of that prefix's declared globs (a matched-but-incomplete row) — a repo
   declaring `skills/pr-review/` only covers exactly the files its glob(s) resolve to; a file in
   that directory not covered by any declared glob for it is treated as unmatched, not scoped.
   Record `quality_gates_scope: scoped`.
4. **Full-suite path.** If `CLAUDE.md` documents a full-suite command, run it exactly as written
   and record `quality_gates_scope: full`. If it does not (no test-command section at all —
   #2267's actual root cause), do **not** brute-force every test file in the repo: discover the
   test suite's own convention (e.g. a single `skills/tests/*.test.sh` glob, a `run-tests.sh`
   entry point), bound the run to what that discovery finds, and record
   `quality_gates: not-run` with `quality_gates_scope: undeclared` plus the reason in the
   verdict — never silently substitute a full-repo loop for a documented command that doesn't
   exist.

This is the same fail-closed doctrine `trivial`/`generated`/`prose` already use elsewhere in this
file: any ambiguity — unmatched file, empty expansion, incomplete row, or no markers — resolves to
running more, never less. A wrong "scoped" run that misses a real regression costs far more than
an unnecessary full run.

**What this does NOT change.** Phase 3 still runs unconditionally at every diff-risk tier,
including `trivial` and `generated` — this section only affects *how much* of the suite that
unconditional run covers, never *whether* it runs. A repo with no `test-scope:` markers sees no
behavior change versus a documented full suite (falls back to it, exactly today's behavior) —
this is additive and opt-in, not a default that could silently under-test an unprepared repo.

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
