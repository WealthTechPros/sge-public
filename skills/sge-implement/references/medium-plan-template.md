# Medium-tier plan template (issue #3522)

Use this template for a **Medium** change (complexity score 16-30, Phase 2) in
either lane, before Phase 3 edits. Its job is to catch integration mistakes
(a task consuming an interface no task produces, a name spelt two ways, an
input nobody tests) while they are still cheap. It is also what the A1 opus
plan advisor reviews on T1/T2.

**Small (≤ 15) is not burdened by it:** a Small change keeps the brief phased
checklist the lane already asks for. **Large (> 30)** is split into child
issues first, and each child is sized on its own.

## Template

```markdown
## Plan: #<issue> — <title>   (Medium, score <N>)

### File map
Every file this change creates, modifies or deletes, with one line on why.
Exact paths, no globs.
- `path/to/file.ext` (modify) — <why>
- `path/to/new_file.ext` (create) — <why>

### Tasks
One entry per vertical slice, in build order.
1. <task name> — criterion: <AC it satisfies>
   - consumes: <functions, types, endpoints, config, data it relies on, and which task or existing file provides each>
   - produces: <the functions, types, endpoints or data it adds or changes, with signatures>
   - test: <the failing test that drives it>
2. ...

### Review focus
Input cases no task's test covers (empty, null, very large, unicode, concurrent,
a partial upstream response, permission edge cases ...), each with a reason it
is acceptable or a note for the reviewer to check.
- <case> — <why untested / what to check>

### Self-check
- [ ] Every `consumes` entry is produced by an earlier task or already exists.
- [ ] Names and types are consistent across tasks: one spelling per
      function, field, type and route, and matching signatures between each
      producer and its consumers.
- [ ] Every file in the map is touched by a task, and every task's files are in the map.
- [ ] Every acceptance criterion is satisfied by at least one task.
```

Keep the plan in the session (or the PR body's plan section when one is
open); it is not a committed file. When the build departs from the plan,
update the plan rather than letting it go stale.
