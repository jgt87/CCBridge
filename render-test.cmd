@echo off
rem Checks which code-block labels Copilot's page shows as a chart ("Chart.js", "Invalid JSON")
rem instead of plain code. Uses one Copilot message in a new chat. Result: a short text file in
rem C:\temp with each label and how the page showed it (no other content).
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\render-test.ps1" %*
echo.
echo Send the StreamHub-render-test-*.txt file shown above.
pause
