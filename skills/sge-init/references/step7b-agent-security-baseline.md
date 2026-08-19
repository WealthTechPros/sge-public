# Step 7b — Seed the Agent Security (Zero-Trust) dimension baseline

Full mechanism for Step 7b, referenced from `SKILL.md`. Read this before running Step 7b.

After the change-protocol guardrails are in place, seed the **C11 Agent Security baseline** so the first `/sge:sge-align` run has a starting posture rather than reporting every control as 🔴 with no context.

Propose the following (AI proposes, human disposes — write only after approval):

1. **Initial posture check** — run `/sge:sge-align --dimension agent-security --dry-run` (if the repo is ready) or run the C11 script (`skills/sge-align/assets/check-agent-security.sh` in the plugin) against the current repo state and report the starting score (e.g. `2/5 controls passing at onboarding`).

2. **Governance-posture seed record** — propose adding `docs/sge/agent-security-posture.md` with the initial C11 result, the date, and the audited SHA. This gives the first "before" snapshot so future sweeps can report a delta (`was 2/5 at onboarding, now 4/5`).

   Template (fill in with actual check results — five controls; ZT-6 was dropped as a self-referential vanity control, sge#842):

   ```markdown
   # Agent Security Posture — <repo>

   Seeded by /sge:sge-init at onboarding. Re-assess with `/sge:sge-align --dimension agent-security`.

   | Date | SHA | Score | ZT-1 | ZT-2 | ZT-3 | ZT-4 | ZT-5 |
   |------|-----|-------|------|------|------|------|------|
   | <date> | <sha> | <N>/5 | ✅/🟡/🔴 | ✅/🟡/🔴 | ✅/🟡/🔴 | ✅/🟡/🔴 | ✅/🟡/🔴 |
   ```

3. **Gap tracking** — for any C11 control that fails (🔴) at onboarding, propose creating a GitHub issue with the relevant dependency reference (see `docs-site/governance/zero-trust-ai-agents.md` roadmap: #279 Least-Agency, #280 send-side controls, #281 prompt injection, #282 AI-BOM, #283 agent identity). This turns the gap into tracked work from day one rather than silent technical debt.

Skip this step and note it in the Review Package if the repo has no CI or is a library with no MCP/agent surface — C11 is N/A for pure libraries and is excluded from the composite score (same exclusion rule as C10 for repos with no UI).
