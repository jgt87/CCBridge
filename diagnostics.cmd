@echo off
rem Packs CCBridge logs and an environment summary into a zip on your desktop.
rem Add  -IncludeReplies  to also include raw Copilot replies (may contain Microsoft 365 data).
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\collect-diagnostics.ps1" %*
pause
