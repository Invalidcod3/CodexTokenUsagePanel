@echo off
setlocal
cd /d "%~dp0"
set "APP=%~dp0dist\CodexMeter\CodexMeter.exe"
if exist "%APP%" (
  start "" "%APP%" --dashboard
  exit /b 0
)
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL%" (
  echo Windows PowerShell was not found.
  pause
  exit /b 1
)
start "" "%POWERSHELL%" -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Start-CodexDashboard.ps1"
endlocal
