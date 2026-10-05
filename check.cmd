@echo off
rem Checks whether this computer has everything StreamHub needs (read-only; -Install NAME adds an optional tool for your user).
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\check.ps1" %*
pause
