# Pre-flight: `unknown` host kind on a self-hosted Forgejo

Reference detail for `SKILL.md`'s Pre-flight entry sequence — the `HOST_KIND = "unknown"` warning right after the host-detection line.

## Why this can happen

A self-hosted Forgejo/Gitea whose hostname contains neither `"forgejo"` nor `"gitea"` (a vanity domain, e.g. `git.example.com`) classifies as `unknown` from `with-repo-cwd.sh`'s host detector. That is **correct, fail-safe behaviour** (see `with-repo-cwd.sh`'s own docstring, ADR-0010) — **not a bug**. The host classifier only auto-recognises the literal substrings `forgejo`/`gitea`; a self-hosted instance with any other hostname must be declared explicitly via `SGE_FORGEJO_HOSTS` (or `SGE_FORGEJO_DEFAULT_HOST`).

## Why the pre-flight sequence warns about it explicitly

`issue-read.sh`'s own dispatch (`list`/`view`/etc.) already fails loud with an actionable message naming `SGE_FORGEJO_HOSTS` when it hits an `unknown` host — but that message only fires on the **first actual issue-read call**, several steps downstream of the pre-flight echo. Without a warning at the pre-flight point itself, an operator sees a bare `host: unknown` in the pre-flight echo with no explanation, and only learns what to do about it several steps later (or not at all, if the failure is swallowed). The pre-flight sequence surfaces the same guidance immediately, so an `unknown` host is never a silent surprise discovered only after Phase 1 has already started.

## The fix

Set `SGE_FORGEJO_HOSTS` (semicolon-separated bare hostnames) before continuing, e.g.:

```bash
export SGE_FORGEJO_HOSTS="git.example.com"
```

Then re-run the pre-flight sequence — `HOST_KIND` will resolve to `forgejo` and every downstream `issue-read.sh` call routes through the Forgejo/Gitea adapter correctly.
