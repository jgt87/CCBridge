@echo off
rem CCBridge - double-click to start. Opens the interface in your browser.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ccbridge.ps1" %*
pause
