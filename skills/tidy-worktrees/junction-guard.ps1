# junction-guard.ps1: Windows link guard for tidy-worktrees' execute.sh (issue #3621).
# Unlinks every UNTRACKED directory junction / symlink (reparse point) inside a
# worktree BEFORE `git worktree remove`, which on Windows follows junctions and
# deletes the real target files. Walks one level at a time and never descends
# into a reparse point (Get-ChildItem -Recurse on Windows PowerShell 5.1
# follows junctions, so it is not used). Each link is removed with a
# NON-recursive Directory.Delete, which cannot delete files: only the link.
# -SkipFile lists git-tracked link paths (relative, '/'-separated) to leave for
# git, which removes them as links. Prints the number of links unlinked. Any
# error exits non-zero and the caller skips the worktree (fail closed).
# -CheckOnly refuses every directory reparse point before unlinking anything.
param([Parameter(Mandatory = $true)][string]$Path, [string]$SkipFile = '', [switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
try {
  $root = Get-Item -LiteralPath $Path -Force
  if ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "worktree path is itself a link: $Path" }
  $rootFull = $root.FullName.TrimEnd('\')
  $skip = @{}
  if ($SkipFile) { foreach ($s in [IO.File]::ReadAllLines($SkipFile)) { if ($s) { $skip[$s.ToLowerInvariant()] = $true } } }
  $queue = [System.Collections.Generic.Queue[string]]::new()
  $queue.Enqueue($rootFull)
  $links = [System.Collections.Generic.List[string]]::new()
  while ($queue.Count -gt 0) {
    $dir = $queue.Dequeue()
    foreach ($child in Get-ChildItem -LiteralPath $dir -Force -Directory) {
      if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($CheckOnly) { throw 'directory reparse point requires separate preservation' }
        $rel = $child.FullName.Substring($rootFull.Length + 1).Replace('\', '/').ToLowerInvariant()
        if (-not $skip.ContainsKey($rel)) { $links.Add($child.FullName) }
      } else { $queue.Enqueue($child.FullName) }
    }
  }
  foreach ($link in $links) {
    [System.IO.Directory]::Delete($link, $false)
    if (Test-Path -LiteralPath $link) { throw "link still present after unlink: $link" }
  }
  Write-Output $links.Count
  exit 0
} catch {
  [Console]::Error.WriteLine("junction-guard: $($_.Exception.Message)")
  exit 1
}
