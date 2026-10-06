# sge-init — Step 7f: recurring drift-check cadence

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

`sge-init`'s output (Steps 1–7e) is a **governance snapshot at t=0** — Vision, capability model, specs, ADRs, the QD registry, and (where adopted) the Step 7b C11 posture baseline, explicitly seeded "so future sweeps can report a delta." A snapshot with an intended delta but no scheduled re-measurement is a delta of one: nothing in Steps 1–9 proposes *when* that next data point gets produced. `/sge:sge-align` (drift detection) and `/sge:drift-hillclimb --auto-dimension` (the scheduled climb cadence) both already exist in the plugin — this step just proposes wiring the freshly onboarded repo into them.

Propose one of the following (AI proposes, human disposes — write only after approval), same tier-by-repo-capability judgement as Step 7b:

1. **Preferred, if the repo has CI:** propose adding `.github/workflows/improvement-sweep.yml`, copied from this framework repo's own `.github/workflows/improvement-sweep.yml` (dependency-free Node picker + a guarded climb step that only fires when `ANTHROPIC_API_KEY` is configured — inert-safe without it). Templatize the one repo-specific value it carries: the `--repo <name>` arg passed to `select-gap.mjs` inside the `pick` job. This gives the repo the same weekly (`cron: '0 7 * * 1'`) cadence this framework repo runs on itself, appending a visible delta row every cycle — acted, skipped, or failed, never silent.
2. **Fallback, if the repo has no CI or isn't ready for the full sweep asset tree:** propose, at minimum, a recorded decision in the Review Package (Step 9): "drift re-check cadence: `<proposed interval>`, owner: `<stakeholder>`" — so the absence of automation is a visible, deliberate choice, not a silent gap.

Skip and note in the Review Package only if the repo is explicitly ideation-stage with no runtime code and no near-term implementation planned (drift has nothing to measure yet) — otherwise always propose at least option 2.
