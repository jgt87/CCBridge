@echo off
rem Sends prompts from simple to complex to Microsoft 365 Copilot and reports where it fails or refuses, with exact reply timings.
rem Each step costs one Copilot message. Options: -From 5 -To 9  (run only some steps)
cd /d "%~dp0.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\complexity-test.ps1" %*
echo.
pause
