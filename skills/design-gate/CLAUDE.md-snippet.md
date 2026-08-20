# Paste this section into the repo's CLAUDE.md

## Design contract

- `DESIGN.md` is law. Every color, font, spacing, radius, and motion
  decision comes from it. If a needed token doesn't exist, propose the
  token change in DESIGN.md first — never improvise a value inline.
- After ANY change to UI files: screenshot the affected routes via
  Playwright at 1440px and 375px and critique against DESIGN.md before
  moving to the next task. Fix what you find. A change you have not
  seen rendered is not done.
- Never declare UI work complete without a design-reviewer PASS in
  `.claude/design-review/latest.md`. If the reviewer fails you, apply
  its fixes and re-run it — do not argue with it in prose.
- For any new page or component, use the frontend-design skill's
  process: plan direction and tokens first, self-critique the plan
  against generic defaults, then build.
- New visual work starts from the `/design-system` route: compose from
  existing primitives before inventing new ones.
