# /sge:reap-orphans — Safe Process Reaper (Windows)
#
# Bundled script for the reap-orphans skill (issue #822). Kills orphaned
# claude/node/bash processes whose parent is already dead, protects the
# current session tree, and reports live resource hogs. See ../SKILL.md for
# the contract, flags, and how it is invoked.
#
# -Heavy (the skill's --heavy, was /sge:cleanup — #2915) first runs the bundled
# heavy-reset.ps1: kill Playwright/headless Chromium test runners and, unless
# -NoWSL, shut down WSL. The orphan scan below then runs on what is left.
#
# GITHUB COPILOT CLI (#3367). Copilot processes are a SEPARATE lane that the
# generic claude/node/bash rule below can never reach. A Copilot client
# (copilot.exe, or node.exe hosting the @github/copilot package, with no
# server/ACP flag) is reaped only when ALL hold; every other shape is kept:
#   a. its parent is absent from the process table,
#   b. a strictly valid per-user lifecycle record binds this exact PID + start
#      identity (creation time) + owner, with intent=interactive,
#   c. the record says the session ended (state=ended, past the end grace) or
#      went silent (state=active, no heartbeat for COPILOT_ABANDON_MIN),
#   d. all of that is re-validated from a fresh process snapshot immediately
#      before Stop-Process (PID reuse -> no kill).
# Parent loss, age, memory and flags alone never qualify; a missing, malformed,
# stale or contradictory record is report-only. Copilot command lines are never
# printed. Only the single Copilot PID is stopped (never its tree). Windows has
# no TERM/KILL pair, so there is one re-validation, directly before the stop.
#
# Usage: pwsh -File reap-orphans.ps1 [-Heavy [-NoWSL]] [-DryRun] [-HogMB <MB>]
#
# Test seams (fixtures only; never needed in real use):
#   SGE_REAP_PROC_FIXTURE[_2|_3]  JSON array of {ProcessId,ParentProcessId,Name,CommandLine,Identity,Owner}
#                                 in place of Win32_Process (_2/_3 = later re-validation snapshots)
#   SGE_REAP_SELF_PID, SGE_REAP_NOW, SGE_REAP_USER   pin self pid / clock / current user
#   SGE_REAP_KILL_LOG             mock termination: append "STOP pid" here, stop nothing
#   SGE_COPILOT_SESSION_DIR, COPILOT_ABANDON_MIN, COPILOT_END_GRACE_SEC
param(
  [switch]$DryRun,
  [int]$HogMB = 400,
  [switch]$Heavy,
  [switch]$NoWSL
)

$ErrorActionPreference = 'SilentlyContinue'

if ($Heavy) {
  & (Join-Path $PSScriptRoot 'heavy-reset.ps1') -DryRun:$DryRun -NoWSL:$NoWSL
  Write-Output ""
}

$FixtureMode = [bool]$env:SGE_REAP_PROC_FIXTURE
$MockKill = $env:SGE_REAP_KILL_LOG

function ConvertTo-Seconds($v, [int64]$default) { $n = 0L; if ([int64]::TryParse([string]$v, [ref]$n) -and $n -ge 0) { return $n } else { return $default } }
$Now = ConvertTo-Seconds $env:SGE_REAP_NOW ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
$AbandonSec = (ConvertTo-Seconds $env:COPILOT_ABANDON_MIN 360) * 60
$EndGraceSec = ConvertTo-Seconds $env:COPILOT_END_GRACE_SEC 300
$Me = if ($env:SGE_REAP_USER) { $env:SGE_REAP_USER } elseif ($env:USERDOMAIN) { "$($env:USERDOMAIN)\$($env:USERNAME)" } else { [Environment]::UserName }
$SessionDir = if ($env:SGE_COPILOT_SESSION_DIR) { $env:SGE_COPILOT_SESSION_DIR }
              elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'sge\copilot-sessions' }
              else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local/state/sge/copilot-sessions' }
$SelfPid = if ($env:SGE_REAP_SELF_PID) { [int]$env:SGE_REAP_SELF_PID } else { [int]$PID }

# Process snapshot keyed by INT pid (UInt32/Int32 mismatch silently breaks lookups).
function Get-ProcTable([int]$Phase) {
  if ($FixtureMode) {
    $f = $env:SGE_REAP_PROC_FIXTURE
    if ($Phase -eq 2 -and $env:SGE_REAP_PROC_FIXTURE_2) { $f = $env:SGE_REAP_PROC_FIXTURE_2 }
    if ($Phase -ge 3) {
      if ($env:SGE_REAP_PROC_FIXTURE_3) { $f = $env:SGE_REAP_PROC_FIXTURE_3 }
      elseif ($env:SGE_REAP_PROC_FIXTURE_2) { $f = $env:SGE_REAP_PROC_FIXTURE_2 }
    }
    $rows = @(Get-Content -Raw -LiteralPath $f | ConvertFrom-Json | ForEach-Object { $_ })
  } else {
    $rows = @(Get-CimInstance Win32_Process | ForEach-Object { $_ })
  }
  $t = @{}
  foreach ($r in $rows) {
    $ident = if ($FixtureMode) { [string]$r.Identity } elseif ($r.CreationDate) { $r.CreationDate.ToUniversalTime().ToString('yyyyMMddTHHmmssZ') } else { '' }
    $t[[int]$r.ProcessId] = [pscustomobject]@{
      ProcessId       = [int]$r.ProcessId
      ParentProcessId = [int]$r.ParentProcessId
      Name            = [string]$r.Name
      CommandLine     = [string]$r.CommandLine
      Identity        = $ident
      Owner           = if ($FixtureMode) { [string]$r.Owner } else { $null }
      WorkingSetSize  = [int64]$r.WorkingSetSize
    }
  }
  return $t
}

# Owner is only resolved for Copilot clients (GetOwner is slow per process).
function Get-ProcOwner($p) {
  if ($FixtureMode) { return [string]$p.Owner }
  $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ProcessId)"
  if (-not $cim) { return '' }
  $o = Invoke-CimMethod -InputObject $cim -MethodName GetOwner
  if ($o -and $o.User) { return "$($o.Domain)\$($o.User)" }
  return ''
}

# Copilot process signature (shared with copilot-session-record.ps1): Get-CopilotKind.
. (Join-Path $PSScriptRoot 'copilot-signature.ps1')

# ---- lifecycle records (per-user store; see SKILL.md) ----
# Windows trust check (#3367): the path must be OWNED by the current Windows user and no other
# principal (beyond SYSTEM, Administrators, CREATOR OWNER) may hold any write-class right on it,
# otherwise another user could plant or swap a record naming us as owner. Fails closed on any
# error. Always on for the real Windows process table; SGE_REAP_ACL_CHECK=1 forces it in fixture mode.
$script:CheckAcl = ($env:SGE_REAP_ACL_CHECK -eq '1') -or (-not $FixtureMode -and $env:OS -eq 'Windows_NT')
function Test-TrustedPath([string]$path) {
  if (-not $script:CheckAcl) { return $true }
  try {
    $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $me) { return $false }
    $trusted = @($me, 'S-1-5-18', 'S-1-5-32-544', 'S-1-3-0')
    $fsr = [Security.AccessControl.FileSystemRights]
    $write = $fsr::WriteData -bor $fsr::AppendData -bor $fsr::WriteExtendedAttributes -bor $fsr::WriteAttributes `
      -bor $fsr::Delete -bor $fsr::DeleteSubdirectoriesAndFiles -bor $fsr::ChangePermissions -bor $fsr::TakeOwnership
    foreach ($ace in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
      if ($ace.AccessControlType -ne 'Allow') { continue }
      if ($trusted -contains $ace.IdentityReference.Value) { continue }
      if (($ace.FileSystemRights -band $write) -ne 0) { return $false }
    }
    return $true
  } catch { return $false }
}

$script:StoreOk = $false; $script:StoreWhy = ''
function Test-Store {
  $script:StoreOk = $false
  $item = Get-Item -LiteralPath $SessionDir -Force
  if (-not $item -or -not $item.PSIsContainer) { $script:StoreWhy = 'no record store'; return }
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $script:StoreWhy = 'record store is a link'; return }
  if (-not (Test-TrustedPath $SessionDir)) { $script:StoreWhy = 'record store not owned by this user or writable by others'; return }
  $script:StoreOk = $true
}

# Returns a hashtable for a strictly valid record, else $null. $script:ClaimedPid is set
# whenever the file names a pid, so an invalid file still makes that pid report-only.
function Read-Record([string]$path) {
  $script:ClaimedPid = $null
  $item = Get-Item -LiteralPath $path -Force
  if (-not $item -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
  if (-not (Test-TrustedPath $path)) { return $null }
  $lines = @(Get-Content -LiteralPath $path -TotalCount 17)
  if ($lines.Count -gt 16) { return $null }
  $allowed = @('schema', 'session', 'pid', 'start', 'owner', 'intent', 'state', 'updated')
  $r = @{}
  foreach ($line in $lines) {
    $i = $line.IndexOf('=')
    if ($i -lt 1) { return $null }
    $k = $line.Substring(0, $i); $v = $line.Substring($i + 1).TrimEnd("`r")
    if ($k -eq 'pid' -and $v -match '^[0-9]+$') { $script:ClaimedPid = [int]$v }
    if ($allowed -notcontains $k) { return $null }
    if ($r.ContainsKey($k)) { return $null }          # duplicate key = contradictory
    $r[$k] = $v
  }
  foreach ($k in $allowed) { if (-not $r.ContainsKey($k)) { return $null } }
  if ($r.schema -ne '1') { return $null }
  if ($r.session -notmatch '^[A-Za-z0-9._-]{1,128}$') { return $null }
  if ((Split-Path -Leaf $path) -ine ($r.session + '.rec')) { return $null }
  if ($r.pid -notmatch '^[0-9]{1,10}$' -or $r.updated -notmatch '^[0-9]{1,12}$') { return $null }
  if ($r.state -notin @('active', 'ended')) { return $null }
  if ($r.intent -notin @('interactive', 'detached', 'acp', 'server')) { return $null }
  if ($r.start -notmatch '^[A-Za-z0-9 :._+-]{1,64}$') { return $null }
  if ($r.owner -notmatch '^[A-Za-z0-9._@\\-]{1,64}$') { return $null }
  if ([int64]$r.updated -gt ($Now + 60)) { return $null }   # a record from the future is not trustworthy
  return $r
}

$script:RecByPid = @{}; $script:BadPids = New-Object 'System.Collections.Generic.HashSet[int]'
function Build-Index {
  $script:RecByPid = @{}; $script:BadPids = New-Object 'System.Collections.Generic.HashSet[int]'
  if (-not $script:StoreOk) { return }
  foreach ($f in @(Get-ChildItem -LiteralPath $SessionDir -Filter '*.rec' -File -Force)) {
    $r = Read-Record $f.FullName
    if ($r) {
      $p = [int]$r.pid
      if (-not $script:RecByPid.ContainsKey($p)) { $script:RecByPid[$p] = @() }
      $script:RecByPid[$p] += , $r
    } elseif ($null -ne $script:ClaimedPid) { [void]$script:BadPids.Add([int]$script:ClaimedPid) }
  }
}

# Decides eligibility from a table (a fresh snapshot for phase > 1). Sets
# $script:Verdict = reap|keep, $script:Why, $script:Kind.
function Test-CopilotEligibility([int]$ProcId, [int]$Phase) {
  $script:Verdict = 'keep'; $script:Why = 'not found'; $script:Kind = 'none'
  if ($Phase -gt 1) { Build-Index; $tbl = Get-ProcTable $Phase } else { $tbl = $script:Table }
  $p = $tbl[$ProcId]
  if (-not $p) { $script:Why = 'process gone'; return }
  $script:Kind = Get-CopilotKind $p
  switch ($script:Kind) {
    'server'  { $script:Why = 'server/ACP host'; return }
    'related' { $script:Why = 'copilot-related, unrecognised shape'; return }
    'client'  { }
    default   { $script:Why = 'no longer a copilot client'; return }
  }
  if ($script:SelfTree.Contains($ProcId)) { $script:Why = 'current session tree'; return }
  if ($tbl.ContainsKey([int]$p.ParentProcessId)) { $script:Why = 'live parent'; return }
  if (-not $script:StoreOk) { $script:Why = 'no valid lifecycle record (report-only)'; return }
  if ($script:BadPids.Contains($ProcId)) { $script:Why = 'invalid or contradictory lifecycle record (report-only)'; return }
  $recs = @(); if ($script:RecByPid.ContainsKey($ProcId)) { $recs = @($script:RecByPid[$ProcId]) }
  if ($recs.Count -eq 0) { $script:Why = 'no valid lifecycle record (report-only)'; return }
  if ($recs.Count -gt 1) { $script:Why = 'invalid or contradictory lifecycle record (report-only)'; return }
  $r = $recs[0]
  if (-not $p.Identity -or $p.Identity -cne $r.start) { $script:Why = 'start identity mismatch (PID reuse?)'; return }
  $owner = Get-ProcOwner $p
  if (-not $owner -or $owner -ine $Me -or $r.owner -ine $Me) { $script:Why = 'owner mismatch'; return }
  if ($r.intent -ne 'interactive') { $script:Why = "record intent=$($r.intent)"; return }
  $age = $Now - [int64]$r.updated
  if ($r.state -eq 'ended') {
    if ($age -ge $EndGraceSec) { $script:Verdict = 'reap'; $script:Why = 'session ended, process outlived it' }
    else { $script:Why = 'session ended moments ago (grace)' }
  } else {
    if ($age -ge $AbandonSec) { $script:Verdict = 'reap'; $script:Why = 'no heartbeat past abandonment window' }
    else { $script:Why = 'recent heartbeat (session may be live)' }
  }
}

function Stop-Target([int]$ProcId) {
  if ($MockKill) { Add-Content -LiteralPath $MockKill -Value "STOP $ProcId"; return }
  Stop-Process -Id $ProcId -Force
}

$alive = Get-ProcTable 1
$script:Table = $alive

# Protect the current session's assistant ancestor (claude OR a Copilot client) + its whole descendant tree
$protect = New-Object System.Collections.Generic.HashSet[int]
[void]$protect.Add($SelfPid)
$p = $alive[$SelfPid]
while ($p) {
  [void]$protect.Add([int]$p.ProcessId)
  if ($p.Name -eq 'claude.exe') { break }
  if ((Get-CopilotKind $p) -in @('client', 'server', 'related')) { break }
  $par = [int]$p.ParentProcessId
  if (-not $alive.ContainsKey($par)) { break }
  $p = $alive[$par]
}
function Add-Descendants($set) {
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($k in @($alive.Keys)) {
      $par = [int]$alive[$k].ParentProcessId
      if ($set.Contains($par) -and -not $set.Contains($k)) { [void]$set.Add($k); $changed = $true }
    }
  }
}
Add-Descendants $protect
$script:SelfTree = $protect

# Copilot lane: classify every process once, decide each client.
Test-Store
Build-Index
$cpKind = @{}
$cpReap = New-Object System.Collections.Generic.List[object]
$cpKeep = New-Object System.Collections.Generic.List[object]
$cpLive = 0; $cpKept = 0; $cpServer = 0; $cpRelated = 0; $cpReaped = 0
$cpKeptSet = New-Object System.Collections.Generic.HashSet[int]
foreach ($proc in @($alive.Values | Sort-Object ProcessId)) {
  $kind = Get-CopilotKind $proc
  $cpKind[[int]$proc.ProcessId] = $kind
  if ($kind -eq 'none') { continue }
  $id = [int]$proc.ProcessId
  if ($kind -eq 'related') { $cpRelated++; [void]$cpKeptSet.Add($id); $cpKeep.Add(@($id, 'related', 'copilot-related, unrecognised shape')); continue }
  if ($kind -eq 'server')  { $cpServer++;  [void]$cpKeptSet.Add($id); $cpKeep.Add(@($id, 'server', 'server/ACP host')); continue }
  Test-CopilotEligibility $id 1
  if ($script:Verdict -eq 'reap') { $cpReap.Add(@($id, $script:Why)) }
  else {
    [void]$cpKeptSet.Add($id)
    if ($script:Why -in @('live parent', 'current session tree')) { $cpLive++ } else { $cpKept++ }
    $cpKeep.Add(@($id, 'client', $script:Why))
  }
}
# Protect the whole tree under every kept Copilot process (live sessions, ambiguous orphans, servers).
foreach ($id in $cpKeptSet) { [void]$protect.Add($id) }
Add-Descendants $protect

$reapNames = @('claude.exe', 'node.exe', 'bash.exe')
function Test-GenericTarget($proc) {
  if ($proc.Name -notin $reapNames) { return $false }
  if ($cpKind[[int]$proc.ProcessId] -ne 'none') { return $false }   # the Copilot lane owns Copilot shapes
  return $true
}

# Root orphans: target-named procs whose parent PID is gone
$kill = New-Object System.Collections.Generic.HashSet[int]
foreach ($proc in $alive.Values) {
  if (-not (Test-GenericTarget $proc)) { continue }
  if ($protect.Contains([int]$proc.ProcessId)) { continue }
  if (-not $alive.ContainsKey([int]$proc.ParentProcessId)) { [void]$kill.Add([int]$proc.ProcessId) }
}
# Expand to dead trees: any target proc whose parent is already in the kill set
$changed = $true
while ($changed) {
  $changed = $false
  foreach ($proc in $alive.Values) {
    if (-not (Test-GenericTarget $proc)) { continue }
    $id = [int]$proc.ProcessId
    if ($protect.Contains($id) -or $kill.Contains($id)) { continue }
    if ($kill.Contains([int]$proc.ParentProcessId)) { [void]$kill.Add($id); $changed = $true }
  }
}

if ($FixtureMode) {
  Write-Output "=== reap-orphans  (fixture) ==="
} else {
  $os = Get-CimInstance Win32_OperatingSystem
  $bFree = [math]::Round($os.FreePhysicalMemory/1MB,2)
  $bPage = (Get-CimInstance Win32_PageFileUsage).CurrentUsage
  $usedPct = [math]::Round(($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/$os.TotalVisibleMemorySize*100,0)
  Write-Output "=== reap-orphans  (RAM used ${usedPct}%, ${bFree} GB free, pagefile ${bPage} MB) ==="
}
Write-Output "Protected session tree: $($protect.Count) procs (current session is safe)"
if (-not $script:StoreOk -and ($cpLive + $cpKept + $cpServer + $cpRelated + $cpReap.Count) -gt 0) {
  Write-Output "Copilot lifecycle records unusable: $($script:StoreWhy)"
  Write-Output "Copilot cleanup coverage: incomplete; unknown sessions stay report-only."
  Write-Output "Preview optional tracking: node `"$PSScriptRoot\copilot-hooks.mjs`" --print (installs nothing)."
}

if ($kill.Count -eq 0 -and $cpReap.Count -eq 0) {
  Write-Output "No eligible orphaned debris found (uncertain processes are kept)."
}
if ($kill.Count -gt 0) {
  $list = $kill | ForEach-Object { $alive[$_] } | Sort-Object Name, ProcessId
  Write-Output "Orphans to reap: $($kill.Count)  ($(( $list | Group-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '))"
  if (-not $FixtureMode) {
    $freedEst = [math]::Round((($list | ForEach-Object { (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue).WorkingSet64 } | Measure-Object -Sum).Sum)/1GB,2)
  }
  foreach ($proc in $list) {
    $tag = if ($DryRun) { 'WOULD KILL' } else { 'KILL' }
    Write-Output ("  {0,-10} {1,-11} PID {2,-7} parent {3} (dead)" -f $tag,$proc.Name,$proc.ProcessId,$proc.ParentProcessId)
    if (-not $DryRun) { Stop-Target $proc.ProcessId }
  }
  if (-not $DryRun -and -not $FixtureMode) {
    Start-Sleep -Seconds 2
    $os2 = Get-CimInstance Win32_OperatingSystem
    $aFree = [math]::Round($os2.FreePhysicalMemory/1MB,2)
    Write-Output "Reaped $($kill.Count). RAM freed ~$([math]::Round($aFree-$bFree,2)) GB (now $aFree GB free)."
  } elseif (-not $DryRun) {
    Write-Output "Reaped $($kill.Count)."
  } elseif (-not $FixtureMode) {
    Write-Output "(dry run) Estimated reclaimable: ~${freedEst} GB"
  }
}

# Copilot lane: command lines are never printed; each stop is preceded by a fresh re-validation.
foreach ($c in $cpReap) {
  $id = [int]$c[0]; $why = $c[1]; $par = $alive[$id].ParentProcessId
  if ($DryRun) { Write-Output ("  WOULD KILL copilot-client PID {0,-7} parent {1} (dead) [{2}]" -f $id, $par, $why); continue }
  Test-CopilotEligibility $id 2
  if ($script:Verdict -ne 'reap') {
    Write-Output ("  SKIP copilot-client PID {0}: re-validation failed before stop [{1}]" -f $id, $script:Why)
    $cpKept++; continue
  }
  Write-Output ("  KILL copilot-client PID {0,-7} parent {1} (dead) [{2}]" -f $id, $par, $why)
  Stop-Target $id
  $cpReaped++
}

# Accurate counts, no command lines.
if (($cpLive + $cpKept + $cpServer + $cpRelated + $cpReap.Count) -gt 0) {
  foreach ($k in $cpKeep) { Write-Output ("  KEPT PID {0} copilot-{1}: {2}" -f $k[0], $k[1], $k[2]) }
  $tail = if ($DryRun) { '' } else { " reaped=$cpReaped" }
  Write-Output "Copilot: live=$cpLive kept-uncertain=$cpKept server/acp=$cpServer related=$cpRelated reapable=$($cpReap.Count)$tail"
}

# Attribute each process once, to its outermost recognised Copilot ancestor.
# Working sets include shared pages: these totals are not reclaimable-RAM estimates.
$cpGroups = @{}
foreach ($proc in $alive.Values) {
  $cursor = [int]$proc.ProcessId; $root = 0
  $seen = New-Object System.Collections.Generic.HashSet[int]
  while ($alive.ContainsKey($cursor) -and $seen.Add($cursor)) {
    if ($cpKind[$cursor] -in @('client', 'server')) { $root = $cursor }
    $cursor = [int]$alive[$cursor].ParentProcessId
  }
  if ($root -eq 0) { continue }
  if (-not $cpGroups.ContainsKey($root)) { $cpGroups[$root] = @() }
  $cpGroups[$root] += ,$proc
}
if ($cpGroups.Count -gt 0) {
  Write-Output "--- Copilot process groups (snapshot working sets, shared pages included; NOT kill targets) ---"
  foreach ($root in @($cpGroups.Keys | Sort-Object)) {
    $members = @($cpGroups[$root])
    $nodes = @($members | Where-Object { $_.Name -eq 'node.exe' -and $cpKind[$_.ProcessId] -eq 'none' }).Count
    $mb = [math]::Round(($members | Measure-Object -Property WorkingSetSize -Sum).Sum / 1MB)
    Write-Output ("  ROOT PID {0,-7} processes={1} node/MCP={2} working-set={3} MB" -f $root, $members.Count, $nodes, $mb)
  }
}

if (-not $FixtureMode) {
  Write-Output ""
  Write-Output "--- Live processes worth a look (NOT killed) ---"
  $nowKept = Get-Process | Where-Object {
    $_.WorkingSet64/1MB -ge $HogMB -and -not $kill.Contains([int]$_.Id)
  } | Sort-Object WorkingSet64 -Descending | Select-Object -First 10
  $nowKept | ForEach-Object {
    $ageH = if ($_.StartTime) { [math]::Round(((Get-Date)-$_.StartTime).TotalHours,1) } else { '?' }
    "{0,-12} PID {1,-7} {2,6} MB  age {3}h  cpu {4}s" -f $_.Name,$_.Id,[math]::Round($_.WorkingSet64/1MB,0),$ageH,[math]::Round($_.CPU,0)
  }
}
Write-Output ""
$cpClients = @($cpKind.Values | Where-Object { $_ -eq 'client' -or $_ -eq 'server' }).Count
if ($FixtureMode) {
  $claudeN = @($alive.Values | Where-Object { $_.Name -eq 'claude.exe' }).Count
  $nodeN   = @($alive.Values | Where-Object { $_.Name -eq 'node.exe' -and $cpKind[[int]$_.ProcessId] -eq 'none' }).Count
} else {
  $claudeN = (Get-Process claude -ErrorAction SilentlyContinue).Count
  # node.exe hosting the Copilot CLI is a Copilot client, counted there and not as an MCP/node proc
  $nodeN   = @(Get-Process node -ErrorAction SilentlyContinue | Where-Object { -not $cpKind.ContainsKey([int]$_.Id) -or $cpKind[[int]$_.Id] -eq 'none' }).Count
}
Write-Output "Live claude sessions: $claudeN   Copilot clients: $cpClients   node/MCP procs: $nodeN   (close unused sessions to cut both)"
