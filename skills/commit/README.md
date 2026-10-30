# Offline staged credential scanning

The commit gate uses **Gitleaks**, not a blanket entropy heuristic. Normal URLs,
paths, hashes and unassigned identifiers do not become credentials merely
because they are long. Gitleaks' maintained provider rules are extended by a
small explicit policy for credential assignments, authentication headers, URL
userinfo and incomplete private-key blocks.

## Setup

Run `bash skills/commit/install-scanner.sh` from the plugin source checkout.
Installed-plugin callers use the same path under their plugin root. Windows
uses Git Bash. Setup requires Node.js, GitHub CLI (or HTTPS curl) and tar/unzip.
It installs the pinned version from official release archives into
`~/.cache/sge/gitleaks/<version>`, checking the committed SHA-256 pins first.
The commit gate makes no downloads and never sends candidates to a service.

Run `bash skills/commit/scan-staged-secrets.sh` **from the repository being
committed**, or use its absolute plugin path. The pinned user-cache install takes
precedence over PATH; a system Gitleaks is accepted only when its version matches
`gitleaks.version`. The wrapper also requires Node.js and Git.

## Findings and boundaries

- Exit **0** means the staged textual additions passed this policy, not proof
  that every possible secret format is detectable.
- Exit **1** names the file, actual added-line number and credential rule.
  Values, snippets and partial token prefixes are never printed.
- Exit **2** means the scanner, Git, configuration or report failed. Fix the
  problem and rerun; an unavailable scan never authorises a commit.
- Remove a staged credential and use an injected secret/reference. Rotate it
  when it has already been exposed. Do not send suspected values for online
  verification.
- Review a false positive against the named rule and add a focused regression
  before changing policy. Do not demand confirmation merely for entropy or
  suppress an entire documentation/test directory.

The plugin's explicit policy extends Gitleaks' default provider rules.
Repository `.gitleaks.toml`, `.gitleaksignore` and inline `gitleaks:allow`
comments cannot silently weaken this gate. Only entirely dummy assignment
values have a narrow test/fixture-path exception; recognisable provider tokens
remain blocked in all paths. The old repository-wide history-scanning policy
is a different control and is not reused here.

Only staged added textual lines are scanned. Existing history, deleted and
unstaged content, binaries and archive contents are not a full scan target.
Use a separate full-repository/history scan when investigating prior exposure.

## Maintenance

Update `gitleaks.version` and the matching official archive entries in
`gitleaks.checksums` together. Run `bash skills/tests/commit-secret-scan.test.sh`
against the real pin, then the existing Skills CI gate. CI and public-publish
verification run the same explicit checksum-verified setup first.
