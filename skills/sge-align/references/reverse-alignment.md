# Step 4 — Reverse alignment: classification table

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Now go **right→left**: list **all** open issues (same pagination guard — use `"$IR" list --state open --limit 1000`; `IR` re-defined at the top of this Bash call) and classify each against current scope:

| Issue vs. current scope | Action |
|---|---|
| **Orphaned** — capability/spec removed/renamed | relabel to successor, or close if truly gone |
| **Out-of-scope** — contradicts a Vision Non-goal | close, citing the non-goal |
| **Superseded** — spec `deprecated` / has `supersededBy` | update (link successor) or close |
| **Already delivered** — spec `implemented`, code+tests exist | close ("delivered in `<spec/PR>`") |
| **Stale scope** — acceptance criteria changed materially | comment/update to re-align |
| **Aligned** | leave it |
