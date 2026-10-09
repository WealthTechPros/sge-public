# Standing review lenses — storage bounds and vacuous authorization tests (issue #2646)

Three rubric rules every Phase 2 reviewer lane applies, alongside the transaction-atomicity lens
(`../SKILL.md` Phase 5, check 5). §1 and §2 come from one miss: a `/sge:pr-review` of ppp PR #12451
returned APPROVE with 0 blockers / 0 majors / 7 minors, and an independent read of the same head
found two defects that should each have been **major** — both verified afterwards. Include all
rules **verbatim in each Layer 2–3 dispatch prompt** ([`reviewer-lanes.md`](reviewer-lanes.md));
the bundled `@code-reviewer` and `@security-auditor` definitions (`agents/`) carry them too.

## 1. Validation bounds must be storable (validation ↔ column type)

**Rule.** For any changed validation or limit on a **persisted** field — a Zod/Joi/Pydantic
`max`/`min`/`length`/`regex`/`enum`, a clamp, a DTO constraint — find the field's column
definition (Drizzle/Prisma/SQL migration/ORM model: `numeric(p,s)`, `decimal`, `varchar(n)`,
`char(n)`, integer width, enum, FK, `NOT NULL`, check constraint) and confirm **every value the
validator accepts is storable**. Check the boundary itself, not just a value near it.

**Severity.** A mismatch where validation accepts a value the column rejects (the request passes
validation, then fails in the database — typically a 500, sometimes silent truncation/rounding)
is **major** (`category: correctness`). Blocker only when it corrupts or silently loses data
already written.

**The miss it prevents.** The PR set a Zod ceiling of `1000` for `cpdHours`; the column is
`numeric(5,2)` (max `999.99`). `"1000"` passes validation and then fails in Postgres as a 500.
The security lane probed the schema, `parseFloat` and the clamp (`1000.00` vs `1000.01`) but never
compared the bound with the column type.

**How to check.** `git grep -n '<fieldName>'` across schema/migration/model files; for a
`numeric(p,s)`, max = `10^(p-s) - 10^-s`; for `varchar(n)`, compare against the validator's
max length **in the same unit** (characters vs bytes). No column definition findable (external
store, untyped JSON) → say so in the finding's `suggestion`, don't guess.

## 2. Vacuous authorization / regression tests are major

**Rule.** A test is **vacuous** when it cannot distinguish "correctly denied" from "denied for
every caller" (or "passes because of the fix" from "passes regardless"). Typical shapes:

- the fixture owner/tenant/scope is `NULL` or unset (`createdBy = NULL`, `hospitalId = NULL`), so
  the ownership comparison fails for reasons unrelated to the check under test;
- only the negative case is asserted (`FORBIDDEN`) — **no positive control** shows an
  authorized caller succeeding against the same fixture;
- the assertion would still pass with the guard deleted or inverted (apply the mutation-gate
  sabotage check, [`mutation-gate.md`](mutation-gate.md), when in doubt).

**Severity.** When such a test is the **only evidence for a security or authorization fix** (or
for the bug the PR claims to fix), it is at least **major** (`category: security` for authZ,
else `correctness`) — the fix is unverified. Suggested fix: populate the owner/tenant fields,
add the positive-control case, and assert both.

**Unchanged.** A test title that doesn't match its assertion stays **minor** unless that test is
the only coverage for the behaviour — then it takes this rule's severity.

**The miss it prevents.** The PR's BDD fixture created a meeting with `createdBy = NULL` and
`hospitalId = NULL`, so its `FORBIDDEN` assertion would pass even if the check rejected every
caller, and no scenario showed an authorized caller succeeding. The review filed it as a minor.

## 3. Control-worth challenge (issue #2996)

When a PR **adds an enforcement control** (CI guard, lint rule, gate, allowlist), the **first** review
states, before itemising any bypass, whether the control's shape can hold: a line-based regex cannot
enforce a semantic rule, and an allowlist read from the PR head can be self-escalated by the PR. If it
cannot, recommend descoping it or a simpler/advisory design as the lead finding. In delta rounds carry
that finding forward at its **original severity**; do not re-litigate it or re-itemise each bypass.

**The miss it prevents.** sge#2995 added a regex guard against new `SGD_` names; three review rounds
found and re-found bypasses before anyone said the shape was wrong, and the control was split out.

**Severity.** An unexamined new enforcement control whose shape cannot hold (bypassable by the PR itself) is `major`; a missed shape challenge on a clearly advisory check is `minor`.
