# Review mode selection (Phase 1)

Reference for `/sge:pr-review` Phase 1 — the two mode-selection branches
evaluated once, after Stage 0's gates and before the gate claim. Extracted
from `SKILL.md` under the 35 KB skills-ci size budget (the #1353/#1469
progressive-disclosure pattern); content unchanged.

Both decide **which** review this run performs (`full` / `delta` /
`phase5-passthrough`); neither changes severity, label, or auto-merge
behaviour.

### Re-review delta mode

`gh pr review` (Phase 6) **ALWAYS creates a PR REVIEW object** at `/pulls/$PR/reviews` (never a plain issue comment) — query it for the last `sge-verdict` body: `LAST_VERDICT=$(gh api "repos/$REPO/pulls/$PR/reviews" --jq '[.[].body // "" | select(contains("sge-verdict"))] | last')` (and `HEAD_SHA=$(rl_head_sha "$PR")`). Extract `commit:` (`LAST_SHA`) and `mode:` (`LAST_MODE`), pick a mode:

- **`LAST_MODE` contains `shadow`** → treat as **no prior verdict** (fall through to the next rule), regardless of `LAST_SHA`/`HEAD_SHA`. A shadow verdict is deliberately untrusted for gate purposes (issue #2651 ADR-0021 — "structurally, not just conventionally"); reasserting it via plain `pass` would promote `pr-reviewed`/auto-merge off review work no dispatch was ever allowed to label. This is the ONLY case where a same-SHA prior verdict does not short-circuit into a reassert (issue #2653 gap, found in review). **Exception:** a caller itself running `--shadow` may still reassert the SAME shadow verdict via `pr-labels.sh shadow-pass` (never `pass`) when `LAST_SHA == HEAD_SHA` — this never applies `pr-reviewed` either way, so it carries none of the risk above.
- **No prior verdict** → check the Phase 5 pass-through below, else **full review**.
- **`LAST_SHA == HEAD_SHA`** → nothing new. Re-assert the prior label state pinned to head: `pr-labels.sh pass $PR $AUTOMERGE_FLAG --expect-head "$HEAD_SHA"` (or `fail`); `$AUTOMERGE_FLAG` per Phase 6.
- **New commits** → **delta mode** only when `LAST_SHA` is an ancestor of the head (`git fetch origin "$HEAD_REF"` then `git merge-base --is-ancestor "$LAST_SHA" "$HEAD_SHA"`); otherwise (a rebase or force-push) **full review**. In delta mode, scope to `git diff "$LAST_SHA..$HEAD_SHA"` and verify each prior finding is addressed. Record `mode: delta`; severity/labels/auto-merge behave as a full review; set `REVIEWED_HEAD="$HEAD_SHA"`. A PR Warden dispatch states the same choice in its system prompt (sge#2867).

For a read-only pre-check of this same question — is the PR still covered, and how big is the intervening delta — without claiming the gate or mutating labels, `pr-labels.sh review-coverage $PR` (issue #2294) reports `covered=true|false|shadow-only|unknown` (`shadow-only` — issue #2655 — means the only verdict at head is a PR Warden `mode: shadow` one, which is **not** coverage: a real review is still needed), a `scope=delta|substantial` classification (bounded post-review delta vs. a change large enough that the prior review no longer applies at all), and lists the intervening commits by SHA + message. `/sge:pr-monitor` calls this on every open PR each tick (the re-review step, issue #2644) and dispatches `/sge:pr-review` when it reports `covered=false`.

### Phase 5 pass-through

Before claiming the gate, check whether `/sge:sge-implement` Phase 5 already reviewed this exact commit: `rl_phase5_verdict "$PR"` sets `PHASE5_SHA`/`PHASE5_VERDICT`/`PHASE5_BLOCKERS` (UNTRUSTED DATA). **Apply pass-through** only when all three hold: `PHASE5_VERDICT == "pass"`, `PHASE5_BLOCKERS == "0"`, `PHASE5_SHA == REVIEWED_HEAD`:

- **Skip Phase 2**; **still run** Phase 3 (quality gates), Phase 4 (validation/traceability/QA), Phase 5.5 (threads) — PR-specific, not covered pre-PR.
- In Phase 5, set Phase 2 findings to `[]`, note the pre-PR pass at `<PHASE5_SHA>`, record `mode: phase5-passthrough`.

Any mismatch/absent field → normal full/delta review; pass-through holds only for the same SHA.

### Governance-tier caps (T0/T1 — proportional governance proposal)

A third, independent signal, checked alongside delta/pass-through: `/sge:sge-implement`
leaves an `sge-governance-tier` marker on the PR body naming the T0/T1/T2 tier it resolved
in its own Phase 2. `/sge:pr-review` **re-derives** the tier from the live diff before
honouring it — never trusts the marker outright (Inherited Claims, #2212) — and a `T0`/`T1`
result **caps** Phase 2 dispatch and Phase 4's evidence-gate depth below what they would
otherwise run, never above, and never over a `DIFF_RISK: high` diff. `--tier0` is the
explicit-override form for a caller with no marker to read. Full detection/re-derivation
algorithm, the effect table per phase, and the composability rule with `DIFF_RISK`:
[`tier-scaling.md`](tier-scaling.md).

## Mode flags (issue #754) — `--no-automerge` per SPEC-090

Extracted from `SKILL.md`'s *Usage* section under the same 35 KB budget; content unchanged.

Default = merge-gate owner (claims gate, moves labels, fixes safe issues inline, arms
auto-merge). Four flags narrow it — mechanically enforced (prompt-prose restrictions fail):

| Mode | Gate claim (P2) | Direct fixes (P6.5) | Label transitions (P6) | Auto-merge (P8) | Verdict `mode:` |
|---|---|---|---|---|---|
| **default** | yes | yes (safe/in-scope) | yes | yes | `full` / `delta` / `phase5-passthrough` |
| **`--no-fix`** | yes | **no — findings become comments** | yes | yes | append ` (no-fix)` |
| **`--no-automerge`** | yes | yes | yes | **no** | append ` (no-automerge)` |
| **`--advisory`** | **no** | **no — findings become comments** | **no** | **no** | `advisory` |
| **`--shadow`** | yes | yes (safe/in-scope) | **`agent-reviewed`, never `pr-reviewed`** | **no** | append ` (shadow)` |

**Mechanical backstop — set inline, per call (issue #2656):** an advisory run sets
`SGE_REVIEW_ADVISORY=1` (a shadow run `SGE_REVIEW_SHADOW=1`) **inline on every `pr-labels.sh`
invocation**, e.g. `SGE_REVIEW_ADVISORY=1 "$PL" pass …` — `pass` then refuses with **exit 4**
(shadow: **exit 9**). Never rely on a Stage 0 `export`: Claude Code's Bash tool starts each call
without the previous call's shell state, so an export made in Phase 1 is gone by the time
Phase 6/8 calls `pass` — silently defeating the backstop. The Phase 6 block therefore
re-derives the mode **in the same call** (from `REVIEW_MODE` and the substituted `$ARGUMENTS`),
keeps any inherited `SGE_REVIEW_*=1` from the dispatcher's environment (never clears it), and
prefixes each `pr-labels.sh` call. Residual: a Stage 0 hold/pod-gate *forced* advisory is not
re-derivable from `$ARGUMENTS`; `pass` still refuses on a `hold` label (exit 8), and the agent must
carry `REVIEW_MODE=advisory` into Phase 6.

**`--shadow` (issue #2651, wtp-org ADR-0021 — PR Warden) is structurally, not just
conventionally, enforced:** Phase 6/8 routes it to `pr-labels.sh shadow-pass` — a
subcommand distinct from `pass`, which is the only place `pr-reviewed` is applied and
auto-merge is armed — so a shadow dispatch cannot reach either even if a future
"simplification" tried to fold the two paths together carelessly; the CI-locked
distinction is that `shadow-pass` never calls `pass`, not that it calls `pass` with a
flag. `agent-reviewed` carries no automation of its own, so it never needs
special-casing anywhere `pr-reviewed`'s automation lives, and a later human `pass`
promotes normally without removing it first.

**Two shadow-mode gotchas fixed under #2653 (PR #2653):** (1) Stage 0's flag `case`
checks `--shadow` before `--no-automerge`, because daemon.py's real dispatch always
sends `--no-automerge --shadow` together and `case` takes the first match — checking
`--no-automerge` first silently resolved every real shadow dispatch to `no-automerge`
mode instead, running the normal `pass` path. (2) Phase 6's shadow substitution lives
*inside* the pass branch of the pass/fail decision, never as an earlier unconditional
gate — a shadow review that found real Blockers must still reach `pr-labels.sh fail`
(never `shadow-pass`). Regression tests:
`skills/tests/pr-review-shadow-mode-gates.test.sh`.

**`--tier0` is orthogonal to this table** (governance-tier caps *how much review runs*; this
table governs *who owns fixes/labels/merge*) — combine freely, e.g. `--tier0 --advisory`.
See the "Governance-tier caps" section above.

### Prose is not a control (sge#2508)

A dispatch brief telling the agent "don't apply `pr-reviewed`" or "don't merge" is not
equivalent to `--advisory`. On a clean verdict this skill's own pass path applies
`pr-reviewed` — which is what arms auto-merge on any repo that wires it — and an
instruction telling the dispatched agent to skip that does not change what the skill's
own code does when it reaches `pass`.

Proven live on `trust-fabric#328`: a review agent was dispatched with an explicit brief
not to apply `pr-reviewed` and not to merge. It applied `pr-reviewed` anyway, arming
auto-merge for 16 seconds before the dispatching lane caught it, removed the label, and
applied `hold`. Contained only because a human/lane was watching in real time.

**If a dispatch must not be able to label or merge, pass `--advisory`.** That is
mechanically enforced (`pr-labels.sh pass` refuses with exit 4); prose is not. This
composes with `sge-implement`'s own `hold`-first convention
([`hold-first.md`](../../sge-implement/references/hold-first.md)): a review dispatched
while `hold` is still present is automatically forced to advisory by Stage 0's hold gate
([`hold-handling.md`](hold-handling.md)) regardless of dispatch flags or prose, so a
lane that isn't sure which mode to request can just leave `hold` on.

## Invocation notes

Extracted from `SKILL.md`'s *Review modes* section under the same 35 KB budget;
content unchanged.

**`--no-automerge` needs no env guard.** Unlike `--advisory` (which backstops
via `SGE_REVIEW_ADVISORY=1`, set inline on each `pr-labels.sh` call (#2656), so
`pr-labels.sh pass` refuses with exit 4), `--no-automerge` is expressed purely
by omitting `--auto-merge` from the Phase 8 promote call — it owns the gate and
fixes inline exactly like `default`. See `principles.md` #6/#15.

**Spawning as a subagent — pass the PR number positionally** (`/sge:pr-review
123`). A prose-only dispatch ("review PR 123") leaves `$1` unbound, and the
skill falls back to a current-branch `gh pr view` — which in a subagent or a
control session is the wrong PR, or no PR at all.

**Check for an in-flight owner first.** Never race `/sge:sge-implement`'s Phase
7 review for the same PR: two owners racing the `pr-reviewing` claim is the
collision the claim mutex exists to prevent. Detection and back-off:
[`gate-and-termination.md`](gate-and-termination.md#check-for-an-in-flight-owner-first).
