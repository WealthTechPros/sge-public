# team-pipeline — dispatch prompt templates

The exact `Task` prompt templates the orchestrator pastes when spawning each
agent. Every agent is a **named `Task`** (never `Agent(isolation:"remote")` and
never a detached background `Agent`) so `TaskStop "<name>"` can terminate it.
The operational contract each agent must honour (budgets, lean rules,
governance gate, draft-PR discipline) is stated in core SKILL.md; these are the
concrete prompts that encode it.

---

## Shared: GitHub API budget discipline (issue #1153)

**Every dispatched agent draws `gh` calls from the SAME org/token-scoped REST
rate-limit bucket (5000/hr).** Under real fan-out (a dozen impl/review/monitor
lanes at once — the exact scenario this pipeline exists for) that shared bucket
becomes an invisible synchronisation point: the more lanes you correctly run,
the faster it hits 0/5000 and *every* lane stalls in lockstep. GraphQL has a
**separate** 5000/hr bucket. So the standing rule for all lanes below:

1. **GraphQL-first for anything with a GraphQL equivalent.** PR/issue state
   reads, review posting (`addPullRequestReview`), label add/remove
   (`addLabelsToLabelable` / `removeLabelsFromLabelable`), auto-merge
   (`enablePullRequestAutoMerge`), merge (`mergePullRequest`) — use
   `gh api graphql` by default. Fall back to plain `gh`/REST only for calls
   with no GraphQL equivalent.
2. **Floor-check before a REST burst.** Before a run of REST calls, read the
   remaining budget once — `gh api rate_limit --jq '.resources.core.remaining'`
   (near-zero cost) — and if it is low (say < 100), route the burst through
   GraphQL instead and note the throttle in your status output.
3. **On any REST 403/429 rate-limit response, switch to GraphQL immediately**
   for the rest of your run rather than waiting for the reset — GraphQL is a
   live escape hatch with a separate quota. Do not busy-loop retrying the same
   REST call.
4. **Log a rate-limit stall distinctly** in your status/JSON output (e.g.
   `"note":"rate-limited: switched to GraphQL"`) so a stall caused by quota is
   immediately distinguishable from any other stall.

Skills that shell `gh` internally (`/sge:pr-review`, `/sge:pr-monitor`) already
carry rate-limit detection + GraphQL fallback in `review-lib.sh` / `pr-labels.sh`
(#1147); when the wtp-sge App credentials (`SGE_REVIEW_APP_*`) are present those
libs route through the 15000/hr App tier via `rl_gh` (#1149). These four rules
are the agent-prompt-level default that the orchestrator must not have to
discover and instruct by hand mid-session.

---

## Shared: front-loaded governance verdict (issue #1266)

**The wave is batch-classified ONCE, up front — per-lane governance-trace forks
are the exception, not the rule.** `/sge:build-ready-audit`'s #872 fold already
runs `/sge:governance-trace` over N issues in a single hop and returns a
`results[]` array with a `governance` verdict per issue. The orchestrator runs
that fold as the default Phase 1.5 step (see core SKILL.md) and, when it spawns a
lane, **injects that issue's verdict into the lane prompt** as `SGE_GOVTRACE_VERDICT`.

The impl-lane's Step 3 gate then **adopts the front-loaded verdict** instead of
forking its own `/sge:governance-trace` — the adopt-on-exact-issue-match rule
`/sge:sge-implement` Phase 0.5 already applies. The env var carries the verdict as
compact JSON, e.g.:

```
SGE_GOVTRACE_VERDICT={"issue":<N>,"verdict":"MATCHES_EXISTING","matchConfidence":"high"}
```

**Opt-out / fallback (documented default).** A lane forks its own per-lane
`/sge:governance-trace` **only** when `SGE_GOVTRACE_VERDICT` is unset, empty, its
`issue` field does not equal `<N>` (stale/mismatched — never trust a verdict for a
different issue), or its `verdict` is missing/malformed. Any issue the batch could
not classify (dropped, errored, or `--skip-governance` was passed) simply arrives
with no `SGE_GOVTRACE_VERDICT`, and the lane falls through to the per-lane fork
exactly as before — the gate is never skipped, only its fork is front-loaded away.

This removes the 10–15 min/lane fork (#10729, ppp) for the common case while
keeping the blocking gate intact for every branch.

---

## Shared: unattended env propagation (#2487)

**`SGE_UNATTENDED=1` does not reach a dispatched lane's hooks on its own.**
`hooks/design-gate.sh` and `hooks/ui-edit-tracker.sh` (SPEC-115, the design-
quality Stop/PostToolUse hooks force-installed via `hooks/hooks.json`) stand
down only when `SGE_UNATTENDED=1` is present in *their own* process
environment. Those hooks are fresh processes the harness spawns per hook
event for the lane's own session — they inherit whatever the **lane**
exported via its own Bash tool calls, never a var the orchestrator merely
`export`ed in its own, separate session. (This is the identical mechanism
`SGE_AGENT_ID` already relies on for token-meter attribution — see "Steps"
Step 0 in the impl-lane prompt below.)

**So:** whenever the orchestrator dispatching a lane is itself running
unattended (`--unattended` was passed to it, or `SGE_UNATTENDED=1` was
already set in its own environment), every dispatched lane's prompt — impl,
review, and pr-monitor alike — must include an explicit `export
SGE_UNATTENDED=1` as an early step, exactly as it already includes `export
SGE_AGENT_ID=...`. Omit it entirely (do not export `SGE_UNATTENDED=0` or
leave it blank) when the orchestrator itself is attended — attended lanes
keep the design-gate enforcement active, which is correct.

**This does not weaken the merge gate.** `SGE_UNATTENDED=1` PRs are NOT
exempt from `/sge:pr-review`'s design-evidence check (`references/design-
evidence.md`) — only the mid-run session hooks stand down; the PR-level gate
is the sole enforcement point left for an unattended UI-touching lane, by
design.

---

## PR monitor (Phase 2) — Task name `"pr-monitor"`

```
Task name: "pr-monitor"
Prompt:
  You are the PR monitor for this team-pipeline session.

  ## Budget contract (self-discipline — see team-pipeline's "Per-Task
  ## Budget Contract" section; there is no SDK enforcement of this number)
  Target ceiling: 40 000 output tokens. If you estimate you are approaching
  it, wrap up your current cycle cleanly. The orchestrator's time-box is
  the actual stop if you run long regardless — this number is a target,
  not a hard limit you will be interrupted at.

  ## GitHub API budget (see "Shared: GitHub API budget discipline", #1153)
  Prefer `gh api graphql` for reads/label/merge ops; floor-check
  `gh api rate_limit` before REST bursts; on a REST 403/429 rate-limit, switch
  to GraphQL for the rest of the run and log the stall distinctly. You share
  ONE REST bucket with every sibling lane.

  <IF the orchestrator dispatching you is itself running unattended
  (--unattended was passed, or SGE_UNATTENDED=1 was already set in its own
  environment), run this FIRST, before anything else, and keep it exported
  for your whole run (#2487 — see "Shared: unattended env propagation"
  above; this stands down hooks/design-gate.sh and hooks/ui-edit-tracker.sh
  for any file edit you make, e.g. via a dispatched /sge:pr-fix):>
    export SGE_UNATTENDED=1

  Run /sge:pr-monitor continuously until the orchestrator signals you to stop.

  After each action, append one JSON line to /tmp/team-pipeline-prmonitor.log:
    {"ts":"<ISO>","pr":<N>,"action":"pr-fix|pr-review|rerun|merged","outcome":"success|failed"}

  You are a DISPATCHED subagent, not a top-level session — `gh pr checks
  --watch` does not hold your turn open here (loops §B; #1681, #2225). Use
  /sge:pr-monitor's own subagent fallback instead: an adaptive bounded
  synchronous poll in ONE tool call (~30s interval while any lane is active,
  ~90s once every lane is merely queued — see pr-monitor SKILL.md's "the
  clock" section). At the end of each cycle, read /tmp/team-pipeline-state.json.
  If prMonitorStatus == "stop", finish your current cycle then exit.

  Do NOT implement issues. Only monitor and fix PRs.
```

The `Task` name `"pr-monitor"` is what allows `TaskStop "pr-monitor"` to work in
Phase 6. **Do NOT spawn this as a detached background Agent or with
`isolation: "remote"`.**

---

## Implementation lane (Phase 3c) — Task name `"impl-<N>"`

Dispatched via `Agent(name: "impl-<N>", model: <tier>)` — `<tier>` is the
queue entry's Phase 1.5-resolved model tier (`haiku`/`sonnet`/`opus`, #2488;
resolved via `resolve-tier.sh`, looked up from `tierMap` —
[commands](mechanisms.md#per-lane-model-tier-2488)). Naming it `"impl-<N>"`
keeps it a stoppable "named Task" per the Stoppable-Only Fan-Out Rule —
`model` changes which model the lane runs on, not its stoppability.

```
Task name: "impl-<N>"
Model tier: <tier>   # haiku | sonnet | opus — Phase 1.5 batch resolution (#2488)
Prompt:
  Implement GitHub issue #<N> (tracked in <TRACKING_REPO>).
  Execution repo: <EXEC_REPO>  (where the branch + PR live; == the tracking
    repo unless the issue carried an execution-repo field — SPEC-057 #1024)
  Worktree: <EXEC_WT_BASE>/issue-<N>  (already created in the EXECUTION repo's
    checkout — do NOT re-create it)
  Branch: ${SGE_BRANCH_PREFIX:-fix/issue-}<N>  (env-parameterized; see Branch prefix below)
  SGE_GOVTRACE_VERDICT: <the wave's front-loaded governance verdict for this
    issue, injected by the orchestrator's Phase 1.5 batch pre-classification;
    absent when the batch could not classify this issue — see Step 3 / "Shared:
    front-loaded governance verdict", #1266>
  SGE_UNATTENDED: <"1" when the orchestrator dispatching you is itself running
    unattended (--unattended or SGE_UNATTENDED=1 in its own environment), else
    absent — see Step 0 below and "Shared: unattended env propagation", #2487>


  ## Budget contract (self-discipline — see team-pipeline's "Per-Task
  ## Budget Contract" section; there is no SDK enforcement of this number)
  Target ceiling: 250 000 output tokens. If you estimate you are approaching
  it, stop expanding scope now: commit what you have, push, open/update the
  draft PR, and terminate. This is a target you are expected to self-police
  — the orchestrator's stale/hard-kill time-box is the actual backstop if
  you overrun it, not a token-count interrupt.

  ## Lean agent contract (MANDATORY — read before doing anything)

  You are a gate-then-build-then-draft agent. Your job is:
    1. Run the /sge:governance-trace gate for the issue headlessly (Step 3
       below); on a blocking verdict, report outcome "blocked" and terminate
       WITHOUT building
    2. Build the change (implement the issue in the worktree provided)
    3. Open a DRAFT PR as soon as you have a first commit
    4. Terminate — report your result, then stop

  Three hard rules that constrain everything else:

  ### Rule 1 — Capped reconnaissance
  Use ONLY the file-map in the issue body (or the preflight report already
  posted as an issue comment) to orient yourself. Do NOT run open-ended
  searches (grep -r, find, rg --glob, reading directories recursively) to
  "understand the codebase" before starting. You have the file-map; that is
  your recon budget. Read only the files listed there plus files you directly
  need to edit. If the file-map is missing, read at most 5 files to locate
  the implementation surface, then build.

  ### Rule 2 — Draft PR on first commit
  After your FIRST commit (even if partial), immediately push and open a DRAFT
  PR IN THE EXECUTION REPO. Your cwd is the execution repo's worktree, so `gh`
  targets it automatically. The reference must reach the TRACKING issue:
  same-repo -> `Part of #<N>`; cross-repo (execution repo != tracking repo) ->
  the fully-qualified `Part of <TRACKING_REPO>#<N>` so the PR still links to the
  tracking issue when it merges in another repo.
  Use `Part of`, NEVER `Fixes`/`Closes` (issue #2241): this PR is opened on your
  FIRST commit and is incomplete by construction, so a closing keyword would
  auto-close the tracking issue on merge while ACs remain. Pass `--base`
  EXPLICITLY (issue #2486) — an omitted `--base` silently falls through to the
  repo's GitHub default branch instead of the base your worktree was actually
  branched from. `SGE_BASE_BRANCH` (default `main`) is exported once in the
  shared pipeline environment the same way `SGE_BRANCH_PREFIX` is (see [Branch
  prefix](#branch-prefix)) — every lane, including yours, inherits it; do not
  hardcode `main`. The closing keyword is decided at completion, not here:
    git push origin "${SGE_BRANCH_PREFIX:-fix/issue-}<N>"
    # same-repo:
    gh pr create --draft --base "${SGE_BASE_BRANCH:-main}" --title "<conventional title>" --body "Part of #<N>"
    # cross-repo (execution repo != tracking repo), e.g. Part of owner/repo#<N>:
    gh pr create --draft --base "${SGE_BASE_BRANCH:-main}" --title "<conventional title>" --body "Part of <TRACKING_REPO>#<N>"
  Do NOT wait until all work is done to open the PR. Opening it early surfaces
  the branch to CI and lets the orchestrator detect you are making progress.

  ### Rule 3a — GitHub API budget discipline (issue #1153)
  You share ONE org REST rate-limit bucket with every sibling lane. Per
  "Shared: GitHub API budget discipline" above: prefer `gh api graphql` for
  reads (issue/PR state) over `gh issue view`/`gh pr view` REST when a burst is
  likely; floor-check `gh api rate_limit --jq '.resources.core.remaining'`
  before a REST burst and route through GraphQL when it is low; on any REST
  403/429 rate-limit, switch to GraphQL for the rest of your run rather than
  waiting for the reset; and note a rate-limit stall distinctly in your
  completion-file `note`.

  ### Rule 3 — Cheap inline quality gates only
  Run ONLY these three cheap checks inline (before final push, so your DRAFT
  PR opens clean):
    - Type-check / static analysis (the repo's typecheck command from CLAUDE.md)
    - The specific test(s) you wrote or touched for this change
    - The repo formatter in WRITE mode over ONLY the files you created/changed
      (e.g. feed `git diff --name-only` to it), then stage the result. DISCOVER
      the format command the way /sge:pr-fix does (skills/pr-fix/SKILL.md
      "Stack-agnostic by design"): read the repo's CLAUDE.md, its package.json
      scripts, and its pre-commit config for the command CI's Format Check runs
      (a `format` / `format:write` npm script, or a formatter pre-commit hook) —
      NEVER hard-code `prettier`.
      WHY this gate exists: in one real run two lanes went red on Format Check
      purely because they never formatted files they had created. A write-mode
      format of only your touched files fixes that at negligible cost.
  Do NOT run the full test suite, linter, whole-repo format-check, or
  build-storybook here — those (the repo-wide `format:check` included) belong to
  the separate /sge:pr-review step after you terminate.
  Running the full battery is what burned 20–50 min per agent before; don't.

  ## Steps

  0. Export the lane's telemetry tag so ${CLAUDE_PLUGIN_ROOT:-.}/hooks/token-meter.sh
     attributes your MEASURED per-turn usage to this lane (used by the
     orchestrator's real token accounting — #857; do NOT self-report a token
     count anywhere):
       export SGE_AGENT_ID="impl-<N>"
     <IF the orchestrator dispatching you is itself running unattended
     (--unattended was passed, or SGE_UNATTENDED=1 was already set in its own
     environment), ALSO run:>
       export SGE_UNATTENDED=1
     <#2487 — hooks/design-gate.sh and hooks/ui-edit-tracker.sh (SPEC-115) are
     fresh processes spawned per hook event; they only see this if YOU export
     it in your own session, not because the orchestrator has it set. Without
     it, editing a UI file (.tsx/.jsx/.vue/.svelte/.css/.scss/.less/.html)
     mid-lane triggers a nudge and then a Stop-hook block waiting on a design-
     reviewer verdict nobody unattended can produce, and the lane runs to the
     45-minute hard-kill instead of terminating cleanly. The pr-review merge
     gate (design-evidence.md) still enforces design evidence for these PRs —
     SGE_UNATTENDED only stands down the mid-run session hooks, not the gate.>
     Keep both exported for the whole lane so every metered turn — and every
     hook invocation — carries them.
  1. cd to the worktree (<EXEC_WT_BASE>/issue-<N>, in the EXECUTION repo's
     checkout) and verify pwd — every `gh`/`git` call then targets the
     execution repo, per SPEC-057 (docs/skill-authoring-repo-context.md)
  2. Read the issue: gh issue view <N> --json title,body,comments
     Extract the file-map and acceptance criteria. This is your entire recon.
  3. Governance-trace gate (MANDATORY — before writing any code). First, if the
     orchestrator injected SGE_GOVTRACE_VERDICT and its "issue" == <N>, ADOPT it
     as the verdict and skip the fork (per "Shared: front-loaded governance
     verdict", #1266; the same adopt-on-exact-issue-match rule sge-implement
     Phase 0.5 uses). Otherwise (unset/empty/mismatched-issue/malformed) dispatch
     via Agent, never Skill(args=) (issue #2452 — Skill(args=) does not fork, so
     args is never received): Agent({description: "Governance-trace classify
     issue <N>", subagent_type: "general-purpose", prompt: "Invoke
     sge:governance-trace ... Issue number <N>, repo <owner/repo> — read
     directly, don't rely on args= threading. Verify mode (--spec SPEC-NNN) when
     the issue title/body cites a spec id, classify mode otherwise. ..."}). Either
     way,
     branch on the resulting verdict exactly as /sge:sge-implement Phase 0.5 does
     when dispatched headlessly:
       - MATCHES_EXISTING / NO_SPEC_WARRANTED / NOT_ONBOARDED, with
         matchConfidence not "low" -> proceed to step 4.
       - MATCHES_EXISTING_MODIFIED, NEEDS_NEW_SPEC, NOT_SGE_SCOPE, or
         matchConfidence == "low" (whatever the verdict) -> do NOT build.
         Write /tmp/team-pipeline-agent-<N>.json using the exact schema of
         /sge:sge-implement Phase 0.5's *Headless completion contract*:
           {"issue":<N>,"outcome":"blocked","prNumber":null,"completedAt":"<ISO>","tokensUsed":<N>,"note":"governance-trace: <one line — what's blocked and why>"}
         then terminate without building. Never guess, never auto-override —
         the orchestrator's Phase 4 branch 4a parks the issue for a human.
  ### BDD Quality Rules (mandatory for all BDD wave agents)

  When the issue or spec includes Gherkin acceptance-criteria scenarios, or
  when you write new ones, every scenario MUST satisfy all five rules before
  you commit any implementation:

  1. **Never leave a Then vague.** Name the exit code, HTTP status, exact
     output string, or specific field value. "Resolves correctly", "succeeds",
     "works as expected" are NOT assertions.

  2. **Define units for every threshold and SLO inline.** Write "within 500
     milliseconds" not "within the defined SLO". If threshold is config-driven,
     assert the config key and value in the Given step.

  3. **Collapse repeated-shape scenarios into Scenario Outline + Examples
     table.** Whenever two or more scenarios differ only in one or two values,
     use an Outline — eliminates copy-paste drift and makes intent legible.

  4. **Anchor Given to observable system state, not private bug references.**
     "Given the scenario from issue #656" is invisible to the test runner.
     Restate the observable precondition the test can actually set up.

  5. **One unhappy-path scenario per happy-path cluster.** Every feature must
     cover at least one failure mode (missing input, unreachable dependency,
     schema mismatch, permission denied) with a concrete Then — not "fails
     gracefully" but what the user or caller actually sees.

  See: platform/docs/sgd-build/bdd-quality-rules.md (examples + audit evidence)

  4. Implement the change (TDD for each acceptance criterion — failing test,
     then minimum code to green). Commit each slice via /sge:commit --no-push.
     Every commit MUST carry a `Spec: SPEC-NNN` or `SGE-Override: <STEP>; <reason>`
     trailer — /sge:commit derives it mechanically (its step 5) from the issue/
     branch; a trailer-less commit fails the require-commit-trailer CI gate.
  5. After the FIRST commit: push + open DRAFT PR (Rule 2 above).
  6. Continue implementing remaining slices and committing (--no-push each).
  7. Run cheap inline gates (Rule 3): typecheck + touched tests + the repo
     formatter (write mode) over your created/changed files — discovered per
     Rule 3, never hard-coded `prettier`; stage the result. Fix failures.
  8. Final push: git push origin "${SGE_BRANCH_PREFIX:-fix/issue-}<N>"  (updates the already-open PR)
  9. Write result to /tmp/team-pipeline-agent-<N>.json:
       {
         "issue":<N>,
         "outcome":"success|blocked|failed",
         "prNumber":<N or null>,
         "completedAt":"<ISO>",
         "note":"<one line>",
         "decisionJournal": [
           {"specId":"<SPEC-NNN or null>","trigger":"<ambiguity description>","optionTaken":"<what was done>","rationale":"<why this is most reversible>"}
         ]
       }
     `decisionJournal` contains one entry for each SPEC-093 tier-b decision made
     during the run (most-reversible-option fallback — not a spec rule, not a
     BLOCKED exit). Omit the field or use an empty array `[]` when no tier-b
     decisions were made. This array is the source for the `questions-per-run`
     metric (#1235) — Phase 6 sums its length across all lanes.
     Do NOT self-report a token count: `tokensUsed`
     is DEPRECATED (#857) and the orchestrator no longer reads it for any budget
     or accounting decision — real spend comes from the harness-measured
     token-meter records (see *Durable token-usage persistence*). If a
     `tokensUsed` field is still present (legacy sge-implement Phase 0.5 shape),
     it is treated as non-authoritative and used only for the visible
     measured-vs-reported divergence check, never as the spend figure.
  10. Terminate. Do NOT run /sge:pr-review. The review agent handles that.
```

The `Task` name `"impl-<N>"` is what allows `TaskStop "impl-<N>"` to work during
stall detection (Phase 4). **Do NOT use `Agent(isolation:"remote")` or a
detached background Agent — they are invisible to `TaskStop` and cannot be
killed.**

> **Completion-file shape.** The per-lane completion file is the
> *completion-file channel* of the shared [`exit-report`](../../exit-report/SKILL.md)
> contract. The lane shape above is the documented legacy shape — it stays
> as-is because it is shared verbatim with `/sge:sge-implement` Phase 0.5's
> *Headless completion contract* (whose retrofit that skill's own #730 slice
> owns); consumers bridge it via exit-report's *Mapping from the legacy
> shapes* table (`issue`→`item`, `outcome`→`status`, `prNumber`→`pr`,
> `note`→`detail`; `tokensUsed`/`completedAt` ride as extension fields). The
> **run-level** report this orchestrator emits at Phase 6 uses the shared
> schema directly.

---

## Review agent (Phase 3d) — Task name `"review-<PR_NUMBER>"`

Review agents are NOT resource-gated. Spawn one when a completion file has
`outcome == "success"` and a `prNumber`.

```
Task name: "review-<PR_NUMBER>"
Prompt:
  Review PR #<PR_NUMBER> (implements issue #<ISSUE>).
  The PR lives in the EXECUTION repo <EXEC_REPO> (== the tracking repo unless
  the issue carried an execution-repo field — SPEC-057 #1024). Resolve that
  checkout FIRST so every gh/git call targets it, then review:
    cd "$("${CLAUDE_PLUGIN_ROOT:-.}/scripts/with-repo-cwd.sh" resolve <EXEC_REPO>)" || exit 1

  ## Budget contract (self-discipline — see team-pipeline's "Per-Task
  ## Budget Contract" section; there is no SDK enforcement of this number)
  Target ceiling: 60 000 output tokens. If you estimate you are approaching
  it, post your findings as-is and terminate rather than expanding scope.

  ## GitHub API budget (see "Shared: GitHub API budget discipline", #1153)
  You share ONE org REST bucket with every sibling lane. Prefer `gh api graphql`
  for PR/issue state reads and for posting the review verdict/labels where a
  GraphQL mutation exists; floor-check `gh api rate_limit` before REST bursts;
  on a REST 403/429 rate-limit, switch to GraphQL for the rest of the run and
  log the stall distinctly. (/sge:pr-review's own libs already do this
  internally per #1147/#1149.)

  <IF the orchestrator dispatching you is itself running unattended
  (--unattended was passed, or SGE_UNATTENDED=1 was already set in its own
  environment), run this FIRST and keep it exported for your whole run
  (#2487 — see "Shared: unattended env propagation" above):>
    export SGE_UNATTENDED=1

  Steps:
  1. gh pr diff <PR_NUMBER>
  2. Run /sge:pr-review #<PR_NUMBER>
  3. If no blocking issues:
       gh pr review <PR_NUMBER> --approve --body "LGTM -- auto-review passed."
       gh pr ready <PR_NUMBER>
       Write: {"pr":<PR>,"issue":<N>,"outcome":"approved","completedAt":"<ISO>"}
  4. If blocking issues:
       gh pr review <PR_NUMBER> --request-changes --body "<findings>"
       Write: {"pr":<PR>,"issue":<N>,"outcome":"changes_requested","completedAt":"<ISO>"}

  Write to: /tmp/team-pipeline-review-<PR_NUMBER>.json
```

The `Task` name `"review-<PR_NUMBER>"` enables `TaskStop "review-<PR_NUMBER>"`
during the review-stall threshold (Phase 4). **Do NOT use
`Agent(isolation:"remote")` or a detached background Agent for review fan-out.**

---

## Branch prefix

Every lane's branch is named `${SGE_BRANCH_PREFIX:-fix/issue-}<N>` where `SGE_BRANCH_PREFIX`
defaults to `fix/issue-`, so unset it (or leave it unset) to keep the existing
`fix/issue-<N>` convention — no change for existing callers. The worktree/branch
is created once by the orchestrator (Phase 3c / `mechanisms.md`); lane agents
push and open PRs against whatever name that produced, so the prefix flows
through automatically. `/sge:available-issues --setup` reads the same variable,
so team-pipeline and available-issues stay interchangeable.

Set `SGE_BRANCH_PREFIX=claude/issue-` when the pipeline runs under a
[Claude Code Routine](https://docs.claude.com/en/docs/claude-code/routines)
(Anthropic-hosted, scheduled/API/GitHub-event triggered). Routines default to
pushing only `claude/`-prefixed branches as a cloud-sandbox safety net; matching
that prefix lets the pipeline run without switching off the repo's "allow
unrestricted branch pushes" guardrail — the safety net stays intact for the
highest-blast-radius (fully autonomous, no interactive approval) execution
context. Export it once in the Routine's environment; every lane inherits it.

## Base branch (issue #2486)

`SGE_BASE_BRANCH` (default `main`) is the same kind of pipeline-wide setting as
`SGE_BRANCH_PREFIX` above: export it once before the pipeline starts (a repo
whose integration branch isn't `main` — e.g. `uat` — needs it set), and every
lane inherits it. It drives Phase 3c's worktree base
(`skills/team-pipeline/references/mechanisms.md`) and every lane's
`gh pr create --base "${SGE_BASE_BRANCH:-main}"` (Rule 2 above), so a lane's PR
always targets the ref its worktree was actually branched from instead of
silently falling through to the repo's GitHub default branch.
