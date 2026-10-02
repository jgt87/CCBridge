@echo off
rem Summarises the STRUCTURE of Copilot's recent replies (field names, types, status words; no answer text)
rem into C:\temp, so your tenant's reply format can be supported. Option: -Count 5
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\stream-shape.ps1" %*
echo.
pause
