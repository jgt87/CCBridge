# The session report: one page of what happened in a run of the app, from its own log. A made-up
# log with the patterns the report has to see.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\SessionReport.psm1') -Force

$log = @'
2026-01-05 09:00:00.000 [ 4100] INFO    log      StreamHub v0.9.1 (commit abc1234), PowerShell 5.1: lines with process 4100 come from this build
2026-01-05 09:00:01.000 [ 4100] VERBOSE server   GET /api/state (12 ms)
2026-01-05 09:00:02.000 [ 4100] INFO    agent    Queued q-a1 (chat, from user) {"title":"Plan: Build a page that lists the open tickets"}
2026-01-05 09:00:02.100 [ 4100] INFO    agent    Turn started {"mode":"plan","chars":120}
2026-01-05 09:00:02.200 [ 4100] INFO    agent    Task kind: coding {"partsAdded":3}
2026-01-05 09:00:03.000 [ 4100] VERBOSE agent    Round 1: sending {"chars":5000}
2026-01-05 09:00:10.000 [ 4100] VERBOSE agent    Round 1: reply parsed {"actions":["read","done"]}
2026-01-05 09:00:11.000 [ 4100] INFO    agent    Queue q-a1 done {"messages":1}
2026-01-05 09:01:00.000 [ 4100] INFO    agent    Queued q-a2 (chat, from user) {"title":"Build this now, following the approved plan below. Change files with action blocks."}
2026-01-05 09:01:00.100 [ 4100] VERBOSE agent    status: A big request: Copilot plans first, as chosen for this project (Project setup in the Files tab changes it).
2026-01-05 09:01:00.200 [ 4100] INFO    agent    Turn started {"mode":"plan","chars":900}
2026-01-05 09:01:01.000 [ 4100] VERBOSE agent    Round 1: sending {"chars":5000}
2026-01-05 09:01:05.000 [ 4100] VERBOSE agent    Round 1: reply parsed {"actions":["write index.html"]}
2026-01-05 09:01:05.500 [ 4100] INFO    agent    action failed 5-0 [PLAN-MODE]: write skipped (plan mode) {"reasons":[]}
2026-01-05 09:01:09.000 [ 4100] INFO    agent    Queue q-a2 done {"messages":1}
2026-01-05 09:02:00.000 [ 4100] INFO    agent    Queued q-a3 (chat, from user) {"title":"Build this now, following the approved plan below. Change files with action blocks."}
2026-01-05 09:02:00.200 [ 4100] INFO    agent    Turn started {"mode":"ask","chars":900}
2026-01-05 09:02:01.000 [ 4100] VERBOSE agent    Round 1: sending {"chars":5000}
2026-01-05 09:02:05.000 [ 4100] VERBOSE agent    Round 1: reply parsed {"actions":["edit js/app.js","edit js/app.js"]}
2026-01-05 09:02:05.500 [ 4100] INFO    agent    action failed 6-0 [EDIT-NOT-FOUND]: edit js/app.js failed {"reasons":[]}
2026-01-05 09:02:06.500 [ 4100] INFO    agent    action failed 6-1 [EDIT-NOT-FOUND]: edit js/app.js failed {"reasons":[]}
2026-01-05 09:02:07.000 [ 4100] VERBOSE agent    status: Copilot explained how to do it instead of doing it. Sending the task again.
2026-01-05 09:02:08.000 [ 4100] VERBOSE agent    status: Copilot explained how to do it instead of doing it. Sending the task again.
2026-01-05 09:02:09.000 [ 4100] INFO    bridge   Message box content does not match the prompt {"expected":900,"actual":880}
2026-01-05 09:02:10.000 [ 4100] VERBOSE server   POST /api/files (6200 ms)
2026-01-05 09:02:11.000 [ 4100] VERBOSE bridge   Reply received over the Copilot stream connection {"chars":100,"result":"Success","ms":75000}
2026-01-05 09:03:00.000 [ 4100] INFO    agent    Queue q-a3 done {"messages":3}
2026-01-05 09:03:00.000 [ 7777] INFO    agent    Queued q-zz (chat, from user) {"title":"another run"}
'@

Describe 'Session report' {
    $lines = $log -split "`r?`n"
    It 'reads the run of one process' {
        Get-LatestRunId $lines | Should Be 4100
        $e = @(Read-LogEntries $lines 4100)
        @($e | Where-Object { $_.msg -match 'another run' }).Count | Should Be 0
        Get-LogValue '{"title":"It''s a \"test\"","n":3}' 'title' | Should Be 'It''s a "test"'
        Get-LogValue '{"title":"x","n":3}' 'n' | Should Be '3'
    }
    It 'names the loops, repeated failures, nudges, typing errors and slow parts' {
        $r = Get-SessionReport (Read-LogEntries $lines 4100)
        $r | Should Match '- Build: StreamHub v0\.9\.1 \(commit abc1234\)'
        $r | Should Match 'Tasks: 3, Copilot messages: 5'
        $r | Should Match '\*\*Plan loop:\*\* 1 approved build\(s\) went to plan mode again'
        $r | Should Match '\*\*Step failed 2 times \[EDIT-NOT-FOUND\]:\*\* edit js/app\.js failed'
        $r | Should Match "\*\*Nudge 'explained instead of acting' 2 times"
        $r | Should Match '\*\*Typing into Copilot failed 1 time'
        $r | Should Match '\*\*Slow replies:\*\* 1'
        $r | Should Match '\*\*Slow request:\*\* POST /api/files took up to 6\.2 s'
        $r | Should Match '\| 09:01:00 \| chat/user \| Build this now, following the approved plan below\..* \| plan \| 1 \| 1 \| \d+ s \| write 1 \| PLANNED AGAIN after approval; failed: PLAN-MODE \|'
        $r | Should Match 'failed: EDIT-NOT-FOUND x2'
        $r | Should Not Match 'The log level was info'
    }
    It 'says when the log has nothing for the run, or only info lines' {
        Get-SessionReport @() | Should Match 'no lines for this run'
        $info = @(Read-LogEntries @($lines | Where-Object { $_ -notmatch 'VERBOSE' }) 4100)
        Get-SessionReport $info | Should Match 'The log level was info'
    }
    It 'writes the report file' {
        $dir = Join-Path $env:TEMP ('ccb-rep-' + [guid]::NewGuid().ToString('N'))
        $f = Join-Path $dir 'ccbridge-20260105.log'; New-Item -ItemType Directory $dir | Out-Null
        try {
            [IO.File]::WriteAllText($f, $log)
            $p = New-SessionReportFile -LogFile $f -OutDir $dir
            $p | Should Match 'session-\d{8}-\d{6}\.md$'
            [IO.File]::ReadAllText($p) | Should Match '^# Session report'
        } finally { Remove-Item $dir -Recurse -Force }
    }
}
