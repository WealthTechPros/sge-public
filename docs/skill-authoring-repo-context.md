# Skill authoring convention: explicit repo context (fail loud, never ambient)

**Status:** Convention in force (SPEC-057, issue #817)
**Applies to:** every skill, sub-agent prompt, or helper script in this repo that shells out to `gh` or `git`.

## The rule

> Every skill that shells out to `gh`/`git` must resolve its repo context **explicitly, before the first such call** — and must **fail loudly** when it cannot, never proceeding against whatever repo the shell happens to be in.

SGE sessions run hub-and-spoke: a control session in a hub checkout (e.g. an org hub repo) dispatches work into per-repo checkouts. Any `gh`/`git` invocation that relies on the ambient working directory is *correct in-repo and silently wrong from a hub* — no error, just another repo's issues, PRs, or refs (observed live: `available-issues` discovery, `sge-implement` Phase 5 review dispatch, `pr-labels.sh` head convergence — see SPEC-057 §1). A wrong-repo read/write is worse than a blocked skill.

## The helper: `scripts/with-repo-cwd.sh`

One shared implementation of "resolve target repo → local checkout, or refuse". Do not hand-roll per-skill variants.

```bash
# Pattern 1 — resolve + cd (most skills):
cd "$(scripts/with-repo-cwd.sh resolve OWNER/REPO)" || exit 1

# Pattern 2 — one-shot command in the target repo (GH_REPO exported for you):
scripts/with-repo-cwd.sh exec OWNER/REPO -- gh issue list --state open

# Pattern 3 — sourced, for multi-step scripts:
source scripts/with-repo-cwd.sh
with_repo_cwd OWNER/REPO || exit 1     # cd + export GH_REPO, or loud non-zero

# Pattern 4 — assert-before-write (issue #1558): confirm the repo a bare `gh`
# call would ACTUALLY target now (GH_REPO, else gh's resolved default/remote
# precedence, else origin) equals OWNER/REPO before a cross-repo write. Fuse it
# to the write with `-- <cmd>` so the guard cannot be split from the write
# across tool calls; it fails closed on any mismatch or a bare-name target:
scripts/with-repo-cwd.sh assert-repo OWNER/REPO -- \
  gh issue comment "$N" --body "…"
```

Accepted targets: `name`, `owner/name`, or any GitHub URL (`https://github.com/owner/name/issues/123` — so an issue/PR's repository URL can be passed straight through). Checkouts are found under `SGE_CHECKOUT_ROOTS` (`;`-separated), the parent directory of the current checkout (sibling-clone hub layout), or the parent of the checkout containing the helper. A candidate is only accepted when its git `origin` actually matches the requested repo — a directory with the right name but the wrong origin is rejected and reported.

## Rules for skill authors

1. **Resolve once at entry, re-enter every call.** Shell state does **not** persist across agent tool calls — an exported `GH_REPO` or a `cd` in one Bash call is gone in the next. Put the `cd "$(… resolve …)"` (or `exec` form) at the **top of every shell call** that touches `gh`/`git`, not just the first.
2. **`GH_REPO` alone is not enough.** It is a `gh`-only mechanism: plain `git` (ls-remote, fetch, push) ignores it, and `gh repo view` prefers local-repo detection over `GH_REPO` when run from inside *any* git checkout. Being in the right directory is the only mechanism that covers both tools.
3. **Fail loud, never fall through.** If the target repo cannot be resolved — not passed as an argument, not derivable from the issue/PR in hand — the skill must error and ask, not proceed against the ambient checkout. The helper already refuses for you; do not catch its failure and continue in cwd.
4. **Derive the target from the work item when you can.** An issue or PR carries its repository (`gh … --json url`, or the caller's `owner/repo#N` reference); pass that to the helper rather than assuming the session's checkout.
5. **Sub-agent dispatches inherit the hazard.** A prompt dispatched to a sub-agent starts in the parent's cwd. Dispatching skills must state the target repo (and ideally the resolved absolute path) in the dispatch prompt, and the dispatched work must still run the helper itself.
6. **Assert before every cross-repo write (issue #1558).** A resolved `cd`/`GH_REPO` at entry can still be undone by an ambient `GH_REPO`, a non-`origin` gh-resolved default, or a same-numbered issue in the wrong repo — and a matching issue *number* does not prove a matching *repo*. Immediately before any `gh` write (comment, label, edit), run `assert-repo OWNER/REPO` (ideally the `-- <cmd>` fused form) so a wrong-repo write fails closed instead of landing an artefact on an unrelated repo/PR.

## The execution-repo issue-body field (issue #863)

An issue can be **tracked** in one repo but **executed** in another — its worktree, `agent-lock`, and PR belong in the execution repo, while status/labels stay on the tracking issue. (Observed live: `sge#798`'s deliverable lived in `web-app`; a decomposition's children `sge#839/#840` executed in the org hub repo.) Without a structured signal, a hub/pipeline assumes issue-repo == execution-repo and sets up the worktree/lock in the wrong place.

### Grammar (canonical)

A single field line in the issue body:

```
Repo: owner/name                # short form — value MUST be owner/name or a GitHub URL
execution-repo: owner/name      # explicit form
exec-repo: owner/name           # alias
```

- The value is `owner/name` or any GitHub URL (an issue/PR URL is accepted and normalised to `owner/name`).
- Keyword matching is **case-insensitive**; `-`, `_`, or a space may separate `execution`/`exec` from `repo`.
- **`Repo: —`** (em dash), `Repo: none`, or **no field at all** means *"executes in the tracking repo"* — the common case.
- The short `repo:` keyword is only treated as the field when its value is slug/URL-shaped, so ordinary prose ("as noted in this repo: …") is never mistaken for it. The explicit `execution-repo:` keyword is **always** the field, so a malformed value there **fails loud**.
- Two field lines naming **different** repos **fail loud** — a hub never guesses which repo to execute in.

### Resolving + validating the field

Do not hand-roll the parse. The helper's `issue-repo` command is the single place to extract and validate it:

```bash
# Given an issue's body + its tracking repo, get the execution repo slug.
# Prints the tracking repo when the field is absent; fails loud when malformed.
EXEC_REPO="$(gh issue view "$N" --json body -q .body \
  | "${CLAUDE_PLUGIN_ROOT}/scripts/with-repo-cwd.sh" issue-repo "$TRACKING_REPO")" || exit 1

# Then resolve the execution repo to a checkout exactly as any other target:
cd "$("${CLAUDE_PLUGIN_ROOT}/scripts/with-repo-cwd.sh" resolve "$EXEC_REPO")" || exit 1
```

**Consumer status (SPEC-057, #863):**
- **`build-ready-audit`** — reports the execution repo per issue and flags cross-repo execution (`executionRepo` in its Step-5 JSON; a column/note in the standalone table).
- **`available-issues`** — surfaces the execution repo per candidate and computes conflict-safety against the **execution** repo's files.
- **`team-pipeline` / `fleet-dispatch` honoring** (worktree/branch/PR in the execution repo; `agent-lock`/status stay on the tracking issue; fleet's per-repo lock keyed on the execution repo) and **`decompose-issue` stamping `Repo:` on children** whose execution repo differs from the parent's — **landed in #1024**.

## Testing

Behavioural harness: `skills/tests/with-repo-cwd.test.sh` (real `git init` sandbox — resolution by name/owner/URL from a hub checkout, origin verification, worktree current-checkout match, exec/sourced modes, the fail-loud refusal, and the `assert-repo` assert-before-write guard incl. gh-resolved-vs-origin divergence and the fused `-- <cmd>` write). Run with `bash skills/tests/with-repo-cwd.test.sh`. The execution-repo field parser (`issue-repo`) has its own harness: `skills/tests/issue-execution-repo.test.sh`.

## Traceability

- Spec: SPEC-057 — Repo-targeting correctness for hub/control sessions (SGE source repo: `docs/specs/SPEC-057-repo-targeting-hub-dispatch.md`) (solution items 1, 3, 4)
- Enabler: issue #817 (this convention + the helper); retrofit of existing call sites: #818 (sweep — S1 landed as #1035, S1b `commit`/`sge-review`/`sge-preflight`/`deep-dive`/`sge-align`/`tidy-worktrees`/`traceability` landed as #1039), #826 (`available-issues`); prior art: #662 / PR #752 (`pr-labels.sh` gh-api fallback slice)
