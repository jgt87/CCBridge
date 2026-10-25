@echo off
rem Tests StreamHub's on-demand features end to end while the StreamHub app runs (start it first with
rem start.cmd): page check, page compare, data profile, runbook from chat, project overview, package for
rem sharing, theme from your colours, tidy-up list and Apply a PowerPoint template, and how Copilot follows
rem StreamHub's instructions. Uses about 4 Copilot messages of the daily limit (none with -SkipCopilot).
rem Makes a new project "On-demand test STAMP" in your projects folder (kept; invented data only).
rem Result: C:\temp\ondemand-test-STAMP.md (checks, what Copilot did, timings; no reply text but the
rem first 200 characters of each done summary).
rem Only some steps:  test-tools\ondemand-test.cmd -Only page-report,tidy
rem Without Copilot:  test-tools\ondemand-test.cmd -SkipCopilot
cd /d "%~dp0.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\ondemand-test.ps1" %*
echo.
echo Send the ondemand-test-*.md file shown above.
pause
