# `sge-verdict` Block Schema

**Canonical source.** This document is the single source of truth for the fenced
`sge-verdict` block that `/sge:pr-review` emits and every gate/consumer parses.
Any parser implementation, future consumer-repo variant, or dashboard MUST be
implemented against this shape.

Related: `docs/review-independence-gate.md` (SGE source repo),
[`skills/pr-review/SKILL.md`](../../skills/pr-review/SKILL.md) §Phase 5.

---

## Fence Grammar

- The block is a **fenced code block** (` ``` ` or `~~~`, 3+ characters,
  CommonMark closing-fence rules) whose **info string is exactly `sge-verdict`**
  (case-insensitive), e.g. ` ```sge-verdict `.
- A review body with **more than one** such fence opener is ambiguous and MUST
  be treated as **unparseable** — it never yields a usable verdict. For the
  `gate-labels` readers and the daemon's arming gate an unparseable body from a
  trusted verdict node is a **blocking** `malformed` candidate (see [Clean
  verdict body](#clean-verdict-body-the-gate-labels-readers-and-the-daemons-arming-gate));
  the older readers (`check-review-independence.sh`, `review-lib.sh`) simply
  take no verdict from it. A naive first-fence parse is spoofable by a decoy
  fence placed before the real one; a multi-fence body fails closed, not open.
- Prose that merely *mentions* the string `sge-verdict` — outside a real fence,
  or inside an ambiguous multi-fence body — is **never** treated as a verdict.
  This is a positive requirement, not an implementation detail: any future
  rewrite of a parser must preserve it.
- Fence indented 4+ spaces (an indented code block, not a fence), nested inside
  an outer unrendered fence, or hidden inside an HTML comment is **not** a
  candidate (bypass 10).
- Fences follow CommonMark exactly (sge#2808, the five forgery variants found
  against PR #2800): an opener or closer is indented by **0-3 spaces** only (a
  tab, `\f` or `\v` is not fence indentation); a closer is a run of the
  opener's character at least as long, followed **only by spaces or tabs**
  (`` ```\v `` does not close); the info string is padded only by spaces or
  tabs (`` ```sge-verdict\f `` is not an `sge-verdict` fence). A fence inside a
  `<pre>`, `<script>`, `<style>` or `<textarea>` HTML block is content too.
- A body that **ends with a fence still open** is malformed: never a usable
  verdict (a blocking `malformed` candidate for the `gate-labels` readers and
  the arming gate, as above). That is the trace a bare ` ``` ` echoed into a wrapped block leaves
  when it breaks the wrapper open and turns the wrapper's own closer into an
  opener (bare-fence breakout).

### Clean verdict body (the `gate-labels` readers and the daemon's arming gate)

The head-scoped gate-label readers (`gate-labels.sh`, `gate_labels.py`) and the
review daemon's merge-arming gate read a verdict only from a **clean** body.
The rules close the forgeries the PR #2800 skeptic review found against the
first sge#2808 fix (absorbing the reviewer's own fence, swallowing it with an
echoed `<!--`/`<pre>`, parity shifts). A body is clean only when **all** hold:

- exactly **one** line in the whole body looks like an `sge-verdict` opener
  (a ` ``` ` or `~~~` run followed anywhere later on the line by
  `sge-verdict`, case-insensitive), and that line opens the one top-level
  `sge-verdict` fence. A second opener-shaped line anywhere -- top level,
  nested, indented, mid-line -- makes the body ambiguous;
- the body ends at top level: no fence, HTML comment or raw HTML block
  (`<pre>`, `<script>`, `<style>`, `<textarea>`) left open;
- the verdict fence is the **last** block: only blank lines follow its closer
  (`/sge:pr-review` Phase 5 and the daemon always end the body with it);
- inside the fence there is no ` ``` ` or `~~~`, and at most one `verdict:`,
  `commit:`, `sha:` and `head:` line each;
- a closer is compared by run **length**, never a counted `{N,}` regex (gh's
  gojq/RE2 rejects counts above 1000); every pattern uses explicit ASCII
  classes, never `\s` or a case-insensitive flag, so jq, gojq and Python agree
  (Python's `re.IGNORECASE` folds `ı`/`İ`/`ſ` onto ASCII letters).

A trusted verdict node (below) that does **not** parse cleanly is not skipped:
it is a **blocking candidate** (`verdict: malformed`, no SHA), which classifies
`unproven` and, as the newest verdict, shuts every merge gate. Skipping it
would let echoed text erase a newer `fail` and resurface an older `pass`. The
price is fail-closed: a review that quotes an `sge-verdict` fence (for example
when reviewing a change to this schema) needs a fresh review or a human.

---

## Trusted verdict sources

A well-formed fence is a verdict only when the **review identity** posted it
(sge#2808):

- **Who.** The `wtp-sge` App (`wtp-sge[bot]`), or, when
  `REVIEW_DAEMON_TRUSTED_VERDICT_AUTHORS` is set, only the logins it pins (the
  allow-list is then the sole authority). `github-actions[bot]` and
  `OWNER`/`MEMBER`/`COLLABORATOR` association are **not** verdict sources:
  any workflow posts as `github-actions[bot]`, and qa-audit reports and
  fix-lane comments post under the operator's own account, so either could
  echo a forged fence. A solo-profile operator whose reviews post under their
  own login must pin that login -- see [Pinning the verdict
  authors](#pinning-the-verdict-authors).
- **Which shapes.** The review identity's **formal PR reviews** (not
  `PENDING`; a `DISMISSED` one is a withdrawn verdict -- see [Dismissed
  Reviews](#dismissed-reviews)) that contain an `sge-verdict` opener, and its
  **issue comments whose FIRST line is the review-verdict marker**
  `<!-- sge-review-verdict -->` (trailing spaces/tabs allowed). The marker is
  a public constant, so it counts only on line 1, where
  `rl_verdict_mark_body` writes it: a marker echoed anywhere else (quoted
  output, a pasted comment) never marks a comment. `/sge:pr-review` adds the
  marker on every comment-route verdict (advisory, draft and hold:
  `rl_post_verdict_comment`). Any other comment by the same identity --
  findings, claims, qa-audit reports, fix-lane notes -- does not start with
  the marker and is never a verdict.
- **Never edited.** A verdict node -- marked comment **or review** -- edited
  after it was posted is a blocking candidate: neither `/sge:pr-review` nor the
  daemon edits a verdict it posted, and anyone with write access can edit a
  comment or review (PR #2800 skeptic review round 2, sge#2803 item 1). The
  edit stamp is GraphQL `lastEditedAt` (null until an edit, at any precision),
  so `gl_latest_verdict` reads reviews and comments through GraphQL: REST
  `/pulls/N/reviews` carries no edit stamp at all, and a REST comment's
  `updated_at` is second-precision (an edit inside the posting second reads as
  unedited). A REST-shaped node is also edited when `updated_at` !=
  `created_at`. The daemon's arming gate alone still accepts an edit whose
  GraphQL `editor` is a trusted verdict identity (its own login or a pinned
  one).
- **State agrees.** A `CHANGES_REQUESTED` review whose fence says `pass` is a
  blocking candidate: the two disagree, so echoed text was read as the verdict.
- **Never** the PR's own author, whatever the login.

The newest trusted verdict across both sources wins (sge#2729 item 2).

### Pinning the verdict authors

`REVIEW_DAEMON_TRUSTED_VERDICT_AUTHORS` is a comma-separated list of GitHub
logins, compared case-insensitively against the REST form of the author
(`<slug>[bot]` for an App). The same rule applies in every reader:
`gate-labels.sh` (`GL_TRUST_FILTER`, under jq and gh's gojq) and the review
daemon (`verdict_trust.trusted_verdict_authors`).

- **Where it is read.** The review daemon reads it from its own environment.
  The GitHub Actions merge-path workflows -- `sge-auto-merge.yml` (the
  `gate-labels.sh current` gate) and `pr-reviewed-staleness.yml`
  (`pr-labels.sh sync-check`) -- read it from the repo or org **Actions
  variable** of the same name (`vars.REVIEW_DAEMON_TRUSTED_VERDICT_AUTHORS`).
  Set the variable only if your reviews do not post as `wtp-sge[bot]`; the
  daemon and the Actions variable must then pin the same logins, or the two
  merge paths disagree.
- **Optional.** The variable is optional. Unset, empty, or only separators,
  spaces and tabs (an unset Actions variable expands to `""`), it is no
  allow-list at all and the default applies: `wtp-sge[bot]` only. It never
  falls back to "trust nobody" or "trust everyone".
- **Parsing.** Split on `,`; trim ASCII space and tab only (never Unicode
  whitespace such as NBSP, so jq, gojq and Python agree); drop empty items;
  lower-case ASCII only. Each remaining item must equal a login exactly:
  there are no wildcards, globs, regexes or prefix matches, so `*` is just a
  login nobody has. A non-empty list is the **sole** authority -- it replaces
  `wtp-sge[bot]` rather than adding to it, so list the App too if it still
  reviews. An item that matches no real login (a typo, `*`, an NBSP-padded
  name) trusts nobody for that item; it can never widen trust beyond the
  listed logins.

---

## Fields

One `key: value` per line inside the fence. All 31 fields below are emitted by
`/sge:pr-review`; two are additionally required by the independence gate.

```sge-verdict
verdict: pass | fail
recommendation: APPROVE | REQUEST_CHANGES | COMMENT
pr: <number>
commit: <full 40-hex HEAD SHA reviewed; the merge gate treats a short SHA as unproven>
reviewed_at: <ISO-8601 UTC>
plugin_ref: <sge plugin version/ref the reviewing environment has installed>
mode: full | delta | phase5-passthrough | advisory | shadow | approval-carried
session: <review session id>
blockers: <count>
majors: <count>
minors: <count>
traceability: SPEC-NNN | <capability-id> | untraceable
quality_gates: pass | fail | not-run
quality_gates_scope: scoped | full | undeclared
qa_evidence: <comment-url> | none | stale@<sha> | stale@unknown
unresolved_threads: <count>
tool_call_count: <count>
diff_risk: prose | trivial | generated | low | medium | high
specialist_dispatch: skipped | reduced | full
review_tier: light | standard | full
review_tier_reason: <one line from review-tier.sh>
bot_findings_folded: <count>
findings_comment: <comment-url> | inline | none
budget_exceeded: true | false
rescued_env: true | false
hold_active: true | false
held_for_human: true | false
head_moved: true | false
control_bearing: true | false
oracle_bearing: true | false
applied_order: <id>[,<id>...] | none
```

### Required vs optional

| Requirement | Fields |
|---|---|
| **Required by the independence gate** (fails closed if absent) | `verdict`, and one of `commit` / `sha` / `head` |
| **Always emitted by `/sge:pr-review`** | all 31 fields above |

Unrecognised fields are ignored by existing parsers; do not remove or rename
existing fields without updating both parser implementations (see
[Implementations](#implementations) below).

### Field notes

**`verdict`** — `pass` satisfies the independence gate (case-insensitive);
`fail` does not. Hedged values such as `pass-with-blockers` do not satisfy the
gate (bypass 12).

**`recommendation`** — maps to the GitHub review event: `APPROVE`,
`REQUEST_CHANGES`, or `COMMENT`. Independent of `verdict` (a `fail` verdict
posts `REQUEST_CHANGES`; a `pass` verdict posts `APPROVE`).

**`commit` / `sha` / `head`** — SHA-binding (SPEC-116, issue #2231). Checked
in that precedence order; the first one present wins. The value is compared
case-insensitively against the PR's live head SHA using a **prefix match of at
least 7 hex characters** (short-SHA tolerant). Rules:

- **Absent** → fails closed; contributes no candidate regardless of `verdict`.
- **Present, < 7 hex characters** → rejected as ambiguous; contributes no
  candidate.
- **Present, ≥ 7 hex characters, does not match** → fails closed with a
  distinct `stale-sha` diagnostic naming the mismatch.
- **Present, ≥ 7 hex characters, matches** → proceeds to identity/association
  checks.

A verdict genuinely reviewed at commit A must not silently validate later
commits B, C, …

**`review_tier` / `review_tier_reason`** — sge#2776. The review DEPTH
`skills/pr-review/review-tier.sh` chose mechanically from the whole PR diff
(by path), and its one-line rule. Depth
only: a `light` pass still posts this block and still promotes `pr-reviewed`
exactly as `standard`/`full` do; no gate reads either field.

**`plugin_ref`** — SPEC-121 Phase 2 (issue #2419). The `version` field of the
reviewing environment's own installed `sge` plugin (`.claude-plugin/plugin.json`
in the plugin's marketplace checkout), e.g. `v4.34.6`. **Self-attested** — the
reviewing environment reports its own value honestly at post-time; the gate
does not independently verify it (a compromised environment could misreport).
Checked by `check-review-independence.sh` against `SGE_REVIEWER_CURRENCY_FLOOR`
and recorded as one of `plugin-ref-current` (at/above floor), `plugin-ref-
stale-reviewer-environment` (below floor), or `plugin-ref-unattested` (field
absent) — a **diagnostic signal only**, distinct from `verdict`/SHA-binding
outcomes and never blocking an otherwise-qualifying candidate (invariant I2).
Composes with Phase 1's fail-loud unrecognized-token hardening as defense in
depth: a stale-but-honestly-reporting environment is visible here; a
non-conforming one is caught there. A value that isn't a plain (optionally
`v`-prefixed) dot-separated numeric string — including a malformed/garbage
value or a pre-release suffix like `v4.31.1-beta` — is treated as
`plugin-ref-unattested` rather than compared: the comparison is `sort -V`
lexicographic ordering, not full semver, so it has no reliable pre-release
precedence to fall back on.

**`mode`** — the review mode the verdict was produced under. `shadow` (issue
#2651; documented here per #2657) marks a PR Warden
`/sge:pr-review --shadow` dispatch: the review ran in full, but its terminal
transition is `pr-labels.sh shadow-pass` (applies `agent-reviewed`), never
`pass` — a shadow verdict must never be the reason a PR gets `pr-reviewed` or
auto-merge. Consumers treat a `mode: shadow` verdict (match the substring, so a
`<mode> (shadow)` suffix also counts) as **not** satisfying the merge gate:
`pr-labels.sh pass` refuses when `SGE_REVIEW_SHADOW=1` (exit 9) and when the
latest trusted verdict at the current head is a shadow one (exit 10, #2653).
That second, verdict-laundering guard is currently GitHub-only — skipped on
Forgejo hosts until the adapter can read PR comments (#2657).

**`approval-carried`** — posted by PR Warden itself,
never by a model: the head is a clean update from the base branch of a commit
that already had a trusted PASS (a two-parent merge whose first parent is that
commit, whose second parent is on the base branch, and whose three-dot diff has
the same patch content). It carries `verdict: pass`, `commit: <new head>`,
`carried_from: <reviewed commit>` and `base_commit: <merged base commit>`, so
head-scoped label readers (`sync-check`, `gate-labels`) read it as current. The
daemon's merge gate accepts it only when the `carried_from` chain reaches a
`full` pass through earlier trusted verdicts
(`services/review-daemon-poc/approval_carry.py`).

**`unresolved_threads`** — must be `0` for a `pass` verdict; `pr-labels.sh
pass` refuses while any remain.

**`tool_call_count`** — Phase 2 review tool-call count; `0` in
`phase5-passthrough` mode.

**`hold_active`** — `true` when a `needs-human` / `do-not-merge` / `blocked`
label or `sign-off-pending` comment is present; routes the skill to advisory
mode.

**`held_for_human`** — `true` when `pr-labels.sh apply-hold` was called (HOLD:
marker or security MAJOR); the gate refuses and exits 8.

**`head_moved`** — `true` when the PR's head SHA moved between Stage 0 (the
review's starting point) and the posted verdict (#2214 ask 4). Signals that
the reviewed diff and the currently-live diff may have diverged mid-review —
the verdict still binds to the `commit`/`sha`/`head` SHA it names, but a
consumer should treat `head_moved: true` as a prompt to re-check for a
newer, unreviewed head before trusting the verdict as current.

**`control_bearing`** — `true` when `rl_diff_control_bearing` (issue #2211)
classified this diff as touching an enforcement mechanism — a CI gate script,
static audit/scanner, or policy/allowlist file — mixed-diff triggered (one
matching file among many still sets it `true`). When `true`, Phase 4.3a
requires current adversarial `qa-audit --adversarial` evidence as a hard
blocker rather than the advisory treatment every other tier gets.

**`oracle_bearing`** — `true` when `rl_diff_oracle_bearing` (issue #2222)
classified this diff as touching a test oracle, domain invariant, or
fixture-generation rule — a snapshot file, fixture directory entry, or file
explicitly named `*oracle*`/`*invariant*` — mixed-diff triggered. When `true`,
Phase 4.3b applies the three-question oracle-derivation lens; a failing answer
emits a `major` finding rather than the hard BLOCKER the adversarial tier uses
(an oracle-derivation check CAN succeed inline without a separate runtime pass).

**`session`** — the reviewing session's id (`SGE_REVIEW_SESSION_ID`, else the Claude Code
session id). Informational for gate parsers, but a delegation-policy hold release
(`pr-labels.sh release-hold`) only counts a clean verdict whose `session:` is the releasing
session's and not the session that applied the hold (sge-public#71 review M2).

**`applied_order`** — the id(s) of every delegation-policy standing order this review applied
(e.g. a hold released under a hold-release order, or an unverifiable-approval finding satisfied by
a recorded approval), comma-separated, or `none`. Informational: gate parsers read `verdict:` /
`commit:` only and tolerate it. Detail: `skills/pr-review/references/delegation-policy.md`.

---

## Dismissed Reviews

A review whose `.state` is `DISMISSED` is **withdrawn evidence**: it is
**never** a pass, regardless of its body content. A `PENDING` review is
unsubmitted and is not a verdict at all (it has no `submittedAt`).

- The `gate-labels` readers (`gate-labels.sh`, `gate_labels.py`) and the
  daemon's arming gate read a trusted dismissed verdict review as the
  candidate `(its commit, verdict: dismissed)` (or `malformed` when its body is
  not clean). It is **not skipped**: skipping it would let a dismissal of the
  newest trusted `fail` resurface an older `pass` at the same head (PR #2800
  skeptic review round 2). A dismissed verdict at an old head still classifies
  `stale`, so the push-time writer strips as before; at the current head it
  blocks every merge gate (not a pass), and the daemon's review selection
  re-selects the PR for a fresh review.
- The older readers (`check-review-independence.sh`, `review-lib.sh`) take no
  verdict from a dismissed review.
- Not covered: **deleting** a newer marked verdict comment leaves no trace in
  the API, so a write-access identity can still resurface an older verdict
  that way. A deletion needs write access, never yields a newer pass, and
  `gate-labels.sh current` still demands a pass bound to the exact head.

---

## Implementations

These implementations parse this grammar:

| File | Function(s) | Used by |
|---|---|---|
| `.github/scripts/check-review-independence.sh` | `verdict_scan` | CI gate (`require-pr-reviewed-label.yml`) |
| `skills/pr-review/review-lib.sh` | `rl__verdict_block`, `rl__verdict_fence_count` | `/sge:pr-review` skill |
| `skills/pr-review/gate-labels.sh` | `GL_VERDICT_JQ`, `GL_TRUST_FILTER`, `gl_latest_verdict` (GraphQL read via `GL_GQL_REVIEWS` / `GL_GQL_COMMENTS` / `GL_GQL_REST`) | head-scoped gate labels: `sge-auto-merge.yml` (`current`), `pr-labels.sh sync-check` |
| `services/review-daemon-poc/gate_labels.py` | `verdict_block`, `verdict_fields`, `verdict_from_body`, `node_verdict`, `verdict_author_trusted`, `latest_verdict` | review daemon (PR Warden) review selection |
| `services/review-daemon-poc/github_adapter.py` | `trusted_verdict_fences` (via `gate_labels.node_verdict` / `verdict_fields`), `self_armed_head` | daemon merge-arming / disarm gate (SPEC-090 gate 5: `merge_verdict_block_reason`, `live_merge_gate_reason`, approval carry) |
| `services/review-daemon-poc/github_adapter.py` | `_parse_sge_verdict_block` (flat first-match) | the daemon's other readers -- `_has_fail_verdict_at_head`, `_has_shadow_verdict_at_head`, `_find_trusted_verdict_block`, `read_artefact_verdict` -- **not yet aligned** (association trust + flat parser; tracked in sge#2803 item 9) |

All implement the same fence grammar (info string, multi-fence-is-ambiguous,
state-machine parse). A future change to the grammar — new required field, new
ambiguity rule — must update **every** implementation. The two `gate-labels`
twins also implement [Trusted verdict sources](#trusted-verdict-sources), the
CommonMark fence rules and the [clean verdict body](#clean-verdict-body-the-gate-labels-readers-and-the-daemons-arming-gate)
rules above, and `skills/tests/gate-labels-parity.test.sh` runs both over one
fixture table, `skills/pr-review/gate-labels.verdict-fixtures.json`, with a
case for each sge#2808 forgery variant and each PR #2800 skeptic case, under
jq and gh's own gojq engine (`GL_TEST_GOJQ`, or `gojq` on PATH; Skills CI
installs gojq and sets `GL_REQUIRE_GOJQ=1`, so a missing gojq fails the suite
there instead of skipping). The daemon's
merge-arming gate reads fences through the same `gate_labels` functions. `check-review-independence.sh` and `review-lib.sh`
still use their own, older fence scans and trust rules (not yet aligned to
sge#2808). Do not merge the scripts into a single shared library without a
dedicated refactor issue; that is a larger change than this schema doc
authorises.

---

## Example

````markdown
```sge-verdict
verdict: pass
recommendation: APPROVE
pr: 2291
commit: a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2
reviewed_at: 2026-08-19T10:00:00Z
mode: full
blockers: 0
majors: 0
minors: 1
traceability: SPEC-114
quality_gates: pass
quality_gates_scope: full
qa_evidence: none
unresolved_threads: 0
tool_call_count: 12
diff_risk: low
specialist_dispatch: full
review_tier: standard
review_tier_reason: not light-eligible: skills/pr-review/SKILL.md
bot_findings_folded: 3
findings_comment: https://github.com/WealthTechPros/sge/pull/2291#issuecomment-0
budget_exceeded: false
rescued_env: false
hold_active: false
held_for_human: false
head_moved: false
control_bearing: false
oracle_bearing: false
```
````
