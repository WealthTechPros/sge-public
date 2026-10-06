# Review tier — risk-tiered review depth (sge#2776)

`/sge:pr-review` used to run at full depth on every PR: a two-line version bump
got the same 10–20 minute, multi-subagent pass as an auth change, and every
delta re-review after a push repeated it. The **review tier** picks the depth
**mechanically from the diff** — a script, never the LLM — so the cheap cases
are cheap and the risky ones keep today's full treatment.

It changes review **depth only**. A `light` PASS still claims `pr-reviewing`,
still posts a real `sge-verdict` (as the review identity), still promotes
`pr-reviewed` through `pr-labels.sh pass`, and every human gate (sensitive-path
auto-merge deny, `hold`, regulated sign-off) applies exactly as before. No PR
skips review. Every review tiers the **whole PR diff by path**: delta tiering
(re-reviews tiered on the delta since the last pass) was dropped on the owner's
decision (sge#2776), together with the verdict `base:` field it needed.

## Computing it

A **required** step, once `DIFF_RISK` is known (Phase 1) and before Phase 2:

```bash
ARG_TIER=$(printf '%s\n' " $ARGUMENTS " | sed -nE 's/.* --review-tier (light|standard|full) .*/\1/p')
RT=$("$SGE_ROOT/skills/pr-review/review-tier.sh" pr "$PR" --floor "${ARG_TIER:-light}" --risk "$DIFF_RISK")
REVIEW_TIER=${RT%%$'\t'*}; REVIEW_TIER_REASON=${RT#*$'\t'}
```

- `--review-tier` is what the review daemon classified at dispatch. It is a
  **floor**: the skill re-derives the tier and keeps the higher one.
- `--risk "$DIFF_RISK"`: a `high` `rl_diff_risk` floors the tier at `standard`.
- Tiers **escalate, never de-escalate, on uncertainty**: an unreadable or
  truncated file list (GitHub's 3000-file `pulls/files` cap), a non-object
  file record, PR metadata, or an unreadable/malformed repo config is `full`.
  Malformed means: any byte other than printable ASCII and tab (a BOM, NUL,
  form feed, NBSP...; lines split on `\n` only, a CR allowed only as a CRLF
  line end), a near-miss list key (indented, quoted, `full_paths :`, another
  case or separator such as `FULL_PATHS:` / `full-paths:`), an inline
  `full_paths: [...]` value, a bare `-` or empty quoted (`- ''`) item, or an
  unbalanced quote. A changed
  path containing a control character (newline, NUL, DEL…) or any non-ASCII
  character is `full` before any glob is tried (`**` does not cross a newline,
  and jq and Python fold Unicode case differently); an unknown path is `standard`.
- An unreadable or truncated head tree, or a head that moved between the file
  list and the tree read, makes every file's mode `unknown`, so nothing is
  `light`. The repo config is read up to 256 KiB in both twins; over that it is
  unreadable (`full`), never a silently truncated list.

## Rules (all changed paths; renames count both names, deletions count too)

| Tier | When |
|---|---|
| **full** | any path on the full list: `.github/**`, `.githooks/**`, `hooks/**`, `.sge/**`, `CODEOWNERS`, `.gitattributes`, infra/IaC (`infra/`, `iac/`, `*.tf`, `*.bicep`, `Pulumi*.yaml`), Docker, `migrations/`, `middleware/`, anything named `*auth*`/`*security*`/`*secret*`/`*credential*`/`*crypto*`/`*password*`, key material, `.env*` — or any input unreadable |
| **light** | every path is light-eligible. Light is an **allowlist**: a regular file (head-tree mode `100644`/`100755`, never a symlink `120000`) that is a doc (`*.md`, `*.markdown`, `*.rst`, `*.adoc`; **not** `*.mdx`, which runs JSX/`import` at build time) at the **top level** or under **`docs/`**, or a **`README.md`** anywhere, and not on the standard list -- any other `.md` (a template, a style guide, a tool's rules dir) is at least `standard`; or a **version-only** edit to `.claude-plugin/*.json` / `marketplace.json` (each run of changed lines is k removed then k added lines, identical pair for pair with version values masked — a moved or swapped version line is a change — and every changed line starts with exactly one `"version"` key at the manifest's own level: indent ≤ 2 in `plugin.json`, ≤ 6 in `marketplace.json`; a nested one such as a plugin `source`'s is not version-only). **Who authored the PR never matters**: there is no dependency-bot rule, so a Dependabot/Renovate manifest or lockfile bump is `standard` like any other (sge#2781 round 3: a bot PR branch accepts web-flow-signed pushes and its title is editable, so neither proves the content) |
| **standard** | everything else (the default), including skill/agent prompts at any depth (`**/skills/**`, `**/prompts/**`, `**/.cursor/**`, `agents/**`, `commands/**`, `.claude/**`, `CLAUDE*.md`, `AGENTS*.md`, `AGENT.md`, `GEMINI*.md`, `CONVENTIONS.md`, `WARP.md`, `.agents/**`, `.windsurf/**`, `.clinerules`, `.kiro/**`, `.roo/**`, `.junie/**`, `.openhands/**`, `.amazonq/**`, `.continue/**`), governance docs (`docs/specs/**`, `docs/decisions/**`) and the agent context loaded into every session (`docs/sge-digest*.md`, `docs/sge/**`, `docs/schemas/**`), which are never light |

Before the built-in `*auth*` globs are matched, the whole words `author`/`authors`/`authored`/`authoring`/`authorship` are masked (they are not auth; `authority`, `authorization` and `authorise` still are). Comment- or whitespace-only diffs are not detected; they fall to `standard`.

**Per-repo extension** — `.sge/review-tier.yml` (the same constrained YAML subset
as `.sge/test-map.yml`), read from the repo's **default branch** (never the PR's
base ref, which its author chooses) so a PR cannot widen its own light list;
the file itself is on the full list. Only an HTTP 404 means "no config"
(the same token has just read the PR's files); any other read failure is `full`.
A `#` starts a comment only after whitespace, so a glob may contain `#`:

```yaml
full_paths:        # escalate (e.g. trust-boundary input handling)
  - 'src/api/**'
standard_paths:    # never light
  - 'docs/runbooks/**'
light_paths:       # widen light (full and standard still win)
  - 'data/*.csv'
```

**Whole PR, every time.** A re-review after a push tiers the whole PR again,
never just the delta: a delta base would have to be bound to the exact head
and base the earlier pass judged, which proved fragile (sge#2781 rounds 2-6),
so it was dropped. The verdict POST is still pinned to the head it judged
(`rl_post_verdict` sends the block's `commit:` as `commit_id`).

## Lean depth plan (sge#2829)

The lean-mode rule: full review depth — the specialist fan-out,
`@security-auditor`, adversarial QA — runs **only on control or security
paths**; every other change gets **one light pass**; and a re-review after a
fix push covers **only the delta**. The plan comes from the script, never the
LLM, once `REVIEW_TIER`, `CONTROL_BEARING` and the review mode are known:

```bash
SEC=0; [ -n "$(rl_security_files "$PR")" ] && SEC=1
PLAN=$("$SGE_ROOT/skills/pr-review/review-tier.sh" depth "$REVIEW_TIER" \
  --control-bearing "$CONTROL_BEARING" --security "$SEC" --mode "$MODE")
# -> review=single|fanout security_auditor=0|1 adversarial_qa=0|1 scope=whole|delta
```

| Plan field | Meaning |
|---|---|
| `review=single` | ONE pass: the native `/code-review` at the dispatch-scaling effort (or, at `light`, the reviewer's own inline read). No Layer 2/3 fan-out. |
| `review=fanout` | the full three-layer review (`full` tier: the control/security path list, extended per repo in `.sge/review-tier.yml`). |
| `security_auditor=1` | `@security-auditor` + `/security-review` run (always at `full`; at `light`/`standard` only on a security-path match). |
| `adversarial_qa=1` | `CONTROL_BEARING=1`: dispatch `/sge:qa-audit --adversarial` (Phase 4.3a blocks without current evidence). |
| `scope=delta` | a re-review after a fix push (`mode: delta`, [`mode-selection.md`](mode-selection.md#re-review-delta-mode)): review only `LAST_SHA..HEAD_SHA` and confirm each prior Blocker/Major is closed — no full re-review. The tier is still computed on the whole PR, so a delta can never lower the depth. |

The plan escalates on uncertainty (an unknown tier is `full`; a trigger that is
not exactly `0` counts as set). Phases 3, 4.1–4.2, 5.5, 6 and 8 run unchanged.
The **Depth per tier** table below still describes what each depth contains;
the plan only decides which of them a PR gets. Tested by
`skills/tests/review-tier-depth.test.sh`.

## Depth per tier

| Tier | Phase 2 | Phase 4 | Model |
|---|---|---|---|
| **light** | ONE inline pass by the reviewer itself — **no subagents, no `/code-review`/`/security-review`**. Read the diff once and check: the change is correct, it adds no secret or credential, and no unexpected path is in the diff. Target under 2 minutes. Only when no reviewer was dispatched at all, `pr-labels.sh pass` runs with `SGE_REVIEW_ATTEST_SKIP=1` (the documented pure-inline escape hatch); never set it after any dispatch. | 4.1–4.2 only (as `T0`) | **sonnet**, never haiku (sge#2776: haiku twice misread an open PR as merged and skipped its review, sge#2790); the daemon raises a haiku route to sonnet, a higher route (opus) is kept |
| **standard** | **one light pass** (lean mode, sge#2829): the native `/code-review` at the [`dispatch-scaling.md`](dispatch-scaling.md) effort, no Layer 2/3 fan-out; **`@security-auditor` and `/security-review` run only when `rl_security_files "$PR"` is non-empty**, adversarial QA only when `CONTROL_BEARING=1` | as today | model routing as today |
| **full** | today's full review: `@security-auditor` on a security-path match **or** any `medium`/`high` dispatch tier | as today | model routing as today |

Phases 3 (quality gates), 5.5 (thread resolution), 6 (verdict) and 8 (promote)
run unchanged at every tier.

## Recording it

Both values go in the verdict block, after `specialist_dispatch`:

```
review_tier: light | standard | full
review_tier_reason: <the one-line reason review-tier.sh printed>
```

The review daemon records the tier it dispatched at in `runs.jsonl`
(`review_tier`, plus `review_tier_reason` with any quoted paths stripped —
the run log carries no PR content). `model_tier` stays the model-routing tier.

The rule lives once, twice implemented: `review-tier.sh` (skill) and
`services/review-daemon-poc/review_tier.py` (daemon), held equal by
`skills/tests/review-tier.test.sh` over `review-tier.fixtures.tsv`.
