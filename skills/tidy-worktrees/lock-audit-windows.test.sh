#!/usr/bin/env bash
# Native NTFS coverage for SPEC-139's target-preserving Windows tidy guard.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/lock-audit.sh"
set +e
if ! _la_is_windows; then
  echo "SKIP - native Windows junction and long-path proof requires Windows"
  exit 0
fi
PS="$(_la_powershell)" || exit 1
case "$(basename "$PS")" in
  pwsh|pwsh.exe) ;;
  *)
    # Windows PowerShell 5.1 (the _la_powershell fallback when pwsh is absent)
    # does not support paths beyond MAX_PATH without a \\?\ prefix, so the
    # long-path fixture this test builds below throws PathTooLongException —
    # an environment gap, not a defect in the junction guard. Require pwsh for
    # this coverage and skip cleanly rather than report a false failure.
    echo "SKIP - long-path junction coverage requires PowerShell 7 (pwsh); only Windows PowerShell ($PS) is available on this host"
    exit 0
    ;;
esac
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sge-lock-probe.XXXXXXXX")" || exit 1
export LA_TEST_BASE="$(cygpath -w "$TMP")"
cleanup() {
  "$PS" -NoProfile -NonInteractive -Command '
    $ErrorActionPreference = "Stop"
    $root = Get-Item -LiteralPath $env:LA_TEST_BASE -Force
    if ($root.Name -notlike "sge-lock-probe.*" -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "unexpected fixture root"
    }
    $queue = [System.Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($root.FullName)
    while ($queue.Count) {
      foreach ($child in Get-ChildItem -LiteralPath $queue.Dequeue() -Directory -Force) {
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
          [IO.Directory]::Delete($child.FullName, $false)
        } else { $queue.Enqueue($child.FullName) }
      }
    }
    [IO.Directory]::Delete($root.FullName, $true)
  ' >/dev/null
}
trap cleanup EXIT
DATA="$("$PS" -NoProfile -NonInteractive -Command '
  $ErrorActionPreference = "Stop"
  $base = (Get-Item -LiteralPath $env:LA_TEST_BASE -Force).FullName
  $root = Join-Path $base "repo [one]"
  $target = Join-Path $base "outside"
  $nested = Join-Path $base "nested target"
  foreach ($p in @($root, $target, $nested)) { [void][IO.Directory]::CreateDirectory($p) }
  [IO.File]::WriteAllText((Join-Path $target "marker.txt"), "target preserved")
  [IO.File]::WriteAllText((Join-Path $nested "marker.txt"), "nested preserved")
  $inner = Join-Path $target "nested junction"
  $child = Join-Path $root "external junction"
  $rootLink = Join-Path $base "root junction"
  foreach ($pair in @(@($inner, $nested), @($child, $target), @($rootLink, $root))) {
    [void](New-Item -ItemType Junction -Path $pair[0] -Target $pair[1])
  }
  $long = $root
  while ($long.Length -le 280) { $long = Join-Path $long ("segment-" + ("x" * 40)) }
  [void][IO.Directory]::CreateDirectory($long)
  $longLink = Join-Path $long "long junction"
  [void](New-Item -ItemType Junction -Path $longLink -Target $target)
  @{ root = $root; child = $child; longLink = $longLink; rootLink = $rootLink; longLength = $longLink.Length } | ConvertTo-Json -Compress
')" || exit 1
field() { printf '%s' "$DATA" | jq -r ".$1" | tr -d '\r'; }
ROOT="$(field root)"; CHILD="$(field child)"; LONG="$(field longLink)"; ROOT_LINK="$(field rootLink)"
fail=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1: wanted [$3], got [$2]"; fail=1; fi
}
OUT="$(_la_junctions "$ROOT")"; RC=$?
check "native probe succeeds beyond MAX_PATH" "$RC" 0
check "fixture link exceeds260characters" "$([ "$(field longLength)" -gt 260 ] && echo yes)" yes
check "only owned child links, not target's nested link, are discovered" \
  "$(printf '%s\n' "$OUT" | tr -d '\r' | LC_ALL=C sort)" "$(printf '%s\n' "$CHILD" "$LONG" | LC_ALL=C sort)"
_la_junctions "$ROOT_LINK" >/dev/null; RC=$?
check "root junction is rejected" "$([ "$RC" -ne 0 ] && echo rejected)" rejected
_la_junctions "$ROOT\\missing" >/dev/null; RC=$?
check "missing root fails closed" "$([ "$RC" -ne 0 ] && echo rejected)" rejected
_la_junctions "$LA_TEST_BASE\\outside\\marker.txt" >/dev/null; RC=$?
check "file root fails closed" "$([ "$RC" -ne 0 ] && echo rejected)" rejected
_la_unlink_junction "$LONG"; check "long-path link-only unlink succeeds" "$?" 0
_la_unlink_junction "$CHILD"; check "child link-only unlink succeeds" "$?" 0
OUT="$(_la_junctions "$ROOT")"; RC=$?
check "post-unlink probe succeeds with no links" "$RC:$OUT" "0:"
"$PS" -NoProfile -NonInteractive -Command '
  $ErrorActionPreference = "Stop"
  $base = $env:LA_TEST_BASE
  if ([IO.File]::ReadAllText((Join-Path $base "outside\marker.txt")) -ne "target preserved") { exit 1 }
  if ([IO.File]::ReadAllText((Join-Path $base "nested target\marker.txt")) -ne "nested preserved") { exit 1 }
  if (-not ((Get-Item -LiteralPath (Join-Path $base "outside\nested junction")).Attributes -band [IO.FileAttributes]::ReparsePoint)) { exit 1 }
  exit 0
'
check "both target contents and target's nested link remain intact" "$?" 0
exit "$fail"
