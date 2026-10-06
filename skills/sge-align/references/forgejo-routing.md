# Run context — issue-read routing and self-hosted Forgejo/Gitea

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

`IR` (`scripts/issue-read.sh`) routes issue list/view calls through `scripts/forgejo-adapter.sh` when the repo host is Forgejo/Gitea, and delegates to `gh` unchanged for GitHub. Re-define `IR` at the top of every subsequent Bash call (same SPEC-057 shell-state rule as `WRC`).

**Self-hosted Forgejo/Gitea:** the host is classified by hostname substring (`*forgejo*`/`*gitea*`); a self-hosted instance on a vanity domain (e.g. `git.example.com`) needs `SGE_FORGEJO_HOSTS` (`;`-separated bare hosts) declared before sweeping it — otherwise `IR` fails loud naming the unrecognised host (ADR-0010).
