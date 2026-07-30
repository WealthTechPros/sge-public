## Decision rules & defaults (required for unattended runs)

<!-- Pre-answer the questions an agent would otherwise stop to ask. Every recurring
     entry in a run's DECISIONS.md journal should graduate into a rule here.
     A spec without this section is not eligible for SGD_UNATTENDED=1 runs. -->

| Situation | Rule / default | Rationale |
|---|---|---|
| Naming/style choice not covered by the spec | Follow the nearest existing pattern in the module; do not introduce new conventions | Consistency beats novelty overnight |
| Dependency needed but version unpinned | Use the version already in the lockfile elsewhere in the repo; never add a new top-level dependency unattended | Supply-chain discipline (SGD-048) |
| Test data required | Synthesise minimal fixtures; never copy production or client data | Zero-trust boundary |
| Spec silent on an edge case | Implement the conservative interpretation; journal it; add a Gherkin scenario marking it PENDING-CONFIRMATION | Reversible + visible |
| Anything touching regulated-user-facing output, migrations, auth, or deletion | BLOCKED — do not proceed unattended | Gate moved to morning, not removed |

<!-- Add spec-specific rows above. Keep rules testable: if a rule can't be checked, rewrite it. -->
