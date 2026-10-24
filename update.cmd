@echo off
rem Updates StreamHub to the newest release now (StreamHub also does this at every start).
rem Go back to an earlier release: update.cmd -To v0.1.149 (automatic updates then skip the newer ones).
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\update.ps1" -Force -Report %*
echo.
echo If StreamHub is running, run start.cmd again to use the new version (it replaces the running copy).
pause