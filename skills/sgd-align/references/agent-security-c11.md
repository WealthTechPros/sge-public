# C11 — Agent Security (Zero-Trust) mechanism

Full mechanism for the **C11** cascade check referenced from `SKILL.md` Step 1. Read this
before running or interpreting C11.

**C11 — Agent Security (Zero-Trust) check.** Run `bash ${CLAUDE_PLUGIN_ROOT}/skills/sgd-align/assets/check-agent-security.sh` (in non-fork invocations, optionally wrapped in a forked read-only subagent — same pattern as C12) and consume its JSON — the script is the **single source of truth** for the five controls, so the score never drifts from what actually ran. Its contract mirrors C12's `check-regulatory-trace.sh` exactly: read-only, JSON on stdout, exit `0` = no failing control, `1` = one or more failing controls, `2` = harness error. It takes an optional trusted repo-root as `$1` (defaults to the enclosing git toplevel). **No control may be scored manually** — every status and evidence string comes from the script's `controls[]`. The five controls map to `docs-site/governance/zero-trust-ai-agents.md`:

| Sub-check | Evidence source | Pass condition |
|---|---|---|
| **ZT-1 Least-Agency** | CI env / `.env.example` / mcp config files | No `fullcontrol` / `allsites.manage` / `allfiles.write` scope present in any mcp config or env var block |
| **ZT-2 Tool-chaining / Exfil** | `WTP_EMAIL_ALLOWLIST` env var in CI config / `.env.example` | Variable is declared and non-empty |
| **ZT-3 Prompt Injection** | Skill bodies under `skills/*/SKILL.md` | All skill files carry a `<!-- UNTRUSTED DATA -->` annotation on their first external-content ingestion point (the script greps for the annotation form `<!-- UNTRUSTED DATA` — a prose mention is not an annotation); `na` (excluded from the denominator) when the repo has no `skills/*/SKILL.md` |
| **ZT-4 Supply-chain / AI-BOM** | `sbom/ai-bom.cdx.json` + `.github/workflows/ai-supply-chain.yml` | Both files exist **and** the BOM's `metadata.timestamp` is within 90 days of today; both exist but the timestamp is missing/unparsable/stale → 🟡 partial (wiring exists, freshness unverifiable); either file absent → 🔴 fail |
| **ZT-5 Agent Identity** | `git log` trailers on the branch (`origin/<default>..HEAD`, falling back to the last 50 commits on HEAD) | ≥ 80% of commits carry an `Agent-Id:` trailer (or all commits are human — 0 agent commits → pass) |

**ZT-6 was dropped** (issue #842): the old sixth control ("Scoring dimension — always passes once C11 is wired in") was self-referential and passed by definition on every run, inflating every score by +16.7%. The dimension is scored out of the **five real controls**; no always-pass vanity control remains — do not reintroduce one.

**Honesty note (ZT-3):** its pass condition verifiably fails the sgd repo itself at the time of wiring (several skills lack the annotation form). The script reports that as a real 🔴 fail listing the unannotated files — never special-case the home repo or soften the verdict; the annotation fixes land via their own issue, not by weakening this check.

Each control carries: status (✅ pass / 🟡 partial / 🔴 fail / `na`), the evidence examined, and the specific finding — straight from the script's JSON. Aggregate: `agent_security_score = round(100 × (passing + 0.5 × partial) / applicable_controls)` (the script emits this as `score`; `applicable_controls` is normally 5, one fewer when ZT-3 is `na`). Each failing control maps to the same `gaps[]` contract as C1–C10 with key `C11:<ZT-n>`; a 🟡 partial is a medium-severity finding, never a gap-free pass.

**Standalone mode** (`--dimension agent-security`): run only the script, skip Steps 0–4 and all C1–C10 cascade checks, emit only the agent-security section of the Step 5 output plus the JSON block with the `agentSecurity` key. This is the fast path for CISO / FCA / DORA re-assessments.
