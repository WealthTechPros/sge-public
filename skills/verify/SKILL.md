---
description: Verify a completed change — run the quality suite and check the diff against acceptance criteria. Accepts `--tier trivial` to use inline verification instead of spawning a review subagent.
argument-hint: "[--tier trivial|standard|critical]"
---

# Verify

Run post-implementation verification for a change, scaling the verification
depth to the change's complexity tier.

## Usage

```
/sgd:verify [--tier trivial|standard|critical]
```

When called without arguments, the tier is inferred from the Phase 2.5
`resolve-context-depth.mjs` result already computed for this change. Pass
`--tier` explicitly only when the caller has already resolved the tier and
wants to avoid re-running the classifier.

## Tier behaviour

| Tier | Verification mode | Subagent spawned? |
|---|---|---|
| `trivial` | Inline — diff review + targeted grep + side-effect check | No (default) |
| `standard` | Forked `/sgd:sgd-review` | Yes |
| `critical` | Forked `/sgd:sgd-review` | Yes (never thinned) |

### `--tier trivial` — inline mode

Passing `--tier trivial` (or being on a trivial-tier change) activates **inline
verification**. The subagent spawn is suppressed; instead:

1. **Phase 4 quality suite** — type-check, lint, tests — runs as normal (not
   skipped).
2. **Diff review** — read `git diff origin/main...HEAD` and confirm each
   acceptance criterion is met. Stay within ≤ 5 000 tokens total.
3. **Targeted grep** — grep only the changed paths as needed. Broad codebase
   searches signal the tier was wrong; escalate if needed.
4. **Side-effect check** — compare `git diff --name-only origin/main...HEAD`
   against the expected path set (the spec's "Files to Create/Modify" or the 0B
   plan). An unexpected file outside that set triggers automatic escalation:

   > **Escalation rule:** if any changed file falls outside the expected path
   > set, re-run verification as `--tier standard` (forked `/sgd:sgd-review`).
   > Record `verification_mode = "subagent (escalated from trivial)"` and embed
   > it in the PR body's `sgd-phase5-verdict` comment.

5. **Record the outcome** — set `verification_mode`:
   - `"inline"` — trivial inline gates passed, no side-effect found.
   - `"subagent (escalated from trivial)"` — side-effect check triggered
     escalation.

   This value is written into the Phase 6 PR body as the `"verification"` field
   inside the `sgd-phase5-verdict` HTML comment, making the verification path
   auditable in CI logs.

### `--tier standard` / `--tier critical` — subagent mode

On `standard` or `critical` (or when escalated from trivial), dispatch a
**forked, fresh-context subagent** running `/sgd:sgd-review`. Pass it the
starting map (touched files + audited-no-change notes from Phase 3) and tell it
to skip the quality-suite step (Phase 4 already ran it).

Record `verification_mode = "subagent"` (or `"subagent (escalated from
trivial)"`) for the PR body.

## Relationship to sgd-implement

`/sgd:sgd-implement` Phase 5 owns the verification decision — it calls this
skill implicitly by following the Phase 5 procedure. `/sgd:verify` is the
canonical reference for that procedure and can also be invoked standalone (e.g.
after a manual patch, or when the Phase 5 step was interrupted).

Full rationale and worked examples:
[`../sgd-implement/references/context-depth.md`](../sgd-implement/references/context-depth.md#trivial-tier-verification-cap-1267)
