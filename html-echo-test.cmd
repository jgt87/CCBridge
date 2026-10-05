@echo off
rem Checks which parts of HTML tags reach StreamHub unchanged from Copilot: asks Copilot to repeat
rem made-up HTML lines exactly, once via the normal route and once read from the page, and compares
rem them line by line. Uses two Copilot messages. Result: a short text file in C:\temp (made-up
rem lines only). One route only:  html-echo-test.cmd -Route page
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\html-echo-test.ps1" %*
echo.
echo Send the StreamHub-html-echo-*.txt file shown above.
pause
