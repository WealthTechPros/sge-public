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
| `jira` | `$IR` routes `list`→**P1**, `view`→**P2**, `dependencies`→**P7**, `dispatch-label`→**P9**, `search`→**P10** through `scripts/jira-adapter.sh`; the output shape is unchanged, so the rest of the pipeline is backend-agnostic |
| *unrecognised* (e.g. `trac`) | **fail loud** naming the value — `with-repo-cwd.sh alm` exits non-zero and `$IR` issues no `gh` and no Jira REST call (DR1); a silent GitHub fallback would dispatch against the wrong tracker |

### Read-path call sites (all via `$IR`)

| Phase / step | Read op | Port call |
|---|---|---|
| **Phase 1** — issue discovery (raw fallback) | P1 `list-dispatchable` | `"$IR" list --state open --limit N \| jq …` |
| **Phase 1** — dependency gate (body parse) | P2 `view-item` | `"$IR" view "$n" \| jq -r '.body // ""'` |
| **Phase 1** — dependency gate | P7 `item-dependencies` | `"$IR" dependencies "$n"` |
| **Phase 2R** — execution-repo field parse | P2 `view-item` | `"$IR" view "$ISSUE" \| jq -r '.body // ""' \| "$WRC" issue-repo …` |
| **Phase 6** — find-or-create tracking issue | P10 `search` | `"$IR" search "pipeline runs" --state open --limit 1 \| jq …` |
| **Pre-flight** — dispatch-label resolution | P9 `dispatch-label` | `"$IR" dispatch-label` |

The preferred discovery path (`/sge:available-issues`) already reads through
`$IR`, so it inherits Jira routing with no per-call change here.

### Config prerequisites (Jira)

A Jira backend needs, in the pipeline's environment (Doppler-injected — never in
the repo, never logged):

- `SGE_ALM_BACKEND=jira`
- `SGE_JIRA_PROJECT` — the project key P1 `list-dispatchable` enumerates
  (required for `$IR list`; `$IR view <issueKey>` does not need it).
- `SGE_JIRA_BASE_URL` + `SGE_JIRA_HOSTS` (allow-list) and a credential
  (`SGE_JIRA_BEARER`, or `SGE_JIRA_EMAIL` + `SGE_JIRA_API_TOKEN`) — checked by
  `scripts/jira-adapter.sh` at the first call; a missing credential or unlisted
  host **fails loud before any network call**.

On the Jira backend an item id is a Jira **issueKey** (`PROJ-123`), so the
normalised `.number` field is that key string and `.state` is `OPEN`/`CLOSED`
derived from the Jira status **category** (DR2), never a localised status name.

### Mutating tracker writes route through `$IW` (SPEC-105 S3, #1701)

All **mutating** issue operations — the tracker-side writes the pipeline and
`pr-monitor`/`pr-review`/`sge-implement` perform (claim notices, triage/exit-report
comments, decomposition children, close-on-merge linkage) — route through the
single seam `scripts/issue-write.sh` (`$IW`), the write-path analogue of `$IR`.
It resolves the ALM backend the same way (fail loud on an unrecognised value,
DR1) and, unlike `$IR`, **is** the write opt-in: it sets `JIRA_ADAPTER_ALLOW_WRITE=1`
for its adapter calls. It never sets `JIRA_ADAPTER_ALLOW_CREATE` — that DP3 scope
gate stays the caller's explicit decision, so the common-case dispatch token
cannot create work items. **Never shell `gh issue comment`/`gh issue create`
directly in a write path** — call `$IW` so a Jira-tracked repo's writes land on
the right backend.

```bash
IW="${CLAUDE_PLUGIN_ROOT:-.}/scripts/issue-write.sh"
```

| `ALM` | Action |
|---|---|
| `github` (unset/empty) | `comment`/`create` delegate to `gh` byte-identically; `close-link` is DECLARATIVE — `$IW` prints the `Closes #N` token to embed in the PR body (it does not edit the PR) — use it only when the PR has earned a closing keyword; otherwise the body keeps `Part of #N` (sge-implement/references/close-keyword.md) |
| `jira` | `comment`→**P5 `comment-item`**, `create`→**P6 `create-item`** (needs `SGE_JIRA_PROJECT` + the caller's `JIRA_ADAPTER_ALLOW_CREATE=1`), `close-link`→**P8 `link-close-on-merge`** (records a remote link on the item — Jira has no native PR link, #1150 — plus a close transition when `SGE_JIRA_CLOSE_TRANSITION_ID` is set; a failed write is surfaced loud, never swallowed) |
| *unrecognised* | **fail loud** naming the value (DR1); no `gh` and no Jira REST write |

| Phase / step | Write op | Port call |
|---|---|---|
| **Phase 1/2** — claim notice, triage, exit report | P5 `comment-item` | `"$IW" comment "$n" "$body"` |
| **Decomposition** — child work items | P6 `create-item` | `JIRA_ADAPTER_ALLOW_CREATE=1 "$IW" create "$title" "$body"` |
| **PR handoff** — close-on-merge linkage | P8 `link-close-on-merge` | `"$IW" close-link "$n" "$pr_url"` (github: embed the printed token — only when the PR has earned a closing keyword; else `Part of #N`, see sge-implement/references/close-keyword.md) |

### PR comments are NOT tracker writes — they stay on `gh`

The port covers **issue-tracker** operations (SPEC-105 §2.1, P1–P9). A comment on
the **pull request** is a *code-host* write, not a tracker write: the PR lives on
GitHub even when the work items live in Jira, and the port has no operation for
it. So `pr-monitor`'s status comments (held-review, abandoned-draft,
conflicting-branch, GitHub-degraded) and `pr-review`'s verdict correctly remain
`gh pr comment` / `gh pr review` — routing them through `$IW` would post a PR
status note onto an unrelated Jira issue.

The rule is the target, not the verb: **`gh issue …` in a write path is a bug on a
Jira repo; `gh pr …` is correct on every backend.** What S3 gives `pr-monitor` and
`pr-review` is the ability to write to the *tracker* when they need to (via `$IW`);
it does not move their PR-surface commentary.

### Out of scope here (later slices)

- **P7 `item-dependencies`** (Jira issue links) and **P9 `dispatch-label-config`**
  Jira realisations are **S4**; until then, the body-text dependency gate and
  the awaiting-label report are GitHub-shaped and stay dark on Jira.
- **Claim/release** (P3/P4) remain `available-issues`/`team-pipeline` concerns via
  the jira-adapter transition verbs (S1); `$IW` covers the comment/create/close
  surface S3 adds.

---
