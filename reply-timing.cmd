@echo off
rem Quick timing run: steps 1-3 of the complexity and timing test (three short prompts, one Copilot message each).
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\complexity-test.ps1" -From 1 -To 3 %*
echo.
pause
