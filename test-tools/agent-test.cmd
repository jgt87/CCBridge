@echo off
rem Tests Copilot's Researcher and Analyst agents the way StreamHub will invoke them (mentioned in
rem the message box), one after the other, and records each run. Uses up to 2 agent runs of your
rem monthly allowance. Results: two zips in C:\temp (steps, structure and timings; no reply text).
rem Only one agent:  test-tools\agent-test.cmd Researcher   or   test-tools\agent-test.cmd Analyst
rem Other name in the @ list (another language):  test-tools\agent-test.cmd Researcher -AgentName "Name"
cd /d "%~dp0.."
if "%~1"=="" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\agent-capture.ps1" -Agent Researcher
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\agent-capture.ps1" -Agent Analyst
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\agent-capture.ps1" -Agent %*
)
echo.
echo Send the agent-capture-*.zip files from the folders above.
pause
