# Example: Cohort Reconciliation (spec-validate worked example)

This is the worked example bundled with `/sge:spec-validate` (issue #761) —
the reconciliation invariant Dave Howard's feedback named directly: *"How do
we validate the rules and spec are aligned? … like C1 must be ≤ Addressable −
Exclusions."* `SPEC-147` (the issue's original example) lives in a different
repo; this stands in as the format's canonical demo, per `docs/specs/README.md`.

## Validation

<!-- validation:fixture example-fixture.json -->

Invariants checked against the demo fixture at spec-graduation time. `rule` is
what a non-technical reviewer verifies by eye; `assert` is the machine-checked
expression `/sge:spec-validate` evaluates, with `r` bound to the fixture's
JSON root.

| id | name | rule | assert |
|----|------|------|--------|
| V1 | Reconciliation footing | Total clients must equal the sum of Exclusions + C1 + C2 + C3 | `r.totals.clients === r.exclusions.clients + r.c1.clients + r.c2.clients + r.c3.clients` |
| V2 | C1 boundable | C1 must never exceed Addressable minus Exclusions | `r.c1.clients <= r.addressable.clients - r.exclusions.clients` |

## Out of scope

Converting the real `SPEC-147` to this format — that happens in its home repo.
