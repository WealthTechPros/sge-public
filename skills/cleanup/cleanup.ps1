# /sge:cleanup — Dev-Box Reset (Windows)
#
# Bundled script for the cleanup skill (issue #822). Kills Playwright /
# headless Chromium / stale-node test runners (CommandLine/ExecutablePath
# filtered so live user browsers and claude-in-chrome MCP sessions are never
# touched), optionally shuts down WSL, and reports RAM freed. Chain
# /sge:reap-orphans afterwards. See ../SKILL.md for the full contract.
#
# Usage: pwsh -File cleanup.ps1 [-DryRun] [-NoWSL]
param(
  [switch]$DryRun,
  [switch]$NoWSL
)

$ErrorActionPreference = 'SilentlyContinue'

function Kill-HeadlessBrowsers {
  param([string[]]$Names)
  # Win32_Process.Name includes the .exe suffix (unlike Get-Process.Name, which
  # strips it -- comparing the latter against "chrome.exe" etc. never matches,
  # which is why this used to be inert dead code). A name match alone is not
  # enough to kill, though: only treat a process as a headless/automation
  # target -- and therefore killable -- when it was launched from the
  # Playwright browser cache (ExecutablePath) or its command line shows
  # --headless/playwright. --remote-debugging-port is deliberately NOT used as
  # a signal on its own: a live user browser window with DevTools open, or a
  # claude-in-chrome MCP session, can carry that flag too and must stay
  # untouchable by construction.
  $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $Names -contains $_.Name -and (
      ($_.ExecutablePath -match 'ms-playwright') -or
      ($_.CommandLine -match '--headless|playwright')
    )
  }
  if (-not $procs) { Write-Host "  Playwright/Chromium (headless) -- none running"; return 0 }
  $count = 0
  foreach ($proc in $procs) {
    $live = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
    $mb = if ($live) { [math]::Round($live.WorkingSet64/1MB,0) } else { 0 }
    if ($DryRun) {
      Write-Host ("  WOULD KILL  {0,-22} PID {1,-7} {2,6} MB" -f $proc.Name,$proc.ProcessId,$mb)
    } else {
      Write-Host ("  KILL        {0,-22} PID {1,-7} {2,6} MB" -f $proc.Name,$proc.ProcessId,$mb)
      Stop-Process -Id $proc.ProcessId -Force
    }
    $count++
  }
  # Write-Host above goes straight to the console, not the pipeline, so the
  # only thing a caller doing "$n = Kill-HeadlessBrowsers ..." captures is
  # this integer -- unlike the old Write-Output-based version, which fed its
  # preview/kill lines into the assignment and broke both DryRun output and
  # the count.
  return $count
}

$os = Get-CimInstance Win32_OperatingSystem
$bFree = [math]::Round($os.FreePhysicalMemory/1MB,2)
$usedPct = [math]::Round(($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/$os.TotalVisibleMemorySize*100,0)
Write-Output "=== cleanup  (RAM used ${usedPct}%, ${bFree} GB free) ==="
if ($DryRun) { Write-Output "(dry run -- nothing will be killed)" }

# 1. Kill Playwright / headless Chromium test runners -- CommandLine/ExecutablePath
#    filtered so live user browsers and claude-in-chrome MCP sessions are never
#    touched (see Kill-HeadlessBrowsers above for the exact matching rule).
Write-Output ""
Write-Output "--- Step 1: Playwright / headless Chromium ---"
$playwrightNames = @('msedge.exe','chrome.exe','chromium.exe','playwright.exe')
$n1 = Kill-HeadlessBrowsers -Names $playwrightNames

# Also kill any node processes running playwright by command line
$pwNodes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -eq 'node.exe' -and $_.CommandLine -match 'playwright' }
foreach ($proc in $pwNodes) {
  $mb = [math]::Round((Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue).WorkingSet64/1MB,0)
  if ($DryRun) {
    Write-Host ("  WOULD KILL  node(playwright)       PID {0,-7} {1,6} MB" -f $proc.ProcessId,$mb)
  } else {
    Write-Host ("  KILL        node(playwright)       PID {0,-7} {1,6} MB" -f $proc.ProcessId,$mb)
    Stop-Process -Id $proc.ProcessId -Force
  }
  $n1++
}
Write-Output "  Playwright/Chromium killed: $n1"

# 2. WSL shutdown
Write-Output ""
Write-Output "--- Step 2: WSL ---"
if ($NoWSL) {
  Write-Output "  Skipped (-NoWSL)"
} else {
  if ($DryRun) {
    Write-Output "  WOULD RUN: wsl --shutdown"
  } else {
    wsl --shutdown 2>&1 | Out-Null
    Write-Output "  WSL shutdown complete"
  }
}

# 3. Summary
if (-not $DryRun) {
  Start-Sleep -Seconds 2
  $os2 = Get-CimInstance Win32_OperatingSystem
  $aFree = [math]::Round($os2.FreePhysicalMemory/1MB,2)
  Write-Output ""
  Write-Output "=== cleanup done. RAM freed ~$([math]::Round($aFree-$bFree,2)) GB (now $aFree GB free) ==="
  Write-Output "Running /sge:reap-orphans next to catch remaining claude/node/bash orphans..."
} else {
  Write-Output ""
  Write-Output "=== cleanup dry-run complete ==="
}
