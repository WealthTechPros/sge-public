# sge-implement — Phase 6 PR body tracking comments

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

Ensure the PR body carries that reference and the two tracking comments (via `gh pr edit --body`):

```
<Closes|Part of> #<issue-number> ...
<!-- sge-cortex-stats: {"cortexHits": N, "cortexMisses": N} -->
<!-- sge-phase5-verdict: {"sha": "<reviewer.sha>", "verdict": "<reviewer.verdict>", "blockers": <reviewer.blockers>, "verification": "<verification_mode>"} -->
<!-- sge-governance-tier: {"tier": "<T0|T1|T2>", "reason": "<reason>"} -->
```

Fill `sge-cortex-stats` from the Phase-0 hit/miss counts (ROI #522), `sge-phase5-verdict` from the Phase 5 reviewer's JSON (`sha`, `verdict`, `blockers`), and `verification` from the Phase 5 `verification_mode`.
