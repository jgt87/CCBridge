@echo off
rem Checks whether this computer has everything StreamHub needs (read-only).
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\check.ps1" %*
pause
