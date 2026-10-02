@echo off
rem StreamHub feasibility probe - double-click to run. No admin rights needed.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0probe.ps1"
echo.
if exist "%~dp0probe-report.txt" (
  echo Opening the report...
  start "" notepad.exe "%~dp0probe-report.txt"
)
pause
