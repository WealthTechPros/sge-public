# Regulatory map — which register field satisfies which obligation

Each inventory field exists because a named regime asks for it. Sources are as researched
2026-06-11; regimes move — verify before citing to a regulator.

## FCA (UK conduct)

- **Approach:** no new AI-specific rulebook (FCA "AI and the FCA: our approach", Sep 2025);
  existing frameworks apply — Consumer Duty and SM&CR carry the weight.
- **Fields:** `accountable_owner` (SM&CR: a named senior manager owns the use case),
  `risk.customer_affecting` (Consumer Duty: customer-affecting AI output needs evidence of
  good-outcomes monitoring), `controls.monitoring_plan`.

## PRA SS1/23 (UK prudential — model risk management)

- **Expectation:** a model inventory with risk tiering, independent validation proportional to
  tier, and fallback mechanisms. Applies to PRA-regulated firms; a sensible benchmark for others.
- **Fields:** the register itself, `risk.tier` + `risk.rationale`,
  `controls.validation_status`, `model.version_control` (model change = model risk event).

## EU AI Act

- **Annex III (high-risk categories):** firms must walk the **full** Annex III list — not just
  the financially-prominent ones. Financially-relevant examples include Section 5(b)
  (creditworthiness assessment / credit scoring for natural persons) and Section 5(a)
  (individual risk assessment in life/health insurance with significant effects on access or
  conditions). Other sections may also apply to FS firms: Section 6 (employment / workers
  management), Section 8 (law enforcement). `risk.eu_ai_act.annex_iii_check` forces the
  walk-through; `classification` records the outcome with reasoning.
- **Article 26 (deployer obligations, apply from 2 Aug 2026):** human oversight, input-data
  control, monitoring, log retention. **No sector-specific exemption exists in Article 26
  itself.** Recital 91 notes that for credit institutions regulated under CRD, competent
  authorities should coordinate to avoid duplication — this is a coordination note, not a
  blanket deeming provision. Article 26 obligations apply in full; firms should seek legal
  advice on how existing governance arrangements satisfy them. This register helps evidence
  that effort.
  Fields: `controls.human_oversight`, `eu_ai_act.deployer_obligations_noted`.

## DORA (EU digital operational resilience)

- **Treatment:** an external LLM API is an ICT third-party dependency — it belongs on the
  firm's register of information, with contractual provisions and a documented exit strategy.
- **Fields:** the whole `dora` block. `register_ref` points at the firm's actual register —
  this inventory cross-references, it does not replace it. UK-only firms: DORA does not bind
  them — point `register_ref` at the FCA operational-resilience/outsourcing equivalent, or
  record `n/a (UK-only)` with that reason.

## Vendor due diligence (template rows)

- ISO/IEC 42001, ISO 27001, SOC 2 Type II — assurance artefacts a diligent firm obtains and
  reviews itself (Anthropic publishes its certifications; the firm still evidences and dates
  the check — that is what the empty template enforces).
- ZDR: zero-data-retention is a **negotiated addendum**, not a default of any tier or route —
  hence `unknown` until contractual confirmation.
- Bedrock/Vertex routes: in-account/in-region inference and no-training commitments are route
  properties worth recording under `deployment` and row 4/5 of the DD template.

## Risk-score control-binding rationale

The following table maps each risk-score input (defined in [`risk-scoring.md`](risk-scoring.md)) to the regulatory obligation that requires it to be mitigated.

| Risk input | High-risk condition | Governing regime | Mitigating control |
|------------|---------------------|------------------|--------------------|
| Exposure: external + network-reachable | ICT third-party risk | FCA SYSC 8.1 (outsourcing), DORA Art 28, FCA SYSC 13.1 (op resilience) | `FCA-SYSC-8-1`, `DORA-ICT-28` |
| Auth: none or api-key | Inadequate access control | FCA SYSC 10.1.6 (conflicts/access), PRA SS1/23 §3.4 | `FCA-SYSC-10-1-6` |
| Data class: client-pii / portfolio-data | Consumer / personal data exposure | UK GDPR Art 25, FCA PROD 4.1 (Consumer Duty) | `FCA-PROD-9-1`, `GDPR-ART-25` |
| Any input: unknown | Unassessed risk — open action | All of the above (cannot confirm compliance) | Resolve unknown before approving asset |
