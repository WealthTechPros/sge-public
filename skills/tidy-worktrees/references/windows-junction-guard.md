# Windows junction guard (Phase 4, Steps 4a–4b)

Moved verbatim from `SKILL.md` (issue #2917, 24 KB size budget).

> ⚠️ **Windows data-loss hazard.** On Windows, repos whose worktrees are wired up by a junction-clone (NTFS directory junctions linking shared build artefacts such as `packages-shared/`, `api/backend-core/`, or `packages/core-*` into each worktree) will have `git worktree remove` — and any recursive `rm -rf` — **follow the junctions and delete the real target files**. This has caused loss of 1000+ source files in a single sweep. Always run this guard before removing a worktree path on Windows.

**Step 4a — Detect junctions (Windows only).**

On Windows (any of: `$WINDIR` set, `uname -s` starts with `MINGW`/`MSYS`/`CYGWIN`, or `[System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)` returns true):

```powershell
# PowerShell — enumerate every directory junction inside the worktree path
$junctions = Get-ChildItem -Path "<worktree-path>" -Recurse -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.LinkType -eq 'Junction' }
```

If `$junctions` is non-empty, **add a prominent notice to the deletion plan** before the user confirms:

```
⚠️  WINDOWS JUNCTIONS DETECTED in <path>
    The following NTFS directory junctions will be UNLINKED before removal.
    git worktree remove follows junctions and would delete the real target files.
    Junctions unlinked: <list each junction FullName>
    Targets are untouched — only the link is removed.
```

**Step 4b — Unlink junctions first (Windows only, if any found).**

`cmd /c rmdir` removes an NTFS directory junction *link* without touching or recursing into the target directory. Do **not** use `Remove-Item -Recurse` or `rm -rf` — those follow the junction and destroy the target.

```powershell
foreach ($j in $junctions) {
    # cmd /c rmdir removes the junction link; /s is NOT passed — target is untouched
    # Quotes are required so paths containing spaces are passed as a single argument.
    cmd /c rmdir "$($j.FullName)"
}
```

Verify each junction is gone before proceeding:

```powershell
foreach ($j in $junctions) {
    if (Test-Path "$($j.FullName)") { throw "Junction still present after unlink: $($j.FullName)" }
}
```

Only after all junctions are confirmed unlinked is it safe to proceed to `git worktree remove` or any recursive delete.

**Non-Windows:** skip Steps 4a–4b entirely; junction handling is a Windows/NTFS concept.
