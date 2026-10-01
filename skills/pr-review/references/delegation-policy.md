# Delegation policy (standing orders): what a review may decide without asking

An operator can give `/sge:pr-review` a **delegation policy**: a list of *standing orders*, each
granting authority once so the reviewer applies it and logs it instead of escalating the same
decision to a human every time. The mechanism is product-neutral. The policy is the operator's
data, and nothing in the skill names an org, a repo or a person.

**No policy, or an invalid one, means no delegation.** Every helper prints nothing, and the
hard-coded holds below behave exactly as they always have. A policy only ever *narrows* when a
human is asked. It never widens what a review may merge.

## Where the policy comes from

The policy is read from the first of these that is set:

- `SGE_DELEGATION_POLICY_JSON`: the policy document as JSON.
- `SGE_DELEGATION_POLICY_FILE`: a path to a file holding the same JSON.

An unattended review daemon exports `SGE_DELEGATION_POLICY_JSON` from its own validated policy
file (projected to `version`/`orders`/approvals' `id`/`order`/`scope`) and blanks any inherited
`SGE_DELEGATION_POLICY_FILE`, so a dispatched review only ever sees the daemon-validated document.
An interactive session without either set is unaffected.

**The review identity.** Hold markers, the `hold` label event and the clean verdict only count
when they come from one login: `SGE_REVIEW_BOT_LOGIN` (default `wtp-sge[bot]`, the same identity
the gate's existing trust filters accept). No other Bot, App or collaborator is trusted.

The shape is the standing-orders document itself:
`{"version":1,"owner":…,"orders":[{"id","kind",…}],"approvals":[{"id","date","granted_by","order","scope","quote"}]}`.
Only `version: 1` with an `orders` array is accepted.

The helpers live in [`../delegation-policy.sh`](../delegation-policy.sh) (`dp_*`, jq plus read-only
`gh`). `review-lib.sh` wraps them as `rl_hold_release_order` and `rl_policy_approval_for`.

## Hold release: a security MAJOR the reviewer fixed itself (`kind: hold-release`)

The order applies when it has `kind: hold-release` and `trigger: self-fixed-security-major`. Its
id (e.g. `SO-4`) is whatever the policy names it.

**1. When the hold is applied (Phase 5 / 6.5).** Security MAJOR → hold (#1393) is unchanged: the
reviewer still applies `hold`. What is new is that it records *why*, in a machine-readable
`sge-hold-marker` comment:

- **If you fixed the finding in this review** (Phase 6.5, fix commit pushed), then after the push run:

  ```bash
  "$PL" apply-hold "$PR" --reason self-fixed-security-major --head "$(git rev-parse HEAD)" \
    --categories "security,<sub-categories>" --order "$(rl_policy_order hold-release self-fixed-security-major)"
  ```

  `--session` defaults to this session's id (`SGE_REVIEW_SESSION_ID`, else the Claude Code
  session id). Name the finding's sub-categories honestly: `authentication`, `identity`,
  `tenant-isolation`, `secrets`, `credentials`, `infra-apply` and so on. The policy's
  `exclude_categories` are matched against them.
- **Otherwise** (the finding was not fixed, it is in an excluded category, or the PR touches an
  excluded path), use `--reason escalate`. An `escalate` hold is never released by policy.

A plain `apply-hold` (no `--reason`) posts no marker, so that hold stays human-only. The same is
true of a `HOLD:` body marker, which keeps its #1393 behaviour.

**2. When a later review sees the hold (Stage 0).** The Stage 0 gate reports `hold:hold` when
`hold` is the only human-hold label. It then asks `rl_hold_release_order "$PR"`, which prints the
order id only when **all** of the following hold:

- the policy has the hold-release order;
- `hold` is present, and no `do-not-merge` / `needs-human` / `blocked` label is present;
- the PR body has no `HOLD:` marker;
- the **latest** `sge-hold-marker` posted by the review identity has
  `reason: self-fixed-security-major`;
- the **latest** `labeled: hold` event was applied by the review identity (a hold a human applied
  is never policy-releasable), and the marker was posted at or after it;
- both this review's session id and the marker's session id are known (non-empty), and they
  **differ**. That is the independence requirement;
- no marker category is in `exclude_categories`;
- no changed path of the PR (rename sources included) matches `exclude_paths`;
- the order's `exclude_categories` and `exclude_paths` are non-empty arrays of strings (a
  malformed exclusion list, or an exclusion check that errors, counts as excluded).

A sign-off-pending comment from a human still wins: `rl_hold_check` runs its comment scan before
reporting `hold:hold`.

Every check fails closed: an unreadable input yields nothing. When the order id is printed, the
review runs **non-advisory** with `HOLD_RELEASE_ORDER=<id>`. Otherwise it is advisory, exactly as before.

**3. At the gate (Phase 6).** If `HOLD_RELEASE_ORDER` is set and the verdict has **0 blockers and 0
majors**, run `"$PL" release-hold "$PR" --order "$HOLD_RELEASE_ORDER" --head "$HEAD"` and then the normal
`pass`. Post the verdict **before** calling it. `release-hold` re-derives eligibility itself: it
refuses with exit 9 unless the result is exactly `--order`, when no policy is set, when `--head`
(required, full SHA) is not the PR's live head, or when the review identity's **latest**
`sge-verdict` for that exact head is not clean (`verdict: pass`, `recommendation: APPROVE`,
`blockers: 0`, `majors: 0`), not `mode: full`, posted before the hold marker, or not carrying this
session's `session:` id (`SGE_REVIEW_SESSION_ID`, else the Claude Code session id; it must differ from the marker's). It also refuses under
`SGE_REVIEW_ADVISORY=1` (exit 4) or `SGE_REVIEW_SHADOW=1` (exit 9), and when a human
sign-off-pending comment is present (the same `rl_hold_check` scan as Stage 0). It removes `hold`
and posts one comment:
"hold released under standing order <id> (self-fixed security MAJOR, independent clean re-review
at <sha>)".

With any blocker or major, keep the hold and take the normal `held` / advisory path. If this
review also fixes a new security MAJOR, apply a fresh marker.

Record `applied_order: <id>` in the verdict block, or `applied_order: none` when no order was
applied.

### Residual limitation: independence is not externally anchored

The session id is still supplied by the reviewing process's own environment
(`SGE_REVIEW_SESSION_ID`, else the Claude Code session id). The checks above bind the marker, the
`hold` label and the clean verdict to the review identity, and require both session ids to be
known and different. They do **not** prove that two sessions are different *agents*: a process
that holds the review identity's credentials could present a fresh session id and release a hold
it applied itself. The control therefore rests on the review identity's credentials being held
only by the review pipeline (the daemon mints one per dispatch). An external anchor, such as a
daemon-signed session attestation, is a follow-up. Until it exists, an operator who needs a
stronger guarantee should leave the hold-release order out of the policy.

## Recorded approvals (`kind: recorded-approvals`)

Some findings amount to "the PR cites an approval or sign-off that cannot be verified", such as an
owner's decision quoted in the PR body. For these, run `rl_policy_approval_for "<owner/repo>#<N>"`.
It prints the ids of recorded approvals whose `scope` names this PR exactly (so `#12` never
matches `#123`, and `acme/x#12` never matches `notacme/x#12`). It prints nothing unless the policy has a `recorded-approvals` order.

- **If an id is printed:** the finding is **satisfied**. Cite the approval id in the finding row
  and do not count it as a blocker or major. Record `applied_order: <recorded-approvals id>` if
  it was the only order applied; if several were applied, list them comma-separated.
- **If nothing is printed:** the finding stands as today.

A broader scope, such as a named programme of work, is a judgement call. Treat it as covering the
PR only when the scope text unambiguously names what the PR does, and cite it the same way.

## Verdict block

`applied_order: <id>[,<id>…] | none` names every standing order this review applied. It is
informational, and gate parsers tolerate it (they read `verdict:` / `commit:` only). See
[`docs/schemas/sge-verdict-block.md`](../../../docs/schemas/sge-verdict-block.md).
