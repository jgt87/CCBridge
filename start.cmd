@echo off
rem StreamHub - double-click to start. Opens the interface in your browser.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0streamhub.ps1" %*
pause
