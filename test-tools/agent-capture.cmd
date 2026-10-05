@echo off
rem Records how a Copilot agent run (Researcher, Analyst) looks on the wire and on the page, while you
rem run the agent yourself in StreamHub's Edge window. Writes a zip without any text into C:\temp.
rem Examples: test-tools\agent-capture.cmd -Label researcher   /   test-tools\agent-capture.cmd -Label analyst
cd /d "%~dp0.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\agent-capture.ps1" %*
echo.
pause
