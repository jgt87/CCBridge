@echo off
rem Asks Copilot (with Work IQ) which fields and filters it can use for a Teams channel message, a
rem Teams group chat message, a Teams 1:1 chat message, an email and a calendar item. Read-only:
rem field names, types and filters only, no item content. Uses one Copilot message per topic and
rem needs a Microsoft 365 Copilot licence. Result: a .md and a .json report in C:\temp.
rem Only some topics:  m365-fields-test.cmd -Topics email,calendar
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\m365-fields-test.ps1" %*
echo.
echo Review the StreamHub-m365-fields-*.md report shown above before sharing it.
pause
