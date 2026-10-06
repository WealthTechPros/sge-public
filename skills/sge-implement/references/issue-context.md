# sge-implement — why the issue is fetched by a real Bash call

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

> A `!`-preload injection line cannot safely carry `$ARGUMENTS` into Bash — the
> harness substitutes it as raw, unescaped text before any shell parses it, so
> no quoting scheme is safe (confirmed live: a bare `"` breaks
> `bash -c '...' _ "$ARGUMENTS"` and executes arbitrary commands; see
> `no-positional-args-in-injection.test.sh` (SGE source repo: `skills/tests/no-positional-args-in-injection.test.sh`),
> anthropics/claude-code#16163). No in-band fix: fetch the issue as a **real
> Bash tool call you issue yourself**, not a preload.
>
> Resolve the plugin root, then fetch the issue, exactly as written below —
> `<ISSUE-NUMBER>` is the number you parsed from the user's invocation, passed
> as a normal, safely-quoted shell argument (never string-interpolated from
> raw untrusted text):
>
> (fetch command: see `SKILL.md`)
>
> `resolve-sge-root.sh` self-locates via its own `BASH_SOURCE` when run from a
> real checkout (the common case, first branch above); the plugin-cache
> fallback covers an installed-plugin session where `scripts/resolve-sge-root.sh`
> isn't on a relative path — `${CLAUDE_PLUGIN_ROOT}` is real here because this
> runs as an actual Bash tool invocation, not a preload substitution.
