@echo off
rem Updates CCBridge to the newest release now (CCBridge also does this at every start).
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\update.ps1" -Force -Report
echo.
echo If CCBridge is running, close its window and start it again to use the new version.
pause