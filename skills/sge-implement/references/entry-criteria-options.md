# Phase 1 entry-criteria recovery options

When `/sge:sge-preflight` returns `readyToBuild: false`, map each reported failure to its recovery options below. Every option gate is presented via AskUserQuestion — never free-text, never a dead-end stop.

**Spec file does not exist:**
- Option A: "The spec is in a combined file" — read from it
- Option B: "Create the spec first" — stop
- Option C: "Cancel"

**A dependency is not built:**
- Option A: "Implement the dependency first"
- Option B: "Implement anyway (stubs)" — proceed with TODO markers
- Option C: "Cancel"

**No acceptance criteria found** (issue body and spec both lack Gherkin scenarios):
- Option A: "Use the spec's acceptance criteria"
- Option B: "Generate criteria from the spec" — auto-generate, show for approval
- Option C: "Proceed without criteria"
- Option D: "Cancel"

**An unresolved Open Question (QD-NN) blocks the spec** — an unresolved QD that gates the spec means it is **not ready to build**:
- Option A: "Resolve the QD first" — stop; link the blocking QD
- Option B: "Proceed with a recorded assumption" — state the assumption on the issue, carry it into the PR body
- Option C: "Cancel"
