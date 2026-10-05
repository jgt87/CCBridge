@echo off
rem Records how Microsoft 365 Copilot exposes the Work IQ toggle and sources (for StreamHub).
rem Run on a machine with a Microsoft 365 Copilot licence; writes capture-report.json.
cd /d "%~dp0.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\capture-copilot.ps1"
if exist "%~dp0..\capture-report.json" start "" notepad.exe "%~dp0..\capture-report.json"
pause
