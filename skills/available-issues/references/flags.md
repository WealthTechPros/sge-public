# `$ARGUMENTS` flags

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

| Flag | Default | Meaning |
|------|---------|---------|
| `--parallel` | off | Return the largest **conflict-free** set instead of a plain ranked list |
| `--count N` | unbounded (`--parallel`: pool budget) | Cap the returned set size |
| `--setup` | off | After selecting, claim each issue and create its worktree (see *Setup*) |
| `--mode autonomous-next` | off | Emit exactly **one** issue — the top-priority ready one — as machine-readable JSON for an autonomous loop |
| `--blocking` | off | Report only blocked issues and their blockers (the inverse view) |
| `--analyze N` | off | Deep-analyse a single issue `N` (dependencies, conflict surface) and stop |
| `--module <name>` | all | Filter to the `module:<name>` GitHub label |
| `--milestone <name>` | all | Scope to a GitHub milestone |
| `--repo <target>` | current checkout | Explicit single-repo target (`name`, `owner/name`, or GitHub URL) — resolved via the SPEC-057 helper (see *Pre-flight*). Pass it whenever the session is not already checked out in the target repo (hub/control sessions) |
| `--fleet <org\|r1,r2,…>` | off | Aggregate the worklist across a **fleet** of repos — a GitHub org (single token, no comma/slash) or an explicit comma-separated repo list. Fleet membership comes from this argument only — never from names baked into the skill. See *Fleet mode* |
