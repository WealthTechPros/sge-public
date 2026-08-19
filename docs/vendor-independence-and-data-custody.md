# Vendor independence and data custody by design

This note explains how SGE avoids hard lock-in to one model provider.

## Separation model

- **Harness/orchestration** is provider-agnostic: workflow controls live in SGE skills and runtime glue, not in any single model SDK contract.
- **Context and memory** are separated from model vendor state: memory can be retained and reasoned about independently of a specific model deployment.
- **Usage metadata custody** is owned by the operating team: prompts/responses, token/cost traces, and run outcomes can be retained in organisation-controlled stores.

## Why this matters

- Provider changes (commercial, operational, or policy-driven) do not force a full rewrite of orchestration logic.
- Regulated teams can evidence model-use decisions and audit history from their own retained records.
- Teams can move from vendor-rented intelligence toward internal optimisation over time, because usage traces remain available.

## Operational expectations

- Treat provider adapters as replaceable seams; avoid provider-specific assumptions in shared orchestration paths.
- Keep retention and minimisation rules explicit and reviewable for regulated usage.
- Validate model swap scenarios in controlled runs before production cutover.

Related references:

- `docs/external-install.md`
- `docs/model-decoupling-audit.md`
- `docs/cortex-model-agnosticism-audit.md`
