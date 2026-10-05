@echo off
rem Checks whether Copilot stops answering after many prompts sent back to back: sends tiny made-up
rem prompts one after another (at most 40) and reports per prompt whether Copilot answered. Stops
rem after 3 failures in a row. No Microsoft 365 data. Result: a short text file in C:\temp.
rem Options:  rate-limit-test.cmd -Count 60 -GapSec 10 -NewChatEvery 10 -StopAfter 3
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\rate-limit-test.ps1" %*
echo.
echo Send the StreamHub-rate-limit-*.txt file shown above.
pause
