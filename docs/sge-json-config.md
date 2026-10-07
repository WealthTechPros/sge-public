# `.claude/sge.json` — per-repo SGE configuration

SGE ships with neutral defaults. Anything that names a specific organisation's
people, bots, hosts or tooling is a **config value**, not plugin text: set it in
the repo's own `.claude/sge.json` (committed on the default branch), or override
it per host or session with the matching environment variable. The environment
variable always wins over the file. (SPEC-130.)

```json
{
  "gateOwner": "pod",
  "intakeApprovers": ["octocat"],
  "agentBotLogin": "acme-agent[bot]",
  "decisionOwner": "Jane Doe",
  "secretsStore": "Vault",
  "podsRegistry": "~/.acme/pods/pods.json"
}
```

## Keys

| Key | Env override | Default (neutral) | What it does |
|-----|--------------|-------------------|--------------|
| `gateOwner` | `SGE_GATE_OWNER` | unset (self-drive) | `pod` hands the `pr-reviewed` gate to a review pod or daemon. See `/sge:sge-implement`'s pod-gate mode. |
| `intakeApprovers` | — | none (the intake gate is not adopted) | GitHub logins whose `## SGE intake` record unlocks a build. Read from the default branch only, by `scripts/intake-check.sh` (SPEC-126). This is the repo's **approver identity**. |
| `agentBotLogin` | `SGE_AGENT_BOT_LOGIN` | none | The GitHub App login your agents author PRs and comments as (for example `acme-agent[bot]`). An App has repo association `NONE`, so the shared PR claim protocol trusts its claims only when it is named here. With no value, no extra App is trusted. Only a comment whose author account type is `Bot` matches. Read by `skills/pr-review/pr-labels.sh` from the base repository's default branch only, fetched through the GitHub API each time it is needed: never from the working tree, a fork remote or a local ref that may be stale, so a PR cannot trust its own author and a removed login stops being trusted at once. |
| `decisionOwner` | — | "the repo owner" | The person skills name when a decision needs an owner (for example in a `needs-decision` rationale). Prose only. Who may actually approve is `intakeApprovers`. |
| `secretsStore` | — | "your secrets manager" | The name of the secrets manager that injects tokens into the environment. SGE never reads secrets from a file or a store directly; skills only name the store when they tell you a token is missing. |
| `podsRegistry` | `SGE_PODS_REGISTRY` | `~/.sge/pods/pods.json` | The fleet pod registry: `pods[]` entries with `type: "review-daemon"` mark repos a review daemon covers, so `hooks/pr-created.sh` does not race it with a session-local review. A leading `~/` means `$HOME`. |

## Where the values come from

- **The file.** Scripts read `.claude/sge.json` from the root of the git repo
  they run in (`git rev-parse --show-toplevel`, else the current directory).
  `intakeApprovers` and `agentBotLogin` are the exceptions: they are read from
  the default branch (`intakeApprovers` freshly fetched, `agentBotLogin` read from the base
  repository's default branch through the GitHub API at read time), so a branch cannot
  approve itself or make its own author a trusted claimant.
- **The environment.** Every key with an env override can be set per host, for
  example in the service unit of a review daemon that covers many repos. Set
  the variable to an empty string to force the neutral default.

## Publisher values never ship

The public distribution is linted at publish time
(`.github/scripts/public-hooks.sh brand-lint` against
`.github/scripts/publish-brand-denylist.txt`). A publisher's own values for
these keys belong in its own repos' `.claude/sge.json`, never in skill text.
