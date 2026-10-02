@echo off
rem Measures where the time goes between sending a prompt to Copilot and CCBridge having the reply.
rem Sends 3 short prompts (one Copilot message each). Options: -Count 1  (fewer prompts)
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\reply-timing.ps1" %*
echo.
pause
