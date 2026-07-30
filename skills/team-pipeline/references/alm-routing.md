# ALM routing — Jira / non-GitHub issue trackers (SPEC-105 S2, #1700)

Progressive-disclosure reference for the pipeline's Jira issue-tracker path.
See the one-line pointer in SKILL.md's Pre-Flight section.

The **git host** (where the code lives) and the **ALM backend** (where the work
items live) are *independent*: a repo can be GitHub-hosted yet track its backlog
in Jira — the common enterprise topology behind Epic #1150 (e.g. Multrees
Investor Services runs Jira for business users, Azure DevOps for engineering).
`gh issue list`/`gh issue view` have nothing to list for such a repo.

All **read** issue operations therefore route through the single seam
`scripts/issue-read.sh` (`$IR`), which resolves the ALM backend **before** the
git host and normalises every backend to the same JSON shape. **Never shell
`gh issue list`/`gh issue view` directly in a read path** — call `$IR list` /
`$IR view` so a Jira-tracked repo works unchanged.

```bash
IR="${CLAUDE_PLUGIN_ROOT:-.}/scripts/issue-read.sh"
ALM=$(${CLAUDE_PLUGIN_ROOT:-.}/scripts/with-repo-cwd.sh alm) || exit 1   # DR1: fail loud, never fall back
echo "[Pre-flight] alm-backend: $ALM"
```

| `ALM` | Action |
|---|---|
| `github` (unset/empty) | proceed with the existing `gh`-based path — **byte-identical**; the ALM dimension is dark until a repo declares a non-GitHub tracker (SPEC-105 §3) |
| `jira` | `$IR` routes `list`→**P1 `list-dispatchable`** and `view`→**P2 `view-item`** through `scripts/jira-adapter.sh`; the output shape is unchanged, so the rest of Phase 1 is backend-agnostic |
| *unrecognised* (e.g. `trac`) | **fail loud** naming the value — `with-repo-cwd.sh alm` exits non-zero and `$IR` issues no `gh` and no Jira REST call (DR1); a silent GitHub fallback would dispatch against the wrong tracker |

### Read-path call sites (all via `$IR`)

| Phase / step | Read op | Port call |
|---|---|---|
| **Phase 1** — issue discovery (raw fallback) | P1 `list-dispatchable` | `"$IR" list --state open --limit N \| jq …` |
| **Phase 1** — dependency gate (body parse) | P2 `view-item` | `"$IR" view "$n" \| jq -r '.body // ""'` |
| **Phase 2R** — execution-repo field parse | P2 `view-item` | `"$IR" view "$ISSUE" \| jq -r '.body // ""' \| "$WRC" issue-repo …` |

The preferred discovery path (`/sgd:available-issues`) already reads through
`$IR`, so it inherits Jira routing with no per-call change here.

### Config prerequisites (Jira)

A Jira backend needs, in the pipeline's environment (Doppler-injected — never in
the repo, never logged):

- `SGD_ALM_BACKEND=jira`
- `SGD_JIRA_PROJECT` — the project key P1 `list-dispatchable` enumerates
  (required for `$IR list`; `$IR view <issueKey>` does not need it).
- `SGD_JIRA_BASE_URL` + `SGD_JIRA_HOSTS` (allow-list) and a credential
  (`SGD_JIRA_BEARER`, or `SGD_JIRA_EMAIL` + `SGD_JIRA_API_TOKEN`) — checked by
  `scripts/jira-adapter.sh` at the first call; a missing credential or unlisted
  host **fails loud before any network call**.

On the Jira backend an item id is a Jira **issueKey** (`PROJ-123`), so the
normalised `.number` field is that key string and `.state` is `OPEN`/`CLOSED`
derived from the Jira status **category** (DR2), never a localised status name.

### Out of scope here (later slices)

- **Mutating** ops — claim/release/comment/create and the close-on-merge link
  are **S3** (not routed by `$IR`, which is read-only).
- **P7 `item-dependencies`** (Jira issue links) and **P9 `dispatch-label-config`**
  Jira realisations are **S4**; until then, the body-text dependency gate and
  the awaiting-label report are GitHub-shaped and stay dark on Jira.

---
