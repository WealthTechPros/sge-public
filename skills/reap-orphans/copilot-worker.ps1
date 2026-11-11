# Opt-in Windows supervision for one disposable native worker, never an existing PID.
# Ownership stays in memory as open process handles; no hook or PID registry is installed.
param(
  [switch]$Disposable,
  [int]$OwnerProcessId = 0,
  [string]$FilePath = '',
  [AllowEmptyString()][string[]]$ArgumentList = @(),
  [string]$WorkingDirectory = '',
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$owner = $null
$child = $null
$childHandleHeld = $false
$result = 1
$stage = 'validation'
$stopReason = 'supervisor stopping'

function Write-Diagnostic([string]$message) {
  [Console]::Error.WriteLine("sge disposable worker: $message")
}

function ConvertTo-NativeArgument([AllowEmptyString()][string]$value) {
  if ($value.IndexOf([char]0) -ge 0) { throw 'Invalid native argument' }
  $escaped = [regex]::Replace($value, '(\\*)"', '$1$1\"')
  $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
  return '"' + $escaped + '"'
}

try {
  if (-not $Disposable) {
    Write-Diagnostic 'explicit -Disposable consent is required; nothing started'
    exit 1
  }
  if ($env:OS -ne 'Windows_NT') { throw 'Windows required' }
  if (-not [IO.Path]::IsPathRooted($FilePath)) { throw 'Absolute executable required' }
  $executable = Get-Item -LiteralPath $FilePath -Force
  if ($executable.PSIsContainer -or $executable.Extension -ine '.exe' -or
      ($executable.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Native executable required' }
  if (-not $WorkingDirectory) { $WorkingDirectory = (Get-Location).ProviderPath }
  $directory = Get-Item -LiteralPath $WorkingDirectory
  if (-not $directory.PSIsContainer) { throw 'Working directory required' }
  $nativeArguments = @($ArgumentList | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '

  $stage = 'owner verification'
  $discoveredOwnerStart = ''
  if ($OwnerProcessId -eq 0) {
    . (Join-Path $PSScriptRoot 'copilot-signature.ps1')
    $table = @{}
    foreach ($row in @(Get-CimInstance Win32_Process)) { $table[[int]$row.ProcessId] = $row }
    $cursor = [int]$PID
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    for ($depth = 0; $depth -lt 64 -and $table.ContainsKey($cursor) -and $seen.Add($cursor); $depth++) {
      $row = $table[$cursor]
      $kind = Get-CopilotKind $row
      if ($kind -eq 'client') {
        $OwnerProcessId = $cursor
        $discoveredOwnerStart = $row.CreationDate.ToUniversalTime().ToString('yyyyMMddTHHmmss.ffffffZ')
        break
      }
      if ($kind -in @('server', 'related')) { throw 'Interactive owner required' }
      $cursor = [int]$row.ParentProcessId
    }
  }
  if ($OwnerProcessId -le 0 -or $OwnerProcessId -eq $PID) { throw 'Owner required' }
  $owner = [Diagnostics.Process]::GetProcessById($OwnerProcessId)
  # Retain this exact process object across exit, rather than looking up its PID again.
  [void]$owner.Handle
  # CIM truncates Windows FILETIME to microseconds.
  $ownerStart = $owner.StartTime.ToUniversalTime().ToString('yyyyMMddTHHmmss.ffffffZ')
  $ownerRow = Get-CimInstance Win32_Process -Filter "ProcessId=$OwnerProcessId"
  if (-not $ownerRow -or $ownerRow.CreationDate.ToUniversalTime().ToString('yyyyMMddTHHmmss.ffffffZ') -cne $ownerStart) { throw 'Owner identity changed' }
  if ($discoveredOwnerStart -and
      ($discoveredOwnerStart -cne $ownerStart -or (Get-CopilotKind $ownerRow) -ne 'client')) { throw 'Discovered owner changed' }
  $ownerSid = Invoke-CimMethod -InputObject $ownerRow -MethodName GetOwnerSid
  $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  if ($ownerSid.ReturnValue -ne 0 -or $ownerSid.Sid -ne $currentSid -or $owner.HasExited) { throw 'Same-user live owner required' }
  if ($DryRun) {
    Write-Diagnostic "would supervise one new disposable worker for owner PID=$OwnerProcessId; nothing started"
    $result = 0
  } else {
    $stage = 'worker launch'
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $executable.FullName
    $info.Arguments = $nativeArguments
    $info.WorkingDirectory = $directory.FullName
    $info.UseShellExecute = $false
    $child = [Diagnostics.Process]::Start($info)
    [void]$child.Handle
    $childHandleHeld = $true
    $stage = 'supervision'
    Write-Diagnostic "supervising owner PID=$OwnerProcessId worker PID=$($child.Id)"
    while (-not $child.WaitForExit(250)) {
      if ($owner.HasExited) { $stopReason = 'owner exited'; break }
    }
    $result = if ($child.HasExited) { $child.ExitCode } else { 0 }
  }
} catch {
  Write-Diagnostic "$stage failed; no existing process was selected for termination"
  $result = 1
} finally {
  if ($child) {
    try {
      if (-not $child.HasExited) {
        if (-not $childHandleHeld) { throw 'No retained child handle' }
        $child.Refresh()
        $privateBytes = $child.PrivateMemorySize64
        if (-not $child.HasExited) {
          Stop-Process -Id $child.Id -Force -ErrorAction Stop
          if (-not $child.WaitForExit(5000)) { throw 'Worker did not exit' }
          Write-Diagnostic "$stopReason; stopped worker PID=$($child.Id); private-bytes-before-stop=$privateBytes (not a system RAM savings measurement)"
        }
      }
    } catch {
      Write-Diagnostic 'owned-worker cleanup could not be confirmed; inspect the supervised worker'
      $result = 1
    } finally { $child.Dispose() }
  }
  if ($owner) { $owner.Dispose() }
}
exit $result
