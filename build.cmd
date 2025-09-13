@echo off
setlocal
set "ROOT=%~dp0"

rem Prefer PowerShell 7 if present
for %%P in ("%ProgramFiles%\PowerShell\7\pwsh.exe" "%ProgramFiles%\PowerShell\7-preview\pwsh.exe") do (
  if exist "%%~fP" set "PSH=%%~fP"
)

if not defined PSH (
  set "PSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
  if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" (
    set "PSH=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  )
)

"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%build.ps1" %*
endlocal