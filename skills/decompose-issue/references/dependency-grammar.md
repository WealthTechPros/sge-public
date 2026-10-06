# decompose-issue — dependency metadata grammar

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

This is the **canonical grammar** for machine-readable dependency edges in an
issue body. Consumers (`/sge:available-issues` Phase 2, `/sge:team-pipeline`
Phase 1) parse it case-insensitively with:

```
(depends[ -]?on|blocked[ -]?by|requires)[[:space:]:]+#[0-9]+
```

Matching forms — all declare "issue #123 must close/merge before this one starts":

- `DependsOn: #123` (the field this skill writes on every child)
- `Depends on #123` / `Depends-on #123`
- `Blocked by #123` / `BlockedBy: #123`
- `Requires #123`

`DependsOn: —` (em dash) declares **no** dependencies — it contains no `#N`, so
it never matches. Do not invent new keywords; extend the regex here first and
mirror it in the consumers if a new form is ever needed.

**Cross-repo refs** (`Depends on org/repo#99`) are recognised by the port and
emitted as `unknown` (blocking, fail-closed) — they cannot be resolved
repo-locally (#1732). Spaced refs like `# 12` are not matched (not a standard
GitHub form). Multiple refs on a single `DependsOn:` line (comma-separated) are
not supported; use one ref per line. Only **direct** dependencies are resolved;
no transitive walk exists.

---
