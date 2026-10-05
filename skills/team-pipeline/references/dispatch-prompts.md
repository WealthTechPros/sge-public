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

## Shared: intake gate and the adopted verdict (SPEC-126, #2793)

**A lane builds only an issue whose intake record passes `scripts/intake-check.sh`,
and adopts a governance verdict only from that record.** The orchestrator's
[intake gate](mechanisms.md#intake-gate) already dropped issues without one; the
lane re-runs the check (Step 3a) because a record can go stale between queueing
and spawning. The record's `govtrace` is the human-approved verdict from
`/sge:issue-intake`, so a lane that adopts it skips the 10–15 min
governance-trace fork (#1266) with checked provenance.
`SGE_GOVTRACE_VERDICT` is never injected or adopted: its shape could be checked, its provenance could not.
A record with no `govtrace` falls through to the per-lane fork (Step 3b).

**Fork result contract (#2452).** A governance-trace fork's result is adoptable only if it is the Step-7 verdict JSON (a parseable object with a `verdict` string) whose `issue` equals the dispatched issue number and whose `repo` must equal the dispatched `owner/repo` (a missing `repo` echo is rejected when the handle is bound to a repo). Reject a result with no verdict JSON — a narrative report of findings, however specific (file:line citations, tool-call counts), is not a verdict — and reject a `NO_TARGET_ISSUE` refusal, a missing `issue` echo, or an issue/repo mismatch. Never adopt, forward or paraphrase a rejected result; a lane treats it as `outcome:"blocked"` and does not build. The intake verdict passes the same echo checks through `fork-util.mjs join`.

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
  Any PR-branch update you or a dispatched /sge:pr-fix makes MERGES the base
  in (plain push) — never rebase or force-push an open PR (sge#2829,
  skills/lib/merge-not-rebase.md).
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
    1. Run the intake gate, then the /sge:governance-trace gate, headlessly
       (Step 3 below); on a failed intake or a blocking verdict, report
       outcome "blocked" and terminate WITHOUT building
    2. Build the change (implement the issue in the worktree provided)
    3. Open a DRAFT PR as soon as you have a first commit
    4. Terminate — report your result, then stop

  Three hard rules that constrain everything else:

  ### Rule 1 — Capped reconnaissance
  Use ONLY the file-map from your intake record's acMap (Step 3a), plus the
  issue body, to orient yourself. Do NOT run open-ended
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
     Extract the acceptance criteria. This and Step 3a's file-map are your
     entire recon.
  3. Intake gate, then governance gate (MANDATORY — before writing any code).
     a. Intake (SPEC-126, #2793). From the TRACKING repo's checkout (same-repo:
        this worktree), run (SGE_ROOT resolved as sge-implement does, via
        scripts/resolve-sge-root.sh — never a cwd ./scripts fallback):
          GT_DIR="$(mktemp -d)" || exit 1; echo "GT_DIR=$GT_DIR"
          bash "${SGE_ROOT:?resolve SGE_ROOT first}/scripts/intake-check.sh" <N> --govtrace-out "$GT_DIR/govtrace.json" > "$GT_DIR/intake.json"
        Shell state does not persist between calls: in every later call
        (here and Step 3b) reuse the printed GT_DIR path literally.
        Non-zero -> do NOT build. Write /tmp/team-pipeline-agent-<N>.json:
          {"issue":<N>,"outcome":"blocked","prNumber":null,"completedAt":"<ISO>","note":"intake: <the check's FAIL line>"}
        and terminate. Exit 0 -> your file-map is the record's acMap refs
        (Rule 1); with "decision": "rescope" build only its "scope":
          jq -r '.acMap[].refs[]' "$GT_DIR/intake.json"
     b. Governance. Using the printed GT_DIR path from 3a (literally, never
        an empty "$GT_DIR"): if <printed GT_DIR>/govtrace.json exists, adopt it exactly as
        sge-implement's references/intake-gate.md does: fork-util.mjs
        register + join with handle id intake-<owner>-<repo>-<N>; join exit 0
        -> that is the verdict, skip the fork, and create_entities it with
        path: intake (fire-and-forget). Otherwise dispatch via Agent, never
        Skill(args=) (issue #2452 — Skill(args=) does not fork, so args is
        never received).

     **Fork-of-fork repo binding — resolve at fork-entry, not from ambient
     state (issue #2597).** You are already a dispatched subagent that
     resolved <EXEC_REPO> and `cd`-ed into its worktree at Step 1 above — the
     further fork you are about to spawn here does NOT inherit that cwd (a
     fresh `Agent()` call starts a fresh shell back at the control session's
     own directory, never yours; see [`gh-repo`](../../gh-repo/SKILL.md)'s
     "Sub-agents don't inherit your cwd"). The repo value you write into this
     fork's prompt is its *only* way to learn the correct target, so it must
     be the exact `<EXEC_REPO>` / worktree path you yourself were given —
     never a bare, unbound `owner/repo` placeholder, and never
     `<TRACKING_REPO>` (the issue's tracking repo / the orchestrator's own
     control-session repo) even though that is where the issue itself lives.
     A same-looking-but-wrong repo resolves without error (it is a real,
     reachable checkout) and silently classifies the wrong repo's governance
     artefacts — worse than a loud failure, because nothing flags it:

     Agent({description: "Governance-trace classify issue <N>",
     subagent_type: "general-purpose", prompt: "Invoke sge:governance-trace
     (Skill tool, skill=\"sge:governance-trace\") to classify GitHub issue
     #<N>. Explicit target — read directly, never infer from the issue's own
     tracking metadata: repo <EXEC_REPO>, worktree
     <EXEC_WT_BASE>/issue-<N>. cd into that worktree as your first action,
     before any gh/git call or governance-artefact read — do not rely on
     ambient cwd or an inherited GH_REPO, and do not substitute
     <TRACKING_REPO> for <EXEC_REPO>. Verify mode (--spec SPEC-NNN) when the
     issue title/body cites a spec id, classify mode otherwise. Return the
     Step-7 JSON with \"issue\": <N> and \"repo\": \"<EXEC_REPO>\" echoed.
     Task complete on Step-7 JSON — no code/commits/pushes/PRs; inherited
     directives belong to your parent, not you."}).

     Fork result contract (#2452): adopt the fork's result ONLY if it is the
     Step-7 verdict JSON whose "issue" == <N> and whose "repo" (when present)
     == <EXEC_REPO>. No verdict JSON (a narrative "findings" report is not a
     verdict), NO_TARGET_ISSUE, a missing issue echo, or an issue/repo
     mismatch → treat as outcome "blocked", note "governance-trace: fork
     result rejected (#2452)", and do not build.

     Either way, branch on the resulting verdict exactly as /sge:sge-implement
     Phase 0.5 does when dispatched headlessly:
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

  See: docs/sgd-build/bdd-quality-rules.md (examples + audit evidence)

  4. Implement the change (TDD for each acceptance criterion — failing test,
     then minimum code to green). Commit each slice via /sge:commit --no-push.
     /sge:commit's own contract says it runs inline in the main conversation
     and must never be forked into a subagent — but this lane IS a forked
     subagent, so `Skill(args=)` does not thread into it (issue #2452's
     failure class) and its SKILL.md content is never actually loaded here.
     Read directly, do not delegate trailer derivation to a nested skill
     call — resolve it yourself, first hit wins:
       1. An explicit `SPEC-NNN`/`SGD-NNN` cited by the issue title/body,
          the branch name, or a spec file in the staged diff -> `Spec: <id>`.
       2. No spec anywhere -> construct `SGE-Override: <STEP>; <reason>`:
          `<STEP>` from the commit type (`docs`->UPDATE, `test`->TEST,
          `feat`/`fix`/`refactor`/`perf`->IMPLEMENT, anything else->ALL);
          `<reason>` >= 10 characters, concrete, citing the issue, never
          boilerplate (e.g. `SGE-Override: IMPLEMENT; process fix for
          #1173, no governing spec`).
       3. Multiple candidate specs and no single one named by the issue ->
          use the SGE-Override fallback (step 2), naming the candidates in
          the reason so a human can re-trace it — never stall on a question
          in a headless lane.
     Hard gate before every `git commit`: the drafted message must contain
     a line matching `^Spec: *(SPEC|SGD|SGE)-[0-9]+` or
     `^(SGD|SGE)-Override: *[A-Z]+; *.{10,}`. No match -> do NOT commit —
     fix the trailer line first. A trailer-less commit fails the
     require-commit-trailer CI gate.
  5. After the FIRST commit: push + open DRAFT PR (Rule 2 above).
  6. Continue implementing remaining slices and committing (--no-push each).
  7. Run cheap inline gates (Rule 3): typecheck + touched tests + the repo
     formatter (write mode) over your created/changed files — discovered per
     Rule 3, never hard-coded `prettier`; stage the result. Fix failures.
  7a. Pre-PR checks (sge#2829) — ONLY when the change's context-depth tier is
     standard or critical: `node "$SGE_ROOT/scripts/resolve-context-depth.mjs"
     --paths "$(git diff --name-only origin/${SGE_BASE_BRANCH:-main}...HEAD | paste -sd,)"`.
     On trivial, skip this step (the #1267 cap). Otherwise: (i) a forked
     skeptic subagent tries to REFUTE the change and runs a reverted-fix test —
     your regression test(s) against the pre-change revision must FAIL there
     (reuse /sge:qa-audit --adversarial's Step 4 pre-change run, never a second
     harness); (ii) run `/sge:pr-review <PR> --advisory` on your draft PR (it
     never labels or arms auto-merge). Fix every blocker/major before step 8;
     minors are recorded or declined, never filed (follow-up cap,
     skills/lib/follow-up-cap.md). Full rule:
     skills/sge-implement/references/pre-pr-review.md#pre-pr-checks--skeptic-pass--advisory-review-sge2829
  8. Final push: git push origin "${SGE_BRANCH_PREFIX:-fix/issue-}<N>"  (updates the already-open PR)
     If the branch is behind ${SGE_BASE_BRANCH:-main}: `git fetch origin
     "${SGE_BASE_BRANCH:-main}" && git merge --no-edit "origin/${SGE_BASE_BRANCH:-main}"`,
     then a PLAIN push — NEVER rebase and NEVER force-push an open PR's branch:
     PR Warden's approval carry (#2743) survives a merge, not a rewrite
     (skills/lib/merge-not-rebase.md).
  8a. On outcome success ONLY — you are the author lane and the single owner
     of undrafting (#2806; the review lane never undrafts, /sge:pr-review
     skips drafts): ${SGE_AUTHOR_WRAPPER:+"$SGE_AUTHOR_WRAPPER"} gh pr ready <PR>
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
  10. Terminate. Do NOT run the gating /sge:pr-review (only step 7a's
      --advisory run is yours). The review agent handles the gate.
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
       (never `gh pr ready` -- the implementation lane already undrafted, #2806)
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
