# sge-implement — Phase 0 routing (spec or no spec)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

**Route — spec or no spec?**

Mechanical check: grep the issue title and body for a feature-spec id — `SPEC-[0-9]+` (or legacy `SGD-[0-9]+`).

- **Spec reference found** → Phase 0.5 in **verify mode** (`--spec SPEC-NNN`) — a citation is a claim, not a guarantee it still matches; confirm before trusting it.
- **No spec reference found** → present options:
  - Option A: "Enter the SGE spec number" — user provides it → Phase 0.5 **verify mode** with that spec
  - Option B: "Classify against governance" — Phase 0.5 **classify mode** (no `--spec`)
  - Option C: "Cancel"

No option skips classification — every issue gets classified. `NO_SPEC_WARRANTED` (below) is a legitimate chore/infra issue's outcome; it proceeds as fast as the old bypass, but as a classified, audited fast-path rather than a blind one.

## Cortex lookup

**Cortex lookup (hit/miss discipline):** before reading any file or calling `gh issue view`, call `search_nodes` with the issue number and any spec id in the preloaded context. If sge-memory is unconfigured, skip silently.

- **Hit** — use the cached summary; skip the Read. Observations may be stale if the issue changed; orient by them, not as ground truth.
- **Miss** — proceed normally. After reading the issue body and spec file, `create_entities` to populate Cortex for next session — **fire-and-forget**: dispatch without awaiting it (nothing this run reads it back). Best-effort/skip if unavailable.

Track hits/misses as counters (`cortexHits`, `cortexMisses`) — appended to the PR body in Phase 6.
