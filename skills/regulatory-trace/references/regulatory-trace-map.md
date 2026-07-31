# Regulatory map — which obligation a spec mapping helps evidence

Companion to `sgd-ai-inventory/references/regulatory-map.md`. **That** map explains
which register field satisfies which regime for an **AI use case**; **this** map
explains which obligation a **feature-spec mapping** helps a regulated WTP *client*
evidence. The two share the obligation vocabulary
(`assets/obligations-catalogue.yaml`) so the skills never diverge.

> **The reframe, stated once and applied throughout.** WTP is the **subject, not the
> addressee** of these regimes. It builds AI software for FCA-authorised firms and is
> their data **processor / sub-processor**. FCA accountability **cannot be delegated
> to a vendor** (FG16/5; SYSC 8.1.6R). So every entry below reads *"a spec mapped here
> helps the **client** evidence X"* — never *"WTP complies with X"*. This skill records
> **evidence-contribution traceability**, not legal conclusions. Seek legal advice on
> whether the evidence is sufficient; this map only routes specs to obligations.

Sources researched 2026-06; regimes move — verify before citing to a regulator.

## FCA (UK conduct & operational resilience)

- **SYSC.8.1 / SYSC.8.1.6R — outsourcing & non-delegable accountability.** When WTP
  software performs a function the firm has outsourced, the firm still owns the
  regulatory accountability. Specs that document the service boundary, access model,
  audit trail, and rollback/exit help the firm evidence its **retained oversight** —
  the only thing SYSC 8.1.6R lets it evidence (it cannot evidence "the vendor took
  the accountability", because that is impossible).
- **SYSC.15A — operational resilience / important business services.** Where WTP
  software underpins a client *important business service*, specs covering resilience,
  recovery, testing and impact tolerances feed the firm's SYSC 15A self-assessment.
- **FG16/5 — outsourcing to the cloud.** Explicitly confirms **ISO 27001 alone is
  insufficient** for material outsourcing. Specs evidencing data location, access
  control, exit rights and audit rights fill exactly the gap FG16/5 names — which is
  why `frameworks` (ISO) and `fca_obligations` (FG16/5) are mapped *together*, never
  one instead of the other.
- **FG26/4 — critical/material third-party ICT arrangements (in force 18 Mar 2027).**
  §3.7 names AI/ML models, their training/test data (incl. synthetic), and third-party
  OSS / ML libraries as reportable. Enhanced-scope clients (≈£50bn AUM, banks,
  designated investment firms) **register WTP** and demand DD evidence with
  **tripartite** (firm + auditor + regulator) access. Specs flagged
  `tripartite_evidence: true` land in the `export --tripartite` bundle and the
  trust-fabric **auditor** evidence room.
- **PRIN.2A — Consumer Duty.** Specs whose output reaches or informs a retail-customer
  outcome carry `consumer_duty: true` and contribute good-outcomes/monitoring evidence.
  Human review before delivery is a *control*, not grounds for `false` — same rule as
  the AI register's `customer_affecting`.
- **PRIN.11 — openness with regulators.** The route for **smaller clients** below the
  FG26/4 enhanced-scope threshold: they surface WTP evidence under Principle 11 on
  request rather than via formal material-arrangement registration. Same export, lighter
  trigger.
- **SUP.15 — notifications; SMCR — named accountable owner.** Incident/material-change
  specs feed a SUP 15 notification trail; a spec's `owner` maps to the client's
  accountable senior manager (SM&CR).

## PRA (prudential — dual-regulated clients)

- **SS1/23 — model risk management.** For AI/model specs, **cross-link** to the AI
  inventory (`ai_inventory_ref`) — do not restate tiering here. Present so non-AI specs
  can still cite controls that feed the client's model-risk framework.
- **SS2/21 — outsourcing & third-party risk.** Prudential analogue of FG16/5; same
  evidence contribution (exit, audit rights, sub-outsourcing, resilience) for
  PRA-dual-regulated clients.

## Certification frameworks (the `frameworks` ids)

- **ISO/IEC 27001:2022** — 93 Annex A controls in 4 themes (Organizational, People,
  Physical, Technological). **Table stakes** for enterprise wealth clients but, per
  FG16/5, **insufficient alone** for material outsourcing — which is why ISO ids are
  always mapped alongside the FCA obligation, never instead of it.
- **ISO/IEC 42001:2023** — the first certifiable **AI Management System** standard; the
  **AI differentiator**. ~40% control overlap with 27001 (shared Annex SL clauses
  4–10), so one spec commonly maps to both `ISO27001:A.x` and `ISO42001:A.x`.
- **ISO/IEC 27701** — privacy (PIMS) extension for UK GDPR; the **WTP-as-processor**
  controls (DPIA, sub-processor management, data-subject rights).

The strategic posture is **one combined ISMS/AIMS/PIMS** (Annex SL clauses 4–10
shared) — so a single spec's `frameworks` list legitimately spans all three standards;
that is a feature of the build-one-management-system approach, not double-counting.

## What this map is NOT

- **Not a compliance statement.** A mapping says "this spec contributes evidence
  toward obligation X"; it never says "WTP/the client is compliant with X".
- **Not the AI register.** AI use-case tiering, Annex III, DORA third-party entries
  live in `ai-inventory.yaml` via `/sgd:sgd-ai-inventory`. This map links to it
  (`ai_inventory_ref`) and never duplicates it.
- **Not legal advice.** Where sufficiency of evidence is in question, the firm takes
  legal/compliance advice; this skill makes the evidence *traceable*, not *sufficient*.
