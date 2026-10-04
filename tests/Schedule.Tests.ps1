# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# Project state (backups, chat history) of the test projects goes to a temporary folder, deleted below.
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-test-state-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Schedule.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

# Friday 2 October 2026, 10:00
$fri = Get-Date -Year 2026 -Month 10 -Day 2 -Hour 10 -Minute 0 -Second 0 -Millisecond 0

Describe 'Get-NextRun' {
    It 'runs daily at the next of several times' {
        (Get-NextRun @{ repeat = 'daily'; times = @('08:00', '13:00') } $fri) | Should Be $fri.Date.AddHours(13)
        (Get-NextRun @{ repeat = 'daily'; times = @('08:00', '13:00') } $fri.Date.AddHours(14)) | Should Be $fri.Date.AddDays(1).AddHours(8)
    }
    It 'skips the weekend for weekdays' {
        $sat = $fri.Date.AddDays(1).AddHours(9)
        (Get-NextRun @{ repeat = 'weekdays'; times = @('08:30') } $sat) | Should Be $fri.Date.AddDays(3).AddHours(8).AddMinutes(30)
    }
    It 'runs weekly on the chosen days (0 = Sunday)' {
        (Get-NextRun @{ repeat = 'weekly'; days = @(1, 3); times = @('07:00') } $fri) | Should Be $fri.Date.AddDays(3).AddHours(7)
        (Get-NextRun @{ repeat = 'weekly'; days = @(5); times = @('09:00', '17:00') } $fri) | Should Be $fri.Date.AddHours(17)
    }
    It 'reads the older single time' {
        (Get-NextRun @{ repeat = 'daily'; time = '11:15' } $fri) | Should Be $fri.Date.AddHours(11).AddMinutes(15)
    }
    It 'returns a one-time schedule until it has run, also when it was missed' {
        (Get-NextRun @{ repeat = 'once'; at = '2026-10-01T07:30' } $fri) | Should Be $fri.Date.AddDays(-1).AddHours(7).AddMinutes(30)
        Get-NextRun @{ repeat = 'once'; at = '2026-10-01T07:30'; lastRun = '2026-10-02T10:00:00' } $fri | Should BeNullOrEmpty
    }
}

Describe 'Test-ScheduleSpec and Format-ScheduleWhen' {
    It 'refuses incomplete schedules' {
        { Test-ScheduleSpec @{ kind = 'chat'; text = ''; repeat = 'daily'; times = @('08:00') } } | Should Throw 'empty'
        { Test-ScheduleSpec @{ kind = 'chat'; text = 'x'; repeat = 'daily'; times = @() } } | Should Throw 'at least one time'
        { Test-ScheduleSpec @{ kind = 'chat'; text = 'x'; repeat = 'daily'; times = @('25:00') } } | Should Throw 'not a time'
        { Test-ScheduleSpec @{ kind = 'runbook'; name = 'm'; repeat = 'weekly'; times = @('08:00'); days = @() } } | Should Throw 'at least one day'
        { Test-ScheduleSpec @{ kind = 'fetch'; name = 'm'; repeat = 'once'; at = 'tomorrow' } } | Should Throw 'date and time'
        { Test-ScheduleSpec @{ kind = 'runbook'; name = 'meetings'; repeat = 'weekly'; times = @('08:00'); days = @(1, 5) } } | Should Not Throw
    }
    It 'describes when it runs' {
        Format-ScheduleWhen @{ repeat = 'weekly'; days = @(5, 1); times = @('13:00', '08:00') } | Should Be 'Mon, Fri at 08:00, 13:00'
        Format-ScheduleWhen @{ repeat = 'weekdays'; times = @('08:00') } | Should Be 'Weekdays at 08:00'
    }
}

Describe "Copilot's daily limit" {
    It 'reads the reset time from the message' {
        (Get-LimitResetTime "You've reached your daily limit. Get more usage now or check back at 2:00 AM." $fri) | Should Be $fri.Date.AddDays(1).AddHours(2).AddMinutes(1)
        (Get-LimitResetTime 'Check back at 3:30 PM.' $fri) | Should Be $fri.Date.AddHours(15).AddMinutes(31)
        (Get-LimitResetTime 'Je dagelijkse limiet is bereikt, probeer het om 14:00 uur opnieuw' $fri) | Should Be $fri.Date.AddHours(14).AddMinutes(1)
        (Get-LimitResetTime 'Limit reached.' $fri) | Should Be $fri.AddMinutes(60)
    }
    It 'recognises limit errors, and an empty message box shortly after a limit' {
        Test-LimitText "Copilot answered with 'OutOfCredits': You've reached your daily limit." $null $fri | Should Be $true
        Test-LimitText 'message box holds 0 characters, expected 13' $null $fri | Should Be $false
        Test-LimitText 'message box holds 0 characters, expected 13' '2026-10-02T08:00:00' $fri | Should Be $true
        Test-LimitText 'SEARCH text not found' '2026-10-02T08:00:00' $fri | Should Be $false
    }
}

Describe 'Invoke-DueSchedules' {
    $config = Get-CCBridgeConfig harness $root
    $file = Join-Path $env:TEMP ('ccb-sched-' + [guid]::NewGuid().ToString('N') + '.json')

    $proj = Join-Path $env:TEMP ('ccb-sched-proj-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force -Path $proj

    It 'queues due schedules, notes missed runs, continues repeats from now and saves' {
        $s = New-AgentState -Config $config -AppRoot $root
        $s.ScheduleFile = $file
        $s.ProjectRoot = $proj
        $daily = New-AgentSchedule $s @{ kind = 'runbook'; name = 'meetings'; repeat = 'daily'; times = @('08:00') }
        $once = New-AgentSchedule $s @{ kind = 'chat'; text = 'Update the report'; repeat = 'once'; at = '2026-10-02T09:58' }
        $daily.nextRun = '2026-10-01T08:00:00'   # missed while closed
        Invoke-DueSchedules $s $fri -Force | Should Be 2
        $s.Queue.Count | Should Be 2
        $q = @($s.Queue)
        ($q | Where-Object { $_.kind -eq 'runbook' }).source | Should Be 'schedule'
        ($q | Where-Object { $_.kind -eq 'runbook' }).note | Should Match 'while StreamHub was closed'
        ($q | Where-Object { $_.kind -eq 'chat' }).note | Should BeNullOrEmpty
        $daily.nextRun | Should Be '2026-10-03T08:00:00'
        $once.enabled | Should Be $false
        $once.nextRun | Should BeNullOrEmpty
        Invoke-DueSchedules $s $fri -Force | Should Be 0

        # Saved in the project, not in the app's data folder.
        Test-Path (Join-Path $proj '.streamhub\schedules.json') | Should Be $true
        Test-Path $file | Should Be $false

        $r = New-AgentState -Config $config -AppRoot $root
        $r.ScheduleFile = $file
        $r.ProjectRoot = $proj
        Restore-Schedules $r | Should Be 2
        (@($r.Schedules) | Where-Object { $_.id -eq $daily.id }).times -join ',' | Should Be '08:00'
    }

    It 'edits a schedule in place: same id and project, new time, saved in the project' {
        $s = New-AgentState -Config $config -AppRoot $root
        $s.ScheduleFile = $file
        $s.ProjectRoot = $proj
        $null = Restore-Schedules $s
        $x = New-AgentSchedule $s @{ kind = 'chat'; text = 'Weekly summary'; repeat = 'weekly'; days = @(1); times = @('09:00') }
        $y = Update-AgentSchedule $s $x.id @{ kind = 'chat'; text = 'Weekly summary for the team'; title = 'Team summary'; repeat = 'weekly'; days = @(5); times = @('16:30') }
        $y.id | Should Be $x.id
        $y.projectRoot | Should Be $x.projectRoot
        $y.title | Should Be 'Team summary'
        ($y.days -join ',') + ' ' + ($y.times -join ',') | Should Be '5 16:30'
        ([datetime]$y.nextRun).DayOfWeek | Should Be 'Friday'
        [IO.File]::ReadAllText((Join-Path $proj '.streamhub\schedules.json')) | Should Match 'Team summary'
        { Update-AgentSchedule $s 's-nothere' @{ kind = 'chat'; text = 'x'; repeat = 'daily'; times = @('08:00') } } | Should Throw
        # A finished one-time schedule given a new time in the future runs again.
        $once = New-AgentSchedule $s @{ kind = 'chat'; text = 'Once'; repeat = 'once'; at = (Get-Date).AddHours(1).ToString('yyyy-MM-ddTHH:mm') }
        $once.enabled = $false
        $later = (Get-Date).AddDays(1).ToString('yyyy-MM-ddTHH:mm')
        (Update-AgentSchedule $s $once.id @{ kind = 'chat'; text = 'Once'; repeat = 'once'; at = $later }).enabled | Should Be $true
        foreach ($id in $x.id, $once.id) { $s.Schedules.Remove((@($s.Schedules) | Where-Object { $_.id -eq $id })[0]) }
        Save-Schedules $s
    }

    It 'picks up a changed or removed project file' {
        $r = New-AgentState -Config $config -AppRoot $root
        $r.ScheduleFile = $file
        $r.ProjectRoot = $proj
        $null = Restore-Schedules $r
        $pf = Join-Path $proj '.streamhub\schedules.json'
        # Edited outside the app (by hand, or synced from another machine): one schedule left.
        $all = [IO.File]::ReadAllText($pf) | ConvertFrom-Json; $one = @($all)[0]
        $one.title = 'Edited elsewhere'
        [IO.File]::WriteAllText($pf, (ConvertTo-Json -InputObject @($one) -Depth 5))
        (Get-Item $pf).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(1)
        Sync-ProjectSchedules $r -Force | Should Be 1
        @($r.Schedules).Count | Should Be 1
        @($r.Schedules)[0].title | Should Be 'Edited elsewhere'
        Remove-Item -LiteralPath $pf
        $null = Sync-ProjectSchedules $r -Force
        @($r.Schedules).Count | Should Be 0
    }

    It 'moves schedules from the old app-wide file into their projects once' {
        $old = Join-Path $env:TEMP ('ccb-old-sched-' + [guid]::NewGuid().ToString('N') + '.json')
        $item = @{ id = 's-old12345'; title = 'Old one'; kind = 'chat'; text = 'hi'; name = ''; projectRoot = $proj; repeat = 'daily'; times = @('07:30'); at = ''; days = @(); enabled = $true; created = '2026-10-01T10:00:00'; lastRun = $null; lastQueueId = $null; nextRun = $null }
        [IO.File]::WriteAllText($old, (ConvertTo-Json -InputObject @($item) -Depth 5))
        $r = New-AgentState -Config $config -AppRoot $root
        $r.ScheduleFile = $old
        $null = Restore-Schedules $r
        @($r.Schedules | Where-Object { $_.id -eq 's-old12345' }).Count | Should Be 1
        Test-Path $old | Should Be $false
        Test-Path "$old.moved-to-projects" | Should Be $true
        ([IO.File]::ReadAllText((Join-Path $proj '.streamhub\schedules.json'))) | Should Match 's-old12345'
        Remove-Item -LiteralPath "$old.moved-to-projects"
    }

    It 'runs a project schedule where the project is now (another machine, another path)' {
        $moved = "$proj-moved"
        Copy-Item -LiteralPath $proj -Destination $moved -Recurse
        $r = New-AgentState -Config $config -AppRoot $root
        $r.ScheduleFile = $file
        $r.ProjectRoot = $moved
        $null = Restore-Schedules $r
        @($r.Schedules | Where-Object { $_.id -eq 's-old12345' })[0].projectRoot | Should Be $moved
        Remove-Item -LiteralPath $moved -Recurse -Force
    }
    Remove-Item -LiteralPath $proj -Recurse -Force

    It 'pauses and resumes the queue' {
        $s = New-AgentState -Config $config -AppRoot $root
        Set-QueuePause $s $fri.AddHours(16) 'daily limit'
        $s.PausedUntil | Should Be '2026-10-03T02:00:00'
        $s.LastLimitAt | Should Not BeNullOrEmpty
        Resume-AgentQueue $s 'test'
        $s.PausedUntil | Should BeNullOrEmpty
    }

    It 'keeps a pause across a restart, and not one that has passed' {
        $pf = Join-Path $env:TEMP ('ccb-pause-' + [guid]::NewGuid().ToString('N') + '.json')
        $s = New-AgentState -Config $config -AppRoot $root
        $s.PauseFile = $pf
        Set-QueuePause $s (Get-Date).AddHours(2) 'daily limit'
        $r = New-AgentState -Config $config -AppRoot $root
        $r.PauseFile = $pf
        Restore-QueuePause $r
        $r.PausedUntil | Should Be $s.PausedUntil
        $r.LastLimitAt | Should Not BeNullOrEmpty
        Set-QueuePause $s (Get-Date).AddMinutes(-5) 'daily limit'
        $r2 = New-AgentState -Config $config -AppRoot $root
        $r2.PauseFile = $pf
        Restore-QueuePause $r2
        $r2.PausedUntil | Should BeNullOrEmpty
        $r2.LastLimitAt | Should Not BeNullOrEmpty
        [IO.File]::Delete($pf)
    }

    Remove-Item $file -Force -ErrorAction SilentlyContinue
}

if ($env:CCBRIDGE_STATE_ROOT -and (Test-Path -LiteralPath $env:CCBRIDGE_STATE_ROOT)) { [IO.Directory]::Delete($env:CCBRIDGE_STATE_ROOT, $true) }
$env:CCBRIDGE_STATE_ROOT = $null