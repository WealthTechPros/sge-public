# Pod-gate mode — rationale and mechanics (issue #1374)

Extended rationale for the `SGE_GATE_OWNER=pod` switch introduced in
`sge-implement` Phase 6.5 and `pr-review`'s Stage 0 guard. The operational
rules live in their respective `SKILL.md` files; this file carries the full
"why", the configuration surface, and the incident that motivated the change.

## Motivation

On repos covered by Autopilot review pods (`sge`, `client-onboarding`), two
reviewer classes race the same `pr-reviewing` label mutex when both active:

1. **The dispatched implementer** — `sge-implement` Phase 7 invokes
   `/sge:pr-review` on its own PR as part of completing the pipeline.
2. **The review pod** — a separate agent pod wakes up, sees the draft PR, and
   also invokes `/sge:pr-review`.

Both agents call `pr-labels.sh start-review`, which is the label mutex anchor.
One wins; the other hits exit 3 (claim younger than TTL) and backs off. The
winner commits fixes; the loser or a later retry sees them as new commits and
re-reviews. In the 2026-07-17 incident the impl-2355 lane claimed `pr-reviewing`
on `client-onboarding#2389` mid-Phase-7 and had to self-revert (`pr-labels.sh
fail` + handoff comment) after orchestrator correction — two live reviewers for
one PR is the root cause of most fleet stalls that day.

The fix is a first-class switch: when `SGE_GATE_OWNER=pod` the implementer ends
at draft PR + handoff comment and the pod is the sole gate owner. No patching of
individual dispatch prompts required.

## Configuration surface

Equivalent signals — the first present wins:

| Signal | Scope | Example |
|---|---|---|
| `SGE_GATE_OWNER=pod` env var | Per-dispatch (set in the `Agent()` prompt or dispatch env) | `SGE_GATE_OWNER=pod /sge:sge-implement 2389` |
| `SGE_REVIEW_OWNER=daemon` env var | Per-dispatch — alias for `SGE_GATE_OWNER=pod` (issue #1313) | `SGE_REVIEW_OWNER=daemon /sge:sge-implement 2389` |
| `.claude/sge.json` → `gateOwner: "pod"` | Repo-level (committed, applies to every dispatch) | `{ "gateOwner": "pod" }` |
| `.claude/sge.json` → `reviewOwner: "daemon"` | Repo-level — alias for `gateOwner: "pod"` (issue #1313) | `{ "reviewOwner": "daemon" }` |

**Env var takes precedence.** Across all four signals the resolver order is
`SGE_GATE_OWNER` > `SGE_REVIEW_OWNER` > `gateOwner` > `reviewOwner` (any env
var beats any config key; within each layer the canonical name beats its
alias). Repo-level config is the right default for daemon-covered repos; env
override lets a one-off interactive session opt in or out without editing the
config.

### The review-owner alias (issue #1313)

`SGE_REVIEW_OWNER=daemon` (and `reviewOwner: "daemon"` in `.claude/sge.json`)
is the daemon-era name for the same switch. The resolver normalises it to
`pod` and everything downstream — the Phase 6.5 handoff, the skipped
Phases 7/8, pr-review's Stage 0 guard — runs the existing pod code path
unchanged. There is deliberately **no second review-owner switch, mechanism,
or code path**: aliasing at the resolver is the whole implementation, so the
two names can never diverge in behaviour.

### Recommended setup for pod-covered repos

Commit `.claude/sge.json` at the repo root:

```json
{
  "gateOwner": "pod"
}
```

This means every `sge-implement` dispatch on that repo — no matter which
orchestrator sends it — automatically enters pod-gate mode without any
per-dispatch prompt patching.

## What changes in pod-gate mode

### `sge-implement` (Phase 6.5)

Resolver (env var takes precedence; `.claude/sge.json` is the repo-level fallback):

```bash
GATE_OWNER="${SGE_GATE_OWNER:-}"
# Review-owner alias (issue #1313): daemon-era name for the same switch.
if [ -z "$GATE_OWNER" ] && [ "${SGE_REVIEW_OWNER:-}" = "daemon" ]; then
  GATE_OWNER="pod"
fi
if [ -z "$GATE_OWNER" ] && [ -f ".claude/sge.json" ]; then
  GATE_OWNER=$(node -e \
    "try{const c=require('./.claude/sge.json');process.stdout.write(c.gateOwner||(c.reviewOwner==='daemon'?'pod':''))}catch(e){}" \
    2>/dev/null || true)
fi
```

Handoff comment when `GATE_OWNER == "pod"` (replace `$PR_NUMBER`):

```bash
gh pr comment "$PR_NUMBER" --body \
  "**SGE handoff — pod-gate mode (issue #1374):** implementation complete; PR is ready for pod review.
Gate owner: \`pod\` (signal: \`SGE_GATE_OWNER=pod\` or \`.claude/sge.json#gateOwner\`).
Phases 7/8 (pr-review + merge-gate) are owned exclusively by the Autopilot review pod — **do not invoke \`/sge:pr-review\` from this session**."
```

After Phase 6's commit + draft PR:

1. Resolves `GATE_OWNER` (env var → `.claude/sge.json` fallback).
2. If `pod`: posts a handoff comment on the PR, skips Phases 7 and 8 entirely,
   emits a `SkillRunRecord` with `verdict "handed-off"` / `phaseReached "Phase 6.5"`,
   and returns with the summary "Gate owned by pod — handed off as draft PR #N."
3. If unset / not `pod`: continues to Phase 7 as before (self-drive).

**The implementer never touches `pr-reviewing` or `pr-reviewed`.** The pod has
exclusive access to the label mutex.

### `pr-review` (Stage 0 guard)

A belt-and-suspenders backstop for unpatched invocations:

- If `SGE_GATE_OWNER=pod` **or** its alias `SGE_REVIEW_OWNER=daemon` is set
  **and** `SGE_POD_REVIEW=1` is **not** set → force `--advisory` mode (no
  claim, no labels, no auto-merge). Logs a warning explaining the guard.
- Pod agents that legitimately own the gate set `SGE_POD_REVIEW=1` in their
  dispatch environment, so the guard is transparent to them.
- Self-drive invocations (default, no `SGE_GATE_OWNER`) are unaffected.

## How pod agents invoke pr-review

A review pod dispatched on a pod-covered repo sets **both** signals:

```bash
SGE_GATE_OWNER=pod SGE_POD_REVIEW=1 /sge:pr-review "$PR"
```

`SGE_GATE_OWNER=pod` advertises pod-gate mode to any co-running skill;
`SGE_POD_REVIEW=1` signals to pr-review's Stage 0 guard that this is a
pod-authorized invocation, not a stray implementer.

If neither env var is set (solo repo, no pod), pr-review behaves exactly as
before the change.

## Default behaviour unchanged

Repos without `.claude/sge.json` and dispatches without `SGE_GATE_OWNER` are
unaffected — `GATE_OWNER` resolves to empty, Phase 6.5 falls through to Phase 7,
and pr-review's Stage 0 guard short-circuits (neither condition matches). The
solo-repo pipeline works identically.

## Exit taxonomy additions

| Mode | SkillRunRecord verdict | phaseReached | Summary |
|---|---|---|---|
| Pod-gate (gate owner = pod) | `handed-off` | `Phase 6.5` | "Gate owned by pod — handed off as draft PR #N" |
| Self-drive (gate owner unset / not pod) | `merged` (success) / `blocked` | `Phase 8` / `Phase 0.5` | (unchanged) |
