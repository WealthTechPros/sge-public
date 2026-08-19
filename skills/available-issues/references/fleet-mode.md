# Fleet mode (`--fleet`) — org-wide worklist

Reference detail for `SKILL.md`'s `--fleet` flag. Loaded by [`../SKILL.md`](../SKILL.md).

One invocation → one conflict-safe, dependency-annotated worklist spanning every repo in the fleet. This section's output shape is the **discovery contract consumed by `/sge:fleet-dispatch`**.

## Fleet membership — from the argument only

Fleet membership comes exclusively from `--fleet` (or config the *caller* expands) — never from org or repo names baked into this skill:

- **`--fleet <org>`** — a single token with no comma and no slash is a GitHub org; enumerate its repos live:

  ```bash
  gh repo list "$ORG" --no-archived --limit 200 --json nameWithOwner -q '.[].nameWithOwner'
  ```

- **`--fleet owner/a,owner/b,…`** — an explicit comma-separated list; each entry takes any form the helper accepts (`name`, `owner/name`, GitHub URL). A caller holding a fleet manifest expands it itself, e.g. `--fleet "$(yq -r '[.repos[].name] | join(",")' fleet.yaml)"`.

## Per-repo pass — helper-resolved, fail-loud

For each fleet member, resolve its local checkout with the SPEC-057 helper and run **Phases 1–4 unchanged** inside it (per-repo conflict analysis is identical to single-repo mode):

```bash
for R in $FLEET; do
  cd "$("$WRC" resolve "$R")" || exit 1   # unreachable checkout/repo → abort the run, loudly
  # Phases 1–4 exactly as single-repo, in this repo's context
done
```

**Fail-loud rule:** a fleet member whose checkout cannot be resolved — or whose `gh` calls fail — **aborts the whole run** with the helper's error naming the repo. Never emit a silently-narrowed worklist: a consumer dispatching against it would believe the missing repo had nothing ready. To proceed without the unreachable repo, the caller re-invokes with the reachable subset listed explicitly.

## Aggregation semantics

- **Claim + dependency gates: per repo, unchanged.** `agent-lock`, assignees, in-flight branches/PRs, and `DependsOn: #N` all resolve within each issue's own repo — a bare `#N` is repo-local, exactly as in single-repo mode.
- **Conflict matrix: per repo only.** File/route/schema surfaces in different repos cannot merge-conflict, so cross-repo pairs are parallel-safe by construction; `serialGroups` never span repos.
- **Ranking:** Phase 4's strict-priority order applied across the aggregate; cross-repo ties break by repo slug (lexicographic), then lowest issue number — deterministic, same input → same worklist.
- **`--count`** caps the **aggregate** parallel set, not each repo's share.

## Fleet output — the `/sge:fleet-dispatch` discovery contract

Every entry is **repo-qualified** (the single-repo shapes above are unchanged — bare-number arrays — so `/sge:team-pipeline` keeps parsing them):

```
Fleet worklist (3 repos; 4 parallel-safe of 9 ready):
  owner/a#218   high    surface: app/billing/**
  owner/b#41    high    surface: docs/specs/**
  owner/a#224   medium  surface: cli/commands/**
  owner/c#12    low     (spec-only)
Serial groups:
  owner/a: #207, #219        (both touch app/auth/**)
Blocked:
  owner/b#33  ← depends on owner/b#10 (open)
```

```json
{
  "fleet": ["owner/a", "owner/b", "owner/c"],
  "parallelSafe": [
    { "repo": "owner/a", "issue": 218, "priority": "high", "surface": ["app/billing/**"] },
    { "repo": "owner/b", "issue": 41,  "priority": "high", "surface": ["docs/specs/**"] }
  ],
  "serialGroups": [ { "repo": "owner/a", "issues": [207, 219] } ],
  "blocked":      [ { "repo": "owner/b", "issue": 33, "blockedBy": [10] } ],
  "conflicts":    [ { "repo": "owner/a", "a": 207, "b": 219, "on": ["app/auth/login.ts"] } ]
}
```

Contract guarantees for the consumer (`/sge:fleet-dispatch`):

- `parallelSafe` is pairwise conflict-free **and** each entry was unclaimed/unblocked in its own repo at derivation time;
- `blocked[].blockedBy` numbers are repo-local to `blocked[].repo`;
- `parallelSafe` ordering **is** the dispatch priority order;
- the shape is stable — additive fields only.

## Flag interactions under `--fleet`

- `--mode autonomous-next` → exactly one entry, with a `"repo"` field: `{ "repo": "owner/a", "issue": 218, "priority": "high", "reason": "…" }` (or `{ "repo": null, "issue": null, "reason": "…" }` when the fleet is drained).
- `--setup` → **refused** (exit with an error). Claiming and worktree creation across repos belongs to the consumer — `/sge:fleet-dispatch` owns the cross-repo claim lifecycle.
- `--analyze N` → refused (issue numbers are repo-local); use `--repo <owner/name> --analyze N` instead.
- `--module` / `--milestone` → applied per repo, same label/milestone name in each.
