# Routine environment recipe — running SGE dispatch skills in the cloud sandbox

Follow-up from the Routines-compatibility audit
(`docs/audits/2026-07-15-routines-compatibility-team-pipeline-available-issues.md` (SGE source repo),
Q2). This is the operator recipe for pointing a
[Claude Code Routine](https://code.claude.com/docs/en/routines) (Anthropic-managed
cloud session) at `/sge:available-issues`, `/sge:team-pipeline`, or
`/sge:fleet-dispatch`.

The dispatch skills shell out to `gh` and assume it is installed and
authenticated. Both assumptions hold in an interactive workstation, but a fresh
Routine sandbox is different in two ways you must account for **before** the
first run.

## 1. `gh` is not pre-installed — install it in the setup script

A Routine sandbox does **not** ship the GitHub CLI. Install it in the
environment's **setup script**, which runs once per environment and is cached
across subsequent executions:

```bash
apt-get update && apt-get install -y gh
```

If the base image already carries `gh`, the install is a fast no-op — the line
is safe to keep unconditionally. Verify in the same script if you want a loud
failure at setup time rather than mid-run:

```bash
apt-get update && apt-get install -y gh
gh --version   # fail the setup if gh did not install
```

## 2. Auth comes from the GitHub proxy — not an operator PAT

The Routine sandbox authenticates outbound GitHub calls through a **built-in
GitHub proxy**. You do **not** provision a personal access token.

- With `GH_TOKEN` / `GITHUB_TOKEN` left unset, the container sets both to the
  placeholder value `proxy-injected`.
- On outbound calls to `api.github.com` / `github.com`, the proxy substitutes
  the real credential. `gh` works with the placeholder in place.
- `api.github.com` and `github.com` are in the default **Trusted network
  allowlist**, so no extra network configuration is needed.

The practical consequence: `gh auth status` behaves differently from a
workstation. The token is present (as the placeholder) but is not a locally
minted credential. The dispatch skills' preflight is **Routine-aware** — it
treats `GH_TOKEN=proxy-injected` as authenticated and does not hard-exit when no
local token is present. See the pre-flight snippets in
[`available-issues`](../skills/available-issues/SKILL.md) and
[`team-pipeline`](../skills/team-pipeline/SKILL.md).

## Recommended rollout

Adopt the conservative sequence from the audit — validate cheaply before
spending usage quota on real implementation:

1. Scheduled Routine, `/sge:available-issues` (no `--setup`) — read-only, a few
   times a day.
2. Scheduled Routine, `/sge:team-pipeline --dry-run --duration 30m` — validates
   the queue and budget arithmetic in the cloud sandbox.
3. Drop `--dry-run`; keep `--agents` / `--ci-limit` / `--session-budget`
   conservative (shared usage quota is the binding resource, not wall-clock).
4. For fleet runs, pass an **explicit** `--fleet <repo,repo,...>` that matches
   the repos attached to the Routine — not `--fleet <org>` live enumeration
   (only attached repos are cloned into the sandbox).

## Isolation checklist for worker fan-out

Before increasing worker count in Routines throughput mode:

- ensure each lane runs in its own worktree (no shared mutable checkout),
- require `agent-lock` claim before implementation starts,
- verify stale-claim reclaim is enabled (TTL + heartbeat policy),
- keep review/merge gates centralised so producer fan-out cannot bypass quality.
