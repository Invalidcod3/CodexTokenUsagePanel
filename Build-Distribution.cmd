@echo off
setlocal
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Distribution.ps1" %*
if errorlevel 1 (
  echo.
  echo Distribution build failed.
  pause
  exit /b 1
)
echo.
pause
endlocal
