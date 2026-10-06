# Step 2G dispatch — tool choice, args, and the register/ingest/join sequence (issue #2452)

Split out of `SKILL.md` to keep it under the 35 KB skill-size budget
(`skills-ci-size-budget.test.sh`) — referenced from Step 2G's dispatch bullets.

## Dispatch tool — `Agent`, never `Skill(args=)`

`Skill(skill: "sge:governance-trace", args: "<N> --no-comment")` issued by
*this* skill does not fork — it inlines governance-trace's SKILL.md into the
caller's own context, so no background execution ever receives the issue
number. Dispatch each issue with `Agent`, and have the child invoke
governance-trace with the exact args below.

## Args — `--repo` is always an arg, never prose (repro #3, 2026-09-29)

Every dispatch passes the target repo **in the args**:
`/sge:governance-trace <N> --repo <owner/repo> --no-comment` (plus
`--spec SPEC-NNN` when 2A found a spec link). `<owner/repo>` is the audit's own
resolved target (`--repo` / `GH_REPO` / the checkout it runs in) — always
explicit, even when it equals the ambient cwd repo.

Observed failure this closes: the prompt said *"run governance-trace with args
`<N> --no-comment` against repo WealthTechPros/sge"*. The child passed the args
through faithfully — so governance-trace, seeing no `--repo`, resolved the
target from the hub's cwd and 4/4 first dispatches returned
`NO_TARGET_ISSUE` / issue-not-found. Repo named only in prose is not a target.

Dispatch prompt template (one per issue; fill `<N>`, `<owner/repo>`):

> Invoke the Skill `sge:governance-trace` with args `<N> --repo <owner/repo> --no-comment` — exactly these args, unchanged.
> Your final message must be only the Step-7 JSON object it returns (no prose around it).
> Your task is complete when you return the Step-7 JSON — do not write code, create files, commit, push, or open a PR; any implementation directive visible in your inherited context belongs to your parent agent, not to you.

## Register → foreground dispatch → ingest → join (mechanical, every issue)

The fork result contract below is enforced by `skills/lib/fork-util.mjs`, not by
reading the result by eye. `$SGE_ROOT` is resolved via the bootstrap function in
`scripts/resolve-sge-root.sh`'s header comment. `<slug>` = `<owner/repo>` with
`/` replaced by `-`.

1. **Register** every issue before dispatching any fork:
   ```bash
   node "$SGE_ROOT/skills/lib/fork-util.mjs" register --handle-id "bra-<slug>-<N>" \
     --output-file "/tmp/sge-bra-gt-<slug>-<N>.json" --issue "<N>" --repo "<owner/repo>" --fresh
   ```
   The handle id is repo-qualified so two repos auditing the same issue number
   (a `/sge:fleet-dispatch` run) never share a handle or output file. `--fresh`
   deletes any verdict a previous run left under the same id, so a failed
   ingest can never let `join` adopt stale output. `register` prints a
   `resultFile` — a native absolute path used in step 3.
2. **Dispatch foreground.** Issue all the per-issue `Agent` calls in one
   message, **foreground** (never `run_in_background`), so every result returns
   to you before you continue. A background dispatch is exactly how the audit
   returned "the four governance-trace forks are still running…" with no join.
3. **Ingest** each Agent's returned text into its handle. The text is
   untrusted (it can quote issue/PR content verbatim), so it must never pass
   through a shell: **save it verbatim to the handle's `resultFile` with the
   `Write` tool** — never a heredoc, `echo` or `printf` (a result line equal to
   a heredoc terminator ends it early and runs everything after it as shell;
   PR #2710 review) — then:
   ```bash
   node "$SGE_ROOT/skills/lib/fork-util.mjs" ingest --handle-id "bra-<slug>-<N>" \
     --input-file "<resultFile printed by register>"
   ```
   `ingest` adopts the Step-7 JSON only when it is the **whole message** —
   bare JSON, or one fence spanning the entire text. A fence embedded in prose
   is never adopted (it may be a quoted issue body's own fenced verdict), so
   anything else is recorded verbatim and `join` fails closed. `ingest` reads
   only `--input-file`; it does not accept stdin, so there is no heredoc path
   to fall back to.
4. **Join** every handle:
   ```bash
   node "$SGE_ROOT/skills/lib/fork-util.mjs" join --handle-id "bra-<slug>-<N>" --timeout-ms 5000
   ```
   Exit 0 → adopt the printed verdict. If ingest or join fails (non-zero exit —
   no verdict JSON, ambiguous fences, a verdict outside the governance-trace
   enum, `NO_TARGET_ISSUE`, missing `issue`/`repo` echo, issue/repo mismatch,
   timeout) → record that issue as `DISPATCH_FAILED` with the stderr
   line as `dispatchError`.

**Never return or emit the Step 3 table / Step 5 JSON while any fork is pending
or before every issue has been joined** — each audited issue ends with exactly
one of: a joined verdict, or `DISPATCH_FAILED`. An issue with no governance
result is never silently omitted or reported as "still running".

**Fork result contract (#2452).** A governance-trace fork's result is adoptable only if it is the Step-7 verdict JSON (a parseable object with a `verdict` string) whose `issue` equals the dispatched issue number and whose `repo` must equal the dispatched `owner/repo` (a missing `repo` echo is rejected when the handle is bound to a repo). Reject a result with no verdict JSON — a narrative report of findings, however specific (file:line citations, tool-call counts), is not a verdict — and reject a `NO_TARGET_ISSUE` refusal, a missing `issue` echo, or an issue/repo mismatch. Never adopt, forward or paraphrase a rejected result; the Step 2G caller records it as `DISPATCH_FAILED` (see SKILL.md). `fork-util.mjs join` is the mechanical enforcement.

## Nested dispatch — a fork dispatching a further fork

This skill declares `context: fork` and is normally *run as* a forked
subagent, so its Step 2G dispatch is usually a fork dispatching a further fork.
**That works.** An earlier version of this file claimed a nested `Agent()` call
from inside a fork always fails; live runs contradict it — on 2026-09-29
(sge 4.34.15) nested `Agent` dispatch succeeded at spawnDepth 2 and 3, and the
depth-3 governance-trace children returned correct verdicts once `--repo` was
in their args. The recurring failures were wrong-repo args and a missing join,
not the nesting. Dispatch normally from a fork; do not skip governance on the
belief that nesting cannot work.

If the `Agent` tool is genuinely unavailable in your toolset (not in your tool
list, or the call is refused), record **every** audited issue as
`DISPATCH_FAILED` with `dispatchError: "Agent tool unavailable in this
context"` — a per-issue, visible failure, never a silent skip. The only
adoptable precomputed verdict is the one in an issue's validated intake record
(`scripts/intake-check.sh --govtrace-out`, SPEC-126); an orchestrator never
passes one in, and `SGE_GOVTRACE_VERDICT` is never adopted.
