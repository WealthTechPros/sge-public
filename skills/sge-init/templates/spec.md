```yaml
spec:
  id: SPEC-001                        # must match the file name: docs/features/SPEC-001-<slug>.md
  title: <Feature title>
  capability: CAP-ONBOARD-CONNECT     # a capability id from the capability model
  feature: F-CONNECT                  # the feature id this spec specifies
  success_measure_moved: SM-1         # the Vision success measure this moves
  status: draft                       # draft -> approved -> building -> implemented
  tracking_issue: null                # the issue number once one exists
  owner: <owner email or role>
  reviewers:
    - <reviewer email or role>
```

<!-- Seeded by /sge:sge-init Step 4. The frontmatter block above conforms to
docs/schemas/spec.schema.json in the SGE plugin (SPEC-133): keep it as the first
thing in the file. A spec past draft must carry an "Acceptance criteria" section
with Gherkin scenarios. -->

# SPEC-001: <Feature title>

## Business intent

<Why this feature exists, and which success measure (SM-N) it moves.>

## User story

As a <persona>, I want <job>, so I can <outcome>.

## Acceptance criteria

```gherkin
Feature: <Feature title> (SPEC-001)

  @SPEC-001
  Scenario: S1 <the job-to-be-done this proves>
    Given <a concrete starting state>
    When <the action>
    Then <a concrete, measurable outcome>
```

## Scenarios

| Scenario | Bound test |
|----------|------------|
| S1 | `<test file> › "SPEC-001 S1: <name>"` |

## Validation

<!-- TODO: no reconciliation/boundary invariant identified from intake. Fill in id/name/rule/assert rows if this feature has one, or delete this section if it genuinely has none. -->

## Out of scope

- <What this spec deliberately does not cover.>

## Open questions

- <QD-NN references, or "none".>
