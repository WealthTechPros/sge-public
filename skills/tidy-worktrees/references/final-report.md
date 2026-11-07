# Final report

Close every run with one table. Every audited item appears exactly once and ends in exactly one of four states.

| Item (kind, name, tip) | Bucket | End state | Evidence |
|---|---|---|---|
| `remote-branch feat/x 3f2c…` | A | **already in main** (and removed from origin) | merged PR #12, tip equals PR head |
| `branch feat/y 91ab…` | B | **PR opened** (draft) | link; "Part of #N"; not merged |
| `worktree ../r-wt/z c0de…` | C | **kept, blocker: <named>** | missing acceptance criterion 2 / open PR #20 / uncommitted `a.ts` |
| `branch feat/old 77fe…` | D | **discarded with SHA 77fe…** | no surviving commits vs origin/main |

Rules:
- Distinguish committed, pushed, PR opened and verified merged. A PR or a checkpoint is not integration.
- Name uncommitted files that were discarded: a SHA cannot recover them.
- List unattributed stashes as a note.
- End with `Outstanding decisions: none` or the list. **Never say the tidy is done while any decision is outstanding**; say what is waiting and on whom.
- If the open-PR set was unknown, say "audit only, nothing removed".
- Quote bucket counts before and after, so a reader sees the repo converge.
