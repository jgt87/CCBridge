@echo off
rem Updates StreamHub to the newest release now (StreamHub also does this at every start).
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\update.ps1" -Force -Report
echo.
echo If StreamHub is running, run start.cmd again to use the new version (it replaces the running copy).
pause