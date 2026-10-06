# Authoring-time pre-check (shift the gate left)

The full audit runs during a triage sweep — long after an issue is written. To
score an issue's four build-ready gates **the moment it is authored** (not only
during a sweep), run the dependency-free pre-check over its body. `$SGE_ROOT`
below is resolved via the bootstrap `_sge_root()` function — the copy-verbatim
source of truth is `scripts/resolve-sge-root.sh`'s header comment; never a bare
`${CLAUDE_PLUGIN_ROOT}`, which is empty whenever unset:

```bash
gh issue view 256 --json body --jq .body | node "$SGE_ROOT/skills/lib/build-ready-prescorer.mjs"
node "$SGE_ROOT/skills/lib/build-ready-prescorer.mjs" --body "<draft body>" --json   # structured
```

It names **which** gate failed and why — `criteria` (2A), `scope` (2B, the
out-of-scope section that keeps a PR diff tight), `dependencies` (2D), `decisions`
(2C) — mapped to the `Task` issue form (SGE source repo: `.github/ISSUE_TEMPLATE/task.yml`)'s
structured sections. It is a fast heuristic that reads only the body: it does
**not** run the governance pass (Step 2G) or the sizing heuristic
([`issue-prescorer.mjs`](../../lib/issue-prescorer.mjs)), and it **advises — it never
blocks issue creation** (exit 0 on either verdict; blank issues stay enabled). A
`NOT_READY` here means the same author who has the context can fix the gap before
the sweep ever sees it; a clean issue produces one quiet `READY` line. The
authoritative gate is still the skill's full Step 2 run at dispatch time.
