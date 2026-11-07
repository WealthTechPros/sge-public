# copilot-session-record.ps1 — Windows twin of copilot-session-record.sh (issue #3367).
# Writes the minimal per-user lifecycle record that lets reap-orphans.ps1 prove a
# Copilot CLI process is an abandoned orphan. BEST-EFFORT and NON-DESTRUCTIVE: it
# writes one small file in the caller's own record store, never stops or inspects
# anything else, and always exits 0 so it can never break a session.
#
#   pwsh -File copilot-session-record.ps1 -Event start|beat|end -Session <session-id>
#
# Walks up from this process to the nearest recognised Copilot client
# (copilot-signature.ps1) and binds that exact PID + start identity (creation time,
# UTC yyyyMMddTHHmmssZ) + owner to the session id. Intent: interactive (the client
# has a live parent), detached (already orphaned when recorded, or
# SGE_COPILOT_INTENT=detached) or server (ACP/server host) — the reaper never
# touches the last two. No Copilot ancestor -> nothing is written. Records hold no
# prompt text, command line, path or credential. Format and store location are in
# ../reap-orphans/SKILL.md and match copilot-session-record.sh.
#
# Test seams: SGE_REAP_PROC_FIXTURE (JSON table), SGE_COPILOT_REC_FROM (start pid),
# SGE_REAP_NOW, SGE_REAP_USER, SGE_COPILOT_SESSION_DIR.
param(
  [string]$Event = '',
  [string]$Session = ''
)
$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'copilot-signature.ps1')

function Write-Record {
  if ($Event -notin @('start', 'beat', 'end')) { return }
  if ($Session -notmatch '^[A-Za-z0-9._-]{1,128}$') { return }
  $fixture = [bool]$env:SGE_REAP_PROC_FIXTURE
  $now = 0L
  if (-not [int64]::TryParse([string]$env:SGE_REAP_NOW, [ref]$now)) { $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
  $me = if ($env:SGE_REAP_USER) { $env:SGE_REAP_USER } elseif ($env:USERDOMAIN) { "$($env:USERDOMAIN)\$($env:USERNAME)" } else { [Environment]::UserName }
  $dir = if ($env:SGE_COPILOT_SESSION_DIR) { $env:SGE_COPILOT_SESSION_DIR }
         elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'sge\copilot-sessions' }
         else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local/state/sge/copilot-sessions' }

  $t = @{}
  $rows = if ($fixture) { @(Get-Content -Raw -LiteralPath $env:SGE_REAP_PROC_FIXTURE | ConvertFrom-Json) } else { @(Get-CimInstance Win32_Process | ForEach-Object { $_ }) }
  foreach ($r in $rows) { $t[[int]$r.ProcessId] = $r }

  $p = if ($env:SGE_COPILOT_REC_FROM) { [int]$env:SGE_COPILOT_REC_FROM } else { [int]$PID }
  $hit = $null; $kind = 'none'
  for ($d = 0; $d -lt 32 -and $t.ContainsKey($p); $d++) {
    $row = $t[$p]
    $k = Get-CopilotKind ([pscustomobject]@{ Name = [string]$row.Name; CommandLine = [string]$row.CommandLine })
    if ($k -in @('client', 'server')) { $hit = $row; $kind = $k; break }
    $p = [int]$row.ParentProcessId
  }
  if (-not $hit) { return }

  if ($fixture) { $start = [string]$hit.Identity; $owner = [string]$hit.Owner }
  else {
    if (-not $hit.CreationDate) { return }
    $start = $hit.CreationDate.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $o = Invoke-CimMethod -InputObject $hit -MethodName GetOwner
    $owner = if ($o -and $o.User) { "$($o.Domain)\$($o.User)" } else { '' }
  }
  if (-not $owner -or $owner -ine $me) { return }                       # only ever record our own process
  if ($start -notmatch '^[A-Za-z0-9 :._+-]{1,64}$' -or $me -notmatch '^[A-Za-z0-9._@\\-]{1,64}$') { return }

  $parentAlive = $t.ContainsKey([int]$hit.ParentProcessId)
  $intent = if ($kind -eq 'server') { 'server' }
            elseif ($env:SGE_COPILOT_INTENT -eq 'detached' -or -not $parentAlive) { 'detached' }
            else { 'interactive' }
  $state = if ($Event -eq 'end') { 'ended' } else { 'active' }

  $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($dir)   # absolute: .NET file APIs use the process cwd, not the PS location
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $item = Get-Item -LiteralPath $dir -Force
  if (-not $item -or -not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
  $rec = Join-Path $dir "$Session.rec"
  # Another session's record for this very pid means the pid has moved on to a newer session
  # (or this is an older session's late event). Ordering rule:
  #   start      the newer session wins: drop the previous generation's record so the reaper
  #              never sees two claims on one pid (it treats that as contradictory).
  #   beat / end an OLDER session's late event must never delete or overwrite the newer
  #              session's record, so it writes nothing at all.
  $others = @(Get-ChildItem -LiteralPath $dir -Filter '*.rec' -File | Where-Object {
      $_.Name -ine "$Session.rec" -and (@(Get-Content -LiteralPath $_.FullName -TotalCount 17) -contains "pid=$p") })
  if ($others.Count -gt 0) {
    if ($Event -ne 'start') { return }
    foreach ($f in $others) { Remove-Item -LiteralPath $f.FullName -Force }
  }
  $body = "schema=1`nsession=$Session`npid=$p`nstart=$start`nowner=$me`nintent=$intent`nstate=$state`nupdated=$now`n"
  $tmp = Join-Path $dir ".tmp.$([guid]::NewGuid().ToString('N'))"
  [IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $rec -Force
  Get-ChildItem -LiteralPath $dir -Filter '*.rec' -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force
}
Write-Record
exit 0
