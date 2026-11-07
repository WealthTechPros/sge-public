# Shared GitHub Copilot CLI process signature (issue #3367) — dot-sourced by
# reap-orphans.ps1 and copilot-session-record.ps1 so the reaper and the record
# writer can never disagree about what a Copilot client is. The POSIX twin is
# copilot-signature.sh; keep the two in step (the behavioural tests pin both).
#
# Get-CopilotKind <proc with Name + CommandLine> -> none | client | server | related
# Only the EXECUTABLE and script/package path are matched — never prompt text or
# other arguments (except the server flags below).
#   client  copilot.exe, or node-hosted @github/copilot
#   server  a recognised client launched as an ACP/server/headless host
#   related anything else whose executable or package looks Copilot-ish (VS Code
#           extension, language server, helper): kept, never reaped
function ConvertTo-Norm([string]$s) { return (($s -replace '\\', '/').ToLowerInvariant()) }
function Get-BaseName([string]$s) { $x = ConvertTo-Norm $s; $x = $x -replace '.*/', ''; return ($x -replace '\.exe$', '') }
function Get-CopilotKind($p) {
  $cl = [string]$p.CommandLine
  $toks = @([regex]::Matches($cl, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') })
  $first = if ($toks.Count -gt 0) { $toks[0] } else { [string]$p.Name }
  $base = Get-BaseName $first
  if (-not $base) { $base = Get-BaseName ([string]$p.Name) }
  $kind = 'none'
  if ($base -eq 'copilot') { $kind = 'client' }
  elseif ($base -in @('node', 'nodejs', 'bun', 'deno')) {
    $script = ''
    for ($i = 1; $i -lt $toks.Count; $i++) {
      if ((ConvertTo-Norm $toks[$i]) -match '(^|/)@github/copilot(/|$)') { $kind = 'client' }
      if ($script -eq '' -and -not $toks[$i].StartsWith('-')) { $script = $toks[$i] }
    }
    if ($kind -eq 'none') {
      $s = ConvertTo-Norm $script
      if ($s -match '(^|/)@github/copilot|(^|/)github\.copilot') { $kind = 'related' }
      elseif ((Get-BaseName $script) -match 'copilot') { $kind = 'related' }
    }
  }
  elseif ($base -match 'copilot') { $kind = 'related' }
  elseif ((ConvertTo-Norm $first) -match '(^|/)github\.copilot|(^|/)@github/copilot') { $kind = 'related' }
  if ($kind -eq 'client') {
    $low = ' ' + (ConvertTo-Norm $cl) + ' '
    if ($low -match ' --(acp|server|headless|ui-server|stdio|port|daemon)([= ]|$)') { $kind = 'server' }
  }
  return $kind
}
