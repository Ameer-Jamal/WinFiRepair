@echo off
setlocal
set "SCRIPT=%~dp0src\WifiRepair.ps1"

if not exist "%SCRIPT%" (
  echo Missing: "%SCRIPT%"
  pause
  exit /b 1
)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" (
  set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process -FilePath '%PS%' -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%SCRIPT%\"'"

endlocal
