: << 'CMDBLOCK'
@echo off
rem SGE hook launcher (sge#3264) - Windows (cmd.exe) half of a cmd/sh polyglot.
rem Usage: run-hook.cmd <absolute path to a hooks/*.sh script>
rem Finds a REAL bash itself instead of trusting `bash` on PATH: on Windows the
rem first `bash` is often C:\Windows\System32\bash.exe (the WSL launcher) or the
rem WindowsApps stub, under which every hook exits 1. stdin, stdout and the hook's
rem exit code pass through unchanged. If no bash can run, it fails CLOSED (exit 2)
rem with a message naming the script, what was tried and the remedy.
rem No labels or goto on purpose: cmd mis-parses them in LF-only files.
setlocal
set "SGE_HOOK=%~1"
set "SGE_BASH="
set "SGE_TRIED="
set "SGE_ERR="
if not defined SGE_HOOK set "SGE_ERR=no hook script was given"
if not defined SGE_ERR if /i not "%SGE_HOOK:~-3%"==".sh" set "SGE_ERR=not a .sh hook script"
if not defined SGE_ERR if not exist "%SGE_HOOK%" set "SGE_ERR=hook script not found"
if defined SGE_ERR (
  >&2 echo SGE hook launcher: cannot run "%~nx1": %SGE_ERR%. Failing closed.
  exit /b 2
)
rem 1) Git for Windows in its well-known locations.
for %%P in ("%ProgramFiles%\Git\bin\bash.exe" "%ProgramW6432%\Git\bin\bash.exe" "%ProgramFiles(x86)%\Git\bin\bash.exe" "%LocalAppData%\Programs\Git\bin\bash.exe") do if not defined SGE_BASH if exist "%%~P" ("%%~P" -c "exit 0" >nul 2>&1 && set "SGE_BASH=%%~P")
rem 2) Next to the git on PATH ($PATH: = PATH only, never the current directory) (...\Git\cmd\git.exe -> ...\Git\bin\bash.exe).
for /f "delims=" %%G in ('where $PATH:git 2^>nul') do if not defined SGE_BASH if exist "%%~dpG..\bin\bash.exe" ("%%~dpG..\bin\bash.exe" -c "exit 0" >nul 2>&1 && set "SGE_BASH=%%~dpG..\bin\bash.exe")
rem 3) Any other bash on PATH ($PATH: = PATH only, never the current directory, which is the untrusted repo), but never the System32 / WindowsApps / Sysnative WSL launchers.
for /f "delims=" %%B in ('where $PATH:bash 2^>nul') do if not defined SGE_BASH (
  echo "%%B"| findstr /i /c:"\system32" /c:"\windowsapps" /c:"\sysnative" >nul || ("%%B" -c "exit 0" >nul 2>&1 && set "SGE_BASH=%%B")
)
if not defined SGE_BASH (
  >&2 echo SGE hook launcher: cannot run hook "%~nx1": no working Git Bash found. Tried: Git for Windows under Program Files and LocalAppData, the bash next to git on PATH, and other bash on PATH ^(WSL launchers in System32 / WindowsApps are skipped on purpose^). Remedy: install Git for Windows ^(https://git-scm.com/download/win^) or put its bin directory on PATH. Failing closed.
  exit /b 2
)
"%SGE_BASH%" "%SGE_HOOK%"
exit /b %ERRORLEVEL%
CMDBLOCK
# --- POSIX (sh/bash) half: Linux, macOS, and Git Bash on Windows. hooks.json runs this file as
# `. run-hook.cmd <script>` (dot-sourced): `.` is the one invocation that both PowerShell (Copilot CLI on
# Windows runs hooks through it, where a quoted-path-first command is a parse error) and sh accept. ---
# Prefer the bash already running us ($BASH), else a bash that actually works
# (a PATH shim that exits non-zero is skipped), else the standard locations.
case "${1:-}" in
  *.sh) ;;
  '') echo "SGE hook launcher: no hook script was passed (a shell whose '.' ignores arguments, such as dash, cannot run hooks; use bash, zsh or Git Bash). Failing closed." >&2; exit 2 ;;
  *) echo "SGE hook launcher: cannot run '${1##*/}': not a .sh hook script. Failing closed." >&2; exit 2 ;;
esac
[ -f "$1" ] || { echo "SGE hook launcher: cannot run '${1##*/}': hook script not found. Failing closed." >&2; exit 2; }
sge_bash="${BASH:-}"
if [ -z "$sge_bash" ]; then
  for c in bash /bin/bash /usr/bin/bash /usr/local/bin/bash /opt/homebrew/bin/bash; do
    if [ "$("$c" -c 'echo ok' 2>/dev/null)" = ok ]; then sge_bash="$c"; break; fi
  done
fi
if [ -z "$sge_bash" ]; then
  echo "SGE hook launcher: cannot run hook '${1##*/}': no working bash found (tried bash on PATH, /bin/bash, /usr/bin/bash, /usr/local/bin/bash, /opt/homebrew/bin/bash). Remedy: install bash or put a working bash on PATH. Failing closed." >&2
  exit 2
fi
exec "$sge_bash" "$1"
