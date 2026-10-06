# decompose-issue — validating owns paths (Phase 3d)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

So before you emit any child's `owns` footprint, run every path through the mechanical validator — do **not** eyeball it:

```bash
VFM="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/scripts/validate-file-map.sh"
# Validate one child's owns footprint (comma-separated, as it will be written):
printf 'Owns: %s\n' "services/import_service.parse*, parsers/csv.*, tests/csv_*" \
  | "$VFM" owns
```

It classifies each path against `git ls-files` and prints one annotated line:

- `ok <path>` — a concrete path that exists, or a glob that matched ≥1 tracked file → emit as-is.
- `new <path> (new)` — a concrete path absent from the tree → the child will **create** it; emit it **with the `(new)` marker** so the lane does not hunt for it.
- `flag <path> <reason>` — a phantom: a concrete path you meant as an **existing** surface that matches nothing, or a glob that expands to zero files. **Correct it (nearest real path) or drop it — never emit it silently.** The validator exits non-zero if any path is flagged.

When a path is meant to be an existing surface (not one the child creates), assert that with `--existing` so an absent one is flagged rather than quietly marked new:

```bash
"$VFM" check --existing services/import_service.ts services/import_service.parse
```

Only paths the child genuinely creates should carry `(new)`; everything else must resolve to a real file or glob match, or be dropped. Run this for **every** child before Phase 5.

> **Cross-repo children.** For a child stamped with a different execution `Repo:` (Phase 5), validate its `owns` paths against **that** repo's tree — run the validator from that checkout (`cd "$(${CLAUDE_PLUGIN_ROOT}/scripts/with-repo-cwd.sh resolve owner/other-repo)"` then `"$VFM" owns`), since `git ls-files` is repo-local.
