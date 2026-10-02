# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
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

    It 'queues due schedules, notes missed runs, continues repeats from now and saves' {
        $s = New-AgentState -Config $config -AppRoot $root
        $s.ScheduleFile = $file
        $s.ProjectRoot = 'C:\Projects\demo'
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

        $r = New-AgentState -Config $config -AppRoot $root
        $r.ScheduleFile = $file
        Restore-Schedules $r | Should Be 2
        (@($r.Schedules) | Where-Object { $_.id -eq $daily.id }).times -join ',' | Should Be '08:00'
    }

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
