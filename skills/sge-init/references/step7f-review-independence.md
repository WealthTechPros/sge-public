# sge-init — Step 7f: review-independence posture (solo-dev repos)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

This step is a sibling to Step 7e (branch-protection-as-code) — both address solo-developer
posture but from different angles. Step 7e handles branch protection (structural gate);
this step handles **review independence** (who may satisfy the SGE merge gate).

If the repo is solo-dev (same question as Step 7e — do not ask twice; carry the answer
forward), propose writing `.sge/posture.yaml` from the template at
`${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)}/skills/sge-init/templates/posture.yaml` (AI proposes, human
disposes — write only after approval):

- `profile: solo` — declares this is a single-primary-author repo.
- `review_independence: declared-exception` — the repo explicitly opts into a declared,
  PR-reviewable exception in place of the legacy opaque `SGE_GOVERNANCE_PROFILE=solo`
  repo-variable bypass (sge#2219).
- `reviewer_identity: <github-login>` — record the intended name of the dedicated
  non-committing reviewer identity here.  **Do not attempt to create or provision that
  identity in this step** — provisioning is handled separately (S2 of sge#2219,
  docs/reviewer-identity-provisioning.md once that doc exists).  The field value is a
  placeholder until the identity is provisioned and its login is known.

**Constraint — reviewer must not commit.** The identity named in `reviewer_identity` must
never push commits to branches it reviews.  An identity that commits enters the
independence gate's exclusion set and invalidates its own verdicts — making the gate
structurally unsatisfiable (the exact failure mode sge#2219 fixes).  Note this constraint
clearly in any onboarding notes for the repo.

**When to skip:** if the repo already has `.sge/posture.yaml`, skip and note it in the
Review Package.  If the repo is team-dev (multiple independent committers), skip — the
standard independence gate applies without a posture declaration.
