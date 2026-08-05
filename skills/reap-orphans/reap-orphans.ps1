# /sge:reap-orphans — Safe Process Reaper (Windows)
#
# Bundled script for the reap-orphans skill (issue #822). Kills orphaned
# claude/node/bash processes whose parent is already dead, protects the
# current session tree, and reports live resource hogs. See ../SKILL.md for
# the contract, flags, and how it is invoked.
#
# Usage: pwsh -File reap-orphans.ps1 [-DryRun] [-HogMB <MB>]
param(
  [switch]$DryRun,
  [int]$HogMB = 400
)

$ErrorActionPreference = 'SilentlyContinue'

# Build process map with INT keys (UInt32/Int32 mismatch silently breaks lookups)
$alive = @{}
Get-CimInstance Win32_Process | ForEach-Object { $alive[[int]$_.ProcessId] = $_ }

# Protect the current session's claude ancestor + its whole descendant tree
$protect = New-Object System.Collections.Generic.HashSet[int]
[void]$protect.Add([int]$PID)
$p = $alive[[int]$PID]
while ($p) {
  [void]$protect.Add([int]$p.ProcessId)
  if ($p.Name -eq 'claude.exe') { break }
  $par = [int]$p.ParentProcessId
  if (-not $alive.ContainsKey($par)) { break }
  $p = $alive[$par]
}
$changed = $true
while ($changed) {
  $changed = $false
  foreach ($k in @($alive.Keys)) {
    $par = [int]$alive[$k].ParentProcessId
    if ($protect.Contains($par) -and -not $protect.Contains($k)) { [void]$protect.Add($k); $changed = $true }
  }
}

$reapNames = @('claude.exe','node.exe','bash.exe')

# Root orphans: target-named procs whose parent PID is gone
$kill = New-Object System.Collections.Generic.HashSet[int]
foreach ($proc in $alive.Values) {
  if ($proc.Name -notin $reapNames) { continue }
  if ($protect.Contains([int]$proc.ProcessId)) { continue }
  if (-not $alive.ContainsKey([int]$proc.ParentProcessId)) { [void]$kill.Add([int]$proc.ProcessId) }
}
# Expand to dead trees: any target proc whose parent is already in the kill set
$changed = $true
while ($changed) {
  $changed = $false
  foreach ($proc in $alive.Values) {
    if ($proc.Name -notin $reapNames) { continue }
    $id = [int]$proc.ProcessId
    if ($protect.Contains($id) -or $kill.Contains($id)) { continue }
    if ($kill.Contains([int]$proc.ParentProcessId)) { [void]$kill.Add($id); $changed = $true }
  }
}

$os = Get-CimInstance Win32_OperatingSystem
$bFree = [math]::Round($os.FreePhysicalMemory/1MB,2)
$bPage = (Get-CimInstance Win32_PageFileUsage).CurrentUsage
$usedPct = [math]::Round(($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/$os.TotalVisibleMemorySize*100,0)

Write-Output "=== reap-orphans  (RAM used ${usedPct}%, ${bFree} GB free, pagefile ${bPage} MB) ==="
Write-Output "Protected session tree: $($protect.Count) procs (current claude is safe)"

if ($kill.Count -eq 0) {
  Write-Output "No orphaned debris found. Clean."
} else {
  $list = $kill | ForEach-Object { $alive[$_] } | Sort-Object Name, ProcessId
  Write-Output "Orphans to reap: $($kill.Count)  ($(( $list | Group-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '))"
  $freedEst = [math]::Round((($list | ForEach-Object { (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue).WorkingSet64 } | Measure-Object -Sum).Sum)/1GB,2)
  foreach ($proc in $list) {
    $tag = if ($DryRun) { 'WOULD KILL' } else { 'KILL' }
    Write-Output ("  {0,-10} {1,-11} PID {2,-7} parent {3} (dead)" -f $tag,$proc.Name,$proc.ProcessId,$proc.ParentProcessId)
    if (-not $DryRun) { Stop-Process -Id $proc.ProcessId -Force }
  }
  if (-not $DryRun) {
    Start-Sleep -Seconds 2
    $os2 = Get-CimInstance Win32_OperatingSystem
    $aFree = [math]::Round($os2.FreePhysicalMemory/1MB,2)
    Write-Output "Reaped $($kill.Count). RAM freed ~$([math]::Round($aFree-$bFree,2)) GB (now $aFree GB free)."
  } else {
    Write-Output "(dry run) Estimated reclaimable: ~${freedEst} GB"
  }
}

Write-Output ""
Write-Output "--- Live processes worth a look (NOT killed) ---"
$nowKept = Get-Process | Where-Object {
  $_.WorkingSet64/1MB -ge $HogMB -and -not $kill.Contains([int]$_.Id)
} | Sort-Object WorkingSet64 -Descending | Select-Object -First 10
$nowKept | ForEach-Object {
  $ageH = if ($_.StartTime) { [math]::Round(((Get-Date)-$_.StartTime).TotalHours,1) } else { '?' }
  "{0,-12} PID {1,-7} {2,6} MB  age {3}h  cpu {4}s" -f $_.Name,$_.Id,[math]::Round($_.WorkingSet64/1MB,0),$ageH,[math]::Round($_.CPU,0)
}
$claudeN = (Get-Process claude -ErrorAction SilentlyContinue).Count
$nodeN   = (Get-Process node -ErrorAction SilentlyContinue).Count
Write-Output ""
Write-Output "Live claude sessions: $claudeN   node/MCP procs: $nodeN   (close unused sessions to cut both)"
