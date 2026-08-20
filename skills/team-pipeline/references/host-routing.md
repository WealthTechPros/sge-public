# Host routing — Forgejo / non-GitHub repos (ADR-0010, #1146 slice #1240)

Progressive-disclosure reference for team-pipeline's Forgejo/Gitea host path.
See the one-line pointer in SKILL.md's "Host routing" section.

All GitHub (`gh`) calls in this skill assume the target repo is GitHub-hosted.
When the target repo lives on a **Forgejo/Gitea** instance, those calls fail.
Detect the host at pre-flight and branch accordingly — **once per run**, at the
top of Pre-Flight, before any `gh` or adapter call.

```bash
HOST_KIND=$(${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/scripts/with-repo-cwd.sh host 2>/dev/null || echo unknown)
echo "[Pre-flight] host-kind: $HOST_KIND"
```

| `HOST_KIND` | Action |
|---|---|
| `github` | proceed with the existing `gh`-based path — no change |
| `forgejo` | replace every `gh issue`/`gh pr`/`gh label` call with the adapter equivalents (table below) |
| `unknown` | **fail loud** — `echo "BLOCKED: unknown host — no adapter registered; declare the host in SGE_FORGEJO_HOSTS or SGE_GITHUB_HOSTS"; exit 1` — never silently target the wrong repo |

### Forgejo call-site substitution table

For a `forgejo` repo all issue / PR / label operations route through
`${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/scripts/forgejo-adapter.sh` (the single seam — never
scatter raw curl calls into skill bodies). `$ORIGIN` is the target repo's
`git remote get-url origin`.

| Phase / step | `gh` command (github path) | Adapter equivalent (forgejo path) |
|---|---|---|
| **Phase 0** — create agent-lock label | `gh label create "agent-lock" --color "D93F0B" --description "..."` | `FORGEJO_ADAPTER_ALLOW_WRITE=1 forgejo-adapter.sh create-label "$ORIGIN" agent-lock D93F0B "Issue claimed by a pipeline agent"` |
| **Phase 1** — list open issues | `/sge:available-issues` (uses `gh issue list`) | `forgejo-adapter.sh list-issues "$ORIGIN"` → parse JSON array; apply dependency gate on the result |
| **Phase 3b** — count open PRs (CI gate) | `gh pr list --state open \| wc -l` | `forgejo-adapter.sh list-prs "$ORIGIN" \| jq 'length'` (or `grep -c '"id"'` without jq) |
| **Phase 3c** — claim issue (add agent-lock) | `gh issue edit $N --add-label "agent-lock"` | `LABEL_ID=$(forgejo-adapter.sh get-label "$ORIGIN" agent-lock \| jq -r .id)` then `FORGEJO_ADAPTER_ALLOW_WRITE=1 forgejo-adapter.sh add-label "$ORIGIN" $N "$LABEL_ID"` |
| **Phase 3c** — release claim (remove label) | `gh issue edit $N --remove-label "agent-lock"` | `FORGEJO_ADAPTER_ALLOW_WRITE=1 forgejo-adapter.sh remove-label "$ORIGIN" $N "$LABEL_ID"` |
| **Phase 4** — read PR state | `gh pr view $PR --json mergeable,isDraft,...` | `forgejo-adapter.sh get-pr "$ORIGIN" $PR` |

### Forgejo: impl-agent prompt addendum (#1240)

When spawning an impl agent (`Task "impl-<N>"`) for a Forgejo-hosted repo,
extend the standard Lean Agent Contract prompt with:

> ```
> Host: forgejo
> ORIGIN=$(git remote get-url origin)
> After the first commit, open the draft PR via the adapter:
>   FORGEJO_ADAPTER_ALLOW_WRITE=1 \
>     ${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/scripts/forgejo-adapter.sh create-pull \
>     "$ORIGIN" "$(git rev-parse --abbrev-ref HEAD)" main \
>     "<title>" --draft <<'BODY'
>   Part of owner/repo#<N>
>   BODY
> (Never use `gh pr create` — `gh` cannot see the Forgejo remote.)
> ```

### Token and allow-list prerequisites (Forgejo)

The adapter is a no-op (fails loud) when:
- `FORGEJO_API_TOKEN` (preferred) or `GITEA_TOKEN` is not set — set via Doppler.
- The target host is not in `SGE_FORGEJO_HOSTS` (`;`-separated bare hosts) or
  `SGE_FORGEJO_DEFAULT_HOST` — add it to the fleet's env config before running.

These checks surface at the first authenticated call and block further dispatch;
they are never silently swallowed.

---
