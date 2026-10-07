# Adversarial mode (--adversarial)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

## Adversarial mode (`--adversarial`, issue #2211)

**The gap this closes.** The same PR was reviewed twice. A read-the-diff pass approved it with minor observations. An execute-it pass built a 30-case bypass corpus and ran it against the checker under review: 26 of 30 succeeded, including `os.system`/`os.popen`/`os.exec*`/`pty.spawn` entirely uncovered, a dynamic-import spelling that walked past the scan, and a dependency-manifest field that passed the allowlist having read nothing at all. A third reviewer reproduced a **fail-open** by constructing the triggering condition natively: an exact-string comparison silently stopped matching, and the script named the PR author as the independent reviewer while exiting 0. **For a change that is a control, reading it is not reviewing it — the failure modes live in what the control does not catch, and that is invisible in a diff.**

**When this mode runs.** `/sge:pr-review` Phase 2 dispatches `/sge:qa-audit <pr> --adversarial` when `rl_diff_control_bearing` classifies the diff as touching an enforcement mechanism — a security check, policy gate, or static audit/scanner script. It can also be invoked directly for a manual behavioural audit of any control. **This is a selected tier, not a default** — a doc-only or prose PR never reaches this mode; ordinary feature/bug-fix PRs use the normal Steps 1–6 above.

**Step 1 (adversarial variant) — derive the control's claimed guarantee, not acceptance criteria.** Instead of "what should this feature do", ask "what is this control supposed to catch, and how would a violation get past it if the control were broken." Read the control's own logic (the diff, or the full script on a fresh introduction) to enumerate its **detection surface** — every distinct code path, pattern, or condition it claims to catch — and its **known escape hatches to check** (anything it explicitly does NOT claim to cover, which is a scope note, not a defect, but must be stated). This list becomes the adversarial criteria; there is no acceptance-criteria/Gherkin substitute here — a control with no stated detection surface is itself a Step 1 finding ("no enumerable claim to test against").

**Step 4 (adversarial variant) — construct the adversarial condition, never reason about it (ask 2).** For each item in the detection surface:

1. **Plant a violation and observe the failure.** Write the actual violating input/file/command the control claims to catch, run it through the control exactly as CI would invoke it, and capture the real exit code and output. "This pattern looks like it would match" is not evidence — only an observed non-zero exit (or whatever failure signal the control defines) counts.
2. **Neuter the checker and confirm the suite goes red.** Temporarily comment out or short-circuit the control's own enforcement logic (in the isolated worktree only — never the shared checkout) and re-run its test suite. A suite that stays green with the control disabled is the tests-passing-for-the-wrong-reason failure mode this mode exists to catch (see ask 4 below); a suite that goes red confirms the tests are actually exercising the control's logic, not merely running past it.
3. **Build the bypass corpus systematically**, not opportunistically: every distinct evasion technique applicable to the control's implementation language/mechanism — encoding/obfuscation variants, alternate syntax for the same operation (e.g. `os.system` vs `subprocess` vs `os.popen` vs `pty.spawn` for "shell execution"), boundary conditions (empty input, exact-match vs prefix-match confusion, case sensitivity), and any manifest/config field the control reads but does not validate. Aim for breadth over depth — the measured incident's corpus was 30 cases; there is no fixed minimum, but a single happy-path bypass attempt is not adversarial testing.

**Step 5 (adversarial variant) — a negative control is mandatory, and its absence is itself a finding (ask 3).** At least one constructed case in the corpus MUST be a genuine, unambiguous violation with no legitimate reason to pass. Run it. **If the control does not catch it, that is not "the control has a gap" phrased as advisory — it is a BLOCKER finding, full stop**, because it means the auditor cannot demonstrate the control works AT ALL, which is a stronger and more urgent problem than any individual bypass. Each result keeps the Step 5 JSON shape, `requirement` naming the specific bypass attempted:

```json
{ "requirement": "os.system(\"rm -rf /\") is caught by the shell-exec scanner", "status": "fail", "evidence": "Ran the exact string through scripts/dependency-audit.sh; exit code 0 (expected non-zero); the pattern list at line 42 covers subprocess.* but not os.system/os.popen" }
```

`status: fail` here means **the bypass succeeded** (the control did not catch the violation) — read the corpus results as "did the control catch this", not "did my test pass"; a `pass` status means the control correctly rejected the constructed violation.

**Step 5 (adversarial variant) — vacuous-test detection (ask 4).** Separately from the corpus above, inspect the control's own test suite (if it has one) for the specific failure mode measured in the incident: a check with **one failure exit path and many failure reasons**, tested only by asserting `exit != 0`. For each existing test case:

1. Identify what specific violation the test's name/comment claims to catch.
2. Trigger a **different** violation that also causes the same generic non-zero exit.
3. If the test would pass regardless of *which* violation triggered the exit (i.e. it asserts only the exit code, never the specific error message/reason/matched-pattern), that test is **vacuous** — it proves the script fails sometimes, not that it fails for the *stated* reason. Report it as a finding: `{"requirement": "test '<name>' asserts only exit code", "status": "fail", "evidence": "swapped the trigger from <original violation> to <unrelated violation>; test still passes because it only checks $? != 0, never the error message"}`.

The measured incident: the pre-fix suite scored 5 passed / 3 failed against exit-code-only assertions; adding diagnostic (message/reason) assertions and re-running against the **unfixed** script (see next) scored 0 passed / 9 failed — every one of the original 5 "passes" was vacuous.

**Step 4 (adversarial variant) — pre-change-revision regression run, when the PR claims to fix a defect (ask 5).** If the PR body or linked issue claims to fix a bug/bypass/vulnerability, `git stash` or `git worktree add --detach <base-sha>` a **second** checkout at the PR's base (pre-fix) commit, and run the SAME adversarial corpus (including the specific case the issue reports) against that pre-change revision. **A regression suite that does not fail against the unfixed code is not a regression suite** — if every corpus case passes against the OLD code too, the "fix" demonstrably fixed nothing observable, regardless of what the diff appears to change. Record both results side by side: `{"requirement": "<case>", "pre_fix_status": "pass|fail", "post_fix_status": "pass|fail"}` — the interesting signal is any case where `pre_fix_status == post_fix_status == "pass"` (bypass succeeded both before and after) or `pre_fix_status == "fail"` on the corpus's OWN reproduction case (the fix's regression test doesn't even fail on the bug it claims to fix).

**Step 6 (adversarial variant) — report structure.** Same `qa-audit-report`/`qa-audit-verdict` contract as the standard report (Step 6 below), with these additions:

- A **Detection Surface** section listing every claimed-catch enumerated in Step 1, each mapped to a corpus case and its result.
- A **Negative Control** line stating explicitly whether the mandatory negative control passed (control caught the deliberate violation) — a missing or failing negative control is called out **before** the recommendation, not buried in the table.
- A **Vacuous Test Findings** section (or "None found") from the Step 5 pass above.
- A **Pre-Fix Regression** section (or "N/A — PR does not claim to fix a defect") from the Step 4 pre-change-revision run.
- `recommendation: APPROVED` requires: negative control passed, no vacuous tests found (or all fixed), and — when applicable — the pre-fix run shows the regression case genuinely failing on the old code and passing on the new. Any one of those missing/failing is `CHANGES REQUESTED`, regardless of how many corpus cases the control did catch.

---
