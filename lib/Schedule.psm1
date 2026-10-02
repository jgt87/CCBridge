# Schedules and Copilot's daily limit: fixed rules on times, no state of their own.
#   A schedule runs a message, a fetch or a runbook once at a set time, or repeating daily, on
#   weekdays or weekly on chosen days, at one or more HH:mm times (local). Agent.psm1 keeps the list, puts due
#   items in the queue (source "schedule") and saves them (Save-Schedules / Restore-Schedules).

$ErrorActionPreference = 'Stop'
$script:Inv = [Globalization.CultureInfo]::InvariantCulture

function ConvertTo-LocalTime([string]$Text) {
    <# 'yyyy-MM-ddTHH:mm' or 'yyyy-MM-ddTHH:mm:ss' (local time) as a DateTime, or $null. #>
    if (-not $Text) { return $null }
    $d = [datetime]::MinValue
    foreach ($f in 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-ddTHH:mm') {
        if ([datetime]::TryParseExact($Text, $f, $script:Inv, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    }
    $null
}

function Get-ScheduleTimes($Schedule) {
    <# The HH:mm times of a repeating schedule, sorted and unique ("times", or the older "time"). #>
    $t = @($Schedule.times | Where-Object { $_ }) + @($Schedule.time | Where-Object { $_ })
    @($t | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Sort-Object -Unique)
}

function Test-ScheduleSpec {
    <# Throws when a schedule is incomplete or invalid. #>
    param([Parameter(Mandatory)][hashtable]$Spec)
    if ($Spec.kind -notin 'chat', 'fetch', 'runbook') { throw "kind must be chat, fetch or runbook" }
    if ($Spec.kind -eq 'chat' -and -not "$($Spec.text)".Trim()) { throw 'The message to schedule is empty' }
    if ($Spec.kind -ne 'chat' -and -not "$($Spec.name)".Trim()) { throw "Which $($Spec.kind) should run?" }
    switch ($Spec.repeat) {
        'once' { if (-not (ConvertTo-LocalTime $Spec.at)) { throw 'Pick the date and time to run it' } }
        { $_ -in 'daily', 'weekdays', 'weekly' } {
            $times = @(Get-ScheduleTimes $Spec)
            if (-not $times.Count) { throw 'Pick at least one time to run it' }
            foreach ($t in $times) { if ($t -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw "'$t' is not a time (HH:mm)" } }
            if ($Spec.repeat -eq 'weekly' -and -not @($Spec.days | Where-Object { "$_" -match '^[0-6]$' }).Count) { throw 'Pick at least one day' }
        }
        default { throw 'repeat must be once, daily, weekdays or weekly' }
    }
}

function Get-NextRun {
    <# The next time a schedule runs after $After, or $null (a one-time schedule that has run).
       A one-time schedule returns its time even when that has passed: it was missed and runs once. #>
    param([Parameter(Mandatory)]$Schedule, [datetime]$After = (Get-Date))
    if ($Schedule.repeat -eq 'once') {
        if ($Schedule.lastRun) { return $null }
        return ConvertTo-LocalTime $Schedule.at
    }
    $times = @(Get-ScheduleTimes $Schedule)
    $days = @($Schedule.days | ForEach-Object { [int]$_ })
    for ($i = 0; $i -le 8; $i++) {
        $date = $After.Date.AddDays($i)
        $dow = [int]$date.DayOfWeek
        $ok = switch ($Schedule.repeat) { 'daily' { $true } 'weekdays' { $dow -ge 1 -and $dow -le 5 } 'weekly' { $days -contains $dow } default { $false } }
        if (-not $ok) { continue }
        foreach ($t in $times) {
            $parts = $t.Split(':')
            $d = $date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1])
            if ($d -gt $After) { return $d }
        }
    }
    $null
}

function Format-ScheduleWhen {
    <# "Every day at 08:00", "Weekdays at 08:00", "Mon, Thu at 08:00", "Once on 2026-10-03 07:30". #>
    param([Parameter(Mandatory)]$Schedule)
    $names = 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'
    switch ($Schedule.repeat) {
        'once' { $d = ConvertTo-LocalTime $Schedule.at; return "Once on $(if ($d) { $d.ToString('yyyy-MM-dd HH:mm', $script:Inv) })" }
        'daily' { return "Every day at $((Get-ScheduleTimes $Schedule) -join ', ')" }
        'weekdays' { return "Weekdays at $((Get-ScheduleTimes $Schedule) -join ', ')" }
        'weekly' { return ((@($Schedule.days | ForEach-Object { [int]$_ } | Sort-Object | ForEach-Object { $names[$_] }) -join ', ') + " at $((Get-ScheduleTimes $Schedule) -join ', ')") }
    }
    ''
}

# Copilot refusing work because of its daily limit (English and Dutch).
$script:LimitText = '(?i)OutOfCredits|daily limit|usage limit|out of credits|reached (your|the) .{0,30}limit|does not accept prompts|dagelijkse limiet|limiet bereikt'

function Test-LimitText {
    <# Whether an error means Copilot's daily limit. An empty message box after a limit was seen
       recently ($LastLimitAt, within 20 hours) counts too: Copilot then refuses input without
       always showing its banner. #>
    param([string]$Text, $LastLimitAt, [datetime]$Now = (Get-Date))
    if (-not $Text) { return $false }
    if ($Text -match $script:LimitText) { return $true }
    if ($Text -match 'message box holds 0 characters' -and $LastLimitAt) {
        $t = ConvertTo-LocalTime "$LastLimitAt"
        if ($t -and ($Now - $t).TotalHours -lt 20) { return $true }
    }
    $false
}

function Get-LimitResetTime {
    <# When Copilot's daily limit resets: from the metering reset time when there is one, else from
       Copilot's message ("check back at 2:00 AM", "om 02:00"), else in an hour (then it is tried
       again). One minute is added as a margin. #>
    param([string]$Message, [datetime]$Now = (Get-Date), [string]$ResetAt = '')
    if ($ResetAt) {
        $r = [datetime]::MinValue
        if ([datetime]::TryParse($ResetAt, $script:Inv, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$r)) {
            $local = $r.ToLocalTime()
            if ($local -gt $Now) { return $local.AddMinutes(1) }
        }
    }
    $m = [regex]::Match("$Message", '(?i)\b(?:at|after|om|na|vanaf)\s+(\d{1,2})(?:[:.](\d{2}))?\s*(a\.?\s?m\.?|p\.?\s?m\.?|uur)?')
    if ($m.Success) {
        $h = [int]$m.Groups[1].Value
        $min = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 0 }
        $ampm = $m.Groups[3].Value.ToLowerInvariant().Replace('.', '').Replace(' ', '')
        if ($ampm -eq 'pm' -and $h -lt 12) { $h += 12 }
        if ($ampm -eq 'am' -and $h -eq 12) { $h = 0 }
        if ($h -le 23 -and $min -le 59) {
            $t = $Now.Date.AddHours($h).AddMinutes($min)
            if ($t -le $Now) { $t = $t.AddDays(1) }
            return $t.AddMinutes(1)
        }
    }
    $Now.AddMinutes(60)
}

Export-ModuleMember -Function ConvertTo-LocalTime, Get-ScheduleTimes, Test-ScheduleSpec, Get-NextRun, Format-ScheduleWhen, Test-LimitText, Get-LimitResetTime
