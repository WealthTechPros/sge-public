# Stacked PRs, Partial-Merge Hazards & Merge-Commit Reversions

Referenced from `/sge:pr-review` (Phase 1, Stage 3) and `/sge:pr-monitor` (lane assignment).
Issue: #2296 — the detection rules for all four ACs live here; the skills carry concise pointers.

---

## AC1 — Detect stacked PRs

A PR is **stacked** when its `baseRefName` equals another open PR's `headRefName`. The stacked
PR must not merge before the PR it is based on — merging it first lands a diff whose base
assumption (the parent PR's changes) isn't yet in main.

### Detection

```bash
# Fetch all open PRs' head and base branch names
OPEN_PRS=$(gh pr list --repo "$REPO" --state open \
  --json number,headRefName,baseRefName --limit 500)
# Note: capped at 500; increase or paginate on repos with > 500 open PRs.

# For the PR under review, check whether its base is another PR's head
BASE=$(gh pr view "$PR" --json baseRefName --jq .baseRefName)
STACKED_ON=$(printf '%s' "$OPEN_PRS" | \
  jq -r --arg base "$BASE" '.[] | select(.headRefName == $base) | .number')
```

### Actions

- If `$STACKED_ON` is non-empty: **the PR is stacked**. State the implied merge order
  (`PR #<STACKED_ON> must merge before PR #<PR>`) with the reason.
- Raise a Phase 5 finding:
  ```json
  {"file":"","line":0,"severity":"major","category":"requirements",
   "finding":"stacked PR — must merge #<STACKED_ON> before this one",
   "suggestion":"Ensure #<STACKED_ON> is reviewed and merged first; then rebase this PR onto main."}
  ```
- Do not APPROVE a stacked PR if its parent is still open; post COMMENT or REQUEST_CHANGES with
  the order note.
- Detect multi-level stacks (A → B → C) by repeating the check on `STACKED_ON` itself. Use a
  visited-set (`VISITED="$PR"`) to guard against cycles before the cycle-detection in AC4 runs:
  ```bash
  while [ -n "$STACKED_ON" ] && ! echo "$VISITED" | grep -qw "$STACKED_ON"; do
    VISITED="$VISITED $STACKED_ON"; STACKED_ON=$(check_for_parent "$STACKED_ON")
  done
  ```

---

## AC2 — Flag partial-merge hazards

A **partial-merge hazard** exists when merging this PR alone would leave a governance artefact
(Vision, capability model, spec, ADR, feature doc) asserting something that a sibling open PR
exists to correct or complete. The reviewer who spotted this in practice noted:

> *"Merging [PR A] alone would have moved an existing inconsistency up into the top-level governance
> artefact an auditor reads first."*

### Detection steps

1. Identify governance artefacts changed by this PR using the repo's `CLAUDE.md` spec globs
   (Vision, capability model, spec files, ADRs, feature docs).
2. Fetch the diff of every other **open** PR touching any of those same artefact paths:

   ```bash
   CHANGED_SPECS=$(gh pr diff "$PR" --repo "$REPO" --name-only | grep -E "$SPEC_GLOB_RE")
   for SPEC in $CHANGED_SPECS; do
     SIBLING_PRS=$(printf '%s' "$OPEN_PRS" | \
       jq -r --argjson pr "$PR" --arg f "$SPEC" '.[] | select(.number != $pr) | .number')
     for S in $SIBLING_PRS; do
       gh pr diff "$S" --repo "$REPO" --name-only | grep -qF "$SPEC" && \
         echo "POTENTIAL_HAZARD $S touches $SPEC"
     done
   done
   ```

3. For each potential hazard pair, read both diffs against the shared artefact. Determine whether
   PR A's change would create an inconsistency when PR B's correction is absent from main.

### Actions

- If a hazard is confirmed: name the specific artefact(s) and the sibling PR(s).
- Recommend merging as a unit (rebase onto each other or merge in immediate succession).
- Phase 5 finding:
  ```json
  {"file":"<artefact-path>","line":0,"severity":"major","category":"requirements",
   "finding":"partial-merge hazard — merging this PR alone leaves <artefact> inconsistent with PR #<S>'s correction",
   "suggestion":"Coordinate with #<S>: merge both in immediate succession or rebase so one lands on the other."}
  ```
- When the sibling is also stacked (AC1), the merge-order recommendation (AC4) already handles
  sequencing — annotate both findings with the same sibling PR number.

---

## AC3 — Detect silent reversions in merge commits

A **silent reversion** occurs in a merge commit when conflict resolution drops a deliberate change
from one of the two parents, restoring a pre-change state without surfacing it in the PR diff.

*Real example from the issue:* a stacked branch predated a review fix; the conflict resolution
took the older side, and the wording the fix introduced was restored — while the PR simultaneously
introduced rules that violated that wording. Nothing flagged it automatically.

### Detection

When the PR contains a merge commit (a commit with more than one parent):

```bash
# Find merge commits on the PR branch since it diverged from base
MERGE_COMMITS=$(gh pr view "$PR" --json commits \
  --jq '.commits[] | select((.parents | length) > 1) | .oid' 2>/dev/null || true)

for MERGE_SHA in $MERGE_COMMITS; do
  # Get both parents
  PARENTS=($(git log --pretty=format:"%P" -1 "$MERGE_SHA"))
  PARENT1="${PARENTS[0]}"
  PARENT2="${PARENTS[1]:-}"
  [ -z "$PARENT2" ] && continue   # not actually a merge commit in the tree

  # For each file changed in the merge commit relative to parent 1,
  # check whether any chunk PARENT2 introduced (over the common ancestor) is absent in the result.
  MERGE_BASE=$(git merge-base "$PARENT1" "$PARENT2" 2>/dev/null)
  CHANGED=$(git diff --name-only "$PARENT1" "$MERGE_SHA" 2>/dev/null)
  for FILE in $CHANGED; do
    # Lines PARENT2 introduced since the common ancestor (precise — avoids false positives from
    # changes PARENT1 made that PARENT2 never touched):
    P2_ADDS=$(git diff "${MERGE_BASE:-$PARENT1}" "$PARENT2" -- "$FILE" 2>/dev/null | grep '^+' | grep -v '^+++')
    # Lines present in the merge result (relative to PARENT1):
    MERGE_ADDS=$(git diff "$PARENT1" "$MERGE_SHA" -- "$FILE" 2>/dev/null | grep '^+' | grep -v '^+++')
    # Any add in P2 that is absent in the merge = candidate silent reversion
    DROPPED=$(comm -23 \
      <(printf '%s\n' "$P2_ADDS" | sort) \
      <(printf '%s\n' "$MERGE_ADDS" | sort))
    if [ -n "$DROPPED" ]; then
      echo "POSSIBLE_REVERSION in $FILE at merge $MERGE_SHA"
      printf '%s\n' "$DROPPED" | head -5
    fi
  done
done
```

### Actions

- For each flagged file, present the dropped lines and ask: was this intentional conflict
  resolution or an accidental drop?
- Phase 5 finding when a reversion is confirmed:
  ```json
  {"file":"<path>","line":0,"severity":"blocker","category":"correctness",
   "finding":"merge commit <sha> silently reverted a change in <file> — conflict resolution dropped lines from parent 2",
   "suggestion":"Verify the dropped lines are intentional; if not, restore them and re-push."}
  ```
- **Never accept a self-description** of what the merge commit does — always re-derive from the
  three-way diff (both parents vs. the merge result). A deliberate drop should have a commit
  message explaining it; flag it as a minor if no explanation is given.
- `RESCUED_ENV=1` PRs are higher-risk for this; apply the check regardless of diff-risk tier.

---

## AC4 — Merge-order recommendation for a PR queue (pr-monitor)

When `/sge:pr-monitor` holds a queue of related or stacked PRs, emit a merge-order recommendation
**before acting on any lane**, so the operator never has to infer it.

### Algorithm

1. **Build the dependency graph.** For each PR in the queue, apply AC1 detection against every
   other PR in the queue (not just open PRs globally — the queue is the scope).

2. **Detect cycles.** A cycle (A stacked on B stacked on A) is a configuration error — flag loudly
   and block until the human resolves it. Do not attempt to auto-rebase into a cycle.

3. **Topological sort.** PRs with no in-queue dependents first; stacked PRs after their base.

4. **Apply hazard flags.** PRs with a confirmed AC2 hazard against each other should be treated as
   a unit — merge them in immediate succession (no other PR should merge between them).
   Represent them as a group: `[#812, #815] — merge as a unit (partial-merge hazard on capability-model.yaml)`.

5. **State the reasoning** for each position. Omit the reasoning only when the basis is obvious
   (e.g. a lone PR with no stacking).

### Example output

```
Stacked-PR merge-order recommendation (queue: #809, #812, #815):
  1. PR #809 — base: main, no in-queue dependents
  2. PR #812 — base: main, no in-queue dependents
  3. PR #815 — stacked on #812 (baseRefName == fix/issue-812); must merge after #812
  Hazard note: #812 and #815 share docs/specs/SPEC-042.md — if #812 alone merges,
    SPEC-042 §3 asserts C-17=deprecated while #815's correction (C-17=retired) is unmerged.
    Recommend merging #812 immediately followed by #815 with no PRs in between.
```

### When there are no stacked PRs

Emit a one-liner: `No stacked PRs detected in the current queue — merge in any order.`
