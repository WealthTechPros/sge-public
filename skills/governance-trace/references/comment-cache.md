# Step 0.5: Comment-cache short-circuit

Skip the fork when a fresh verdict exists. Loaded by [`../SKILL.md`](../SKILL.md) between Step 0 and [Step 0.6 (tier gate)](tier-gate.md).


The expensive part of this skill is Steps 1–5 — a full-depth classification fork (~10–15 min, ~70k tokens; issue #1258) that re-derives a verdict this skill *already posted as a `## Governance trace` comment* on a prior run. When that prior verdict is still valid, re-deriving it is pure waste. This step reuses it instead — but **only when it can prove the verdict is still valid**; otherwise it falls straight through to Step 1 and the gate runs at full depth, unchanged. The gate stays authoritative — the cache only avoids re-running it, it never replaces it.

Do **not** short-circuit in these cases (fall through to Step 1 as normal):

- `--spec` (verify mode) was passed — the caller wants a fresh Step 3 requirement-change check against a specific spec; do not reuse a cached classify-mode verdict for it.
- `--no-comment` was passed — the caller has opted out of the comment audit trail; honour that intent and do not read prior comments as a cache either.

Otherwise, run the short-circuit check with the shared IO helper. `skills/lib/governance-cache.mjs check-fresh` does the whole decision in **one** command: it fetches the newest `## Governance trace` comment on the issue via `gh`, resolves each named governance artefact's **commit SHA** both now and as-of the comment's `createdAt` via `git log`, and reports whether every artefact is unchanged. This skill does **not** re-implement comment parsing or the freshness comparison — those live in the enabler modules (`scripts/govtrace-cache.mjs` pure primitives, #1261; `skills/lib/governance-cache.mjs` IO layer, #1337).

**a. Resolve the governance artefact paths** for this repo — the same Vision, capability-model, and (when a prior verdict named one) matched-spec files Step 1 would read. Resolve them now so Step 1 can reuse the paths on a miss.

**b. Decide reuse.** Pass the issue number and each resolved artefact path to `check-fresh` (add `--repo` only for a cross-repo/hub dispatch — same repo, leave it off):

```bash
DECISION=$(node "${CLAUDE_PLUGIN_ROOT:-.}/skills/lib/governance-cache.mjs" check-fresh "$ISSUE" \
  ${GH_REPO:+--repo "$GH_REPO"} \
  --artefact "$VISION_PATH" \
  --artefact "$CAPABILITY_MODEL_PATH" \
  --artefact "$SPEC_PATH")   # omit the spec --artefact when the cached verdict named none
FRESH=$(echo "$DECISION" | jq -r .fresh)
```

`check-fresh` reports `fresh:true` only when a parseable, known-verdict `## Governance trace` comment exists **and** every named artefact's commit SHA is identical now to what it was when the comment was posted. It **fails toward staleness** — no prior comment, a malformed body, an unknown verdict token, an untracked/unreadable artefact, or an unusable `createdAt` all yield `fresh:false` — and always exits 0 (the decision is advisory; a `false` never blocks the gate, it just means run it). The `verdict` and `matchedSpec` come back on the same JSON line for reuse on a hit.

**c. On a cache hit (`fresh == true`):** reuse the cached verdict. Return the **cache-hit Step 7 JSON variant** (see Step 7) built from the decision — `verdict` and `matchedSpec` from `$DECISION`, `issue` from the positional argument — with `matchConfidence: "medium"` (a reused verdict, not a freshly derived one, warrants a human glance), the marker field **`cacheReused: true`**, and `commentPosted: false`. **Post no comment** — the audit trail already exists; a duplicate is exactly the `#8815/#8877`-style pile-up this step removes. Then **run [Step W](../SKILL.md#step-w-cortex-write-on-every-terminal-path-mandatory) — `path: cache-hit`, which reinforces the existing memory — and stop**; do not run Steps 0.6–6.

> Step W is **not** part of the "do not run Steps 0.6–6" skip. Skipping it here is precisely the #1664 bug: the cache-hit path is the *common* path, so a graph that never writes on it can never accumulate. Reinforcing costs one upsert, not a re-classification.

**d. On a cache miss (`fresh == false`, or no prior comment):** proceed to Step 0.6 (tier gate) and from there to Step 1.

A short-circuited run does not change any downstream posting rule: the Step 6 rules — `--no-comment` skips, but `MATCHES_EXISTING_MODIFIED` and `NOT_SGE_SCOPE` **always** post — apply only on the full-depth path (Step 6), which a cache hit never reaches. A cache hit posts nothing at all (the prior comment already carries whichever of those verdicts it recorded).


