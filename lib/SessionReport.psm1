# Session report: what happened in a run of StreamHub, from its own diagnostic log (already masked
# when written: no user name, paths or email addresses), as a short Markdown page. Fixed rules on the
# log lines, no model: per task (queued -> done) the request, kind, mode, rounds, actions, failed
# steps, nudges and checks; across the run the patterns that mean something went wrong (a plan
# planned again, the same request sent again and again, a step failing the same way, typing and
# no-answer errors, slow requests, polling noise, unexpected errors). The person sends this one file
# instead of a folder of logs. Command menu > Session report (Server POST /api/session-report) and
# Export diagnostics. ASCII only (Windows PowerShell 5.1).

$script:LinePattern = '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) \[\s*(\d+)\] (\w+)\s+(\S+)\s+(.*)$'
# Status lines that are the helper program correcting Copilot (with a short name for the count).
$script:NudgePatterns = [ordered]@{
    'explained instead of acting' = 'Copilot explained how to do it instead of doing it'
    'only read and searched' = 'has only read and searched'
    'reminded before finishing' = 'Before finishing: Copilot is reminded'
    'plan coverage' = 'the plan names are missing|placeholder\(s\) found'
    'page errors sent back' = 'Checking .* again after the fix'
    'files nothing loads' = 'New file\(s\) that no page or script loads'
    'Done when not met' = 'not met'
    'stopped without done' = 'Copilot did not report the task as done'
}

function Read-LogEntries {
    <# The log lines as entries @{ time; pid; level; comp; msg; data }; lines of other shapes (stack
       traces) are skipped. -ProcessId keeps one process (one run of the app). #>
    param([string[]]$Lines, [int]$ProcessId = 0)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($l in $Lines) {
        $m = [regex]::Match($l, $script:LinePattern)
        if (-not $m.Success) { continue }
        $procId = [int]$m.Groups[2].Value
        if ($ProcessId -and $procId -ne $ProcessId) { continue }
        $rest = $m.Groups[5].Value
        $data = ''
        $j = $rest.IndexOf(' {')
        if ($j -gt 0 -and $rest.TrimEnd().EndsWith('}')) { $data = $rest.Substring($j + 1); $rest = $rest.Substring(0, $j) }
        $out.Add([pscustomobject]@{ time = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture); pid = $procId; level = $m.Groups[3].Value; comp = $m.Groups[4].Value; msg = $rest.Trim(); data = $data })
    }
    $out.ToArray()
}

function Get-LogValue([string]$Data, [string]$Name) {
    # One field of a log line's JSON data, without parsing the whole thing (it may be cut off).
    $m = [regex]::Match($Data, '"' + [regex]::Escape($Name) + '"\s*:\s*("((?:[^"\\]|\\.)*)"|-?\d+(\.\d+)?|true|false|null)')
    if (-not $m.Success) { return $null }
    if ($m.Groups[2].Success -and $m.Groups[1].Value.StartsWith('"')) { return ($m.Groups[2].Value -replace '\\u0027', "'" -replace '\\"', '"' -replace '\\n', ' ') }
    $m.Groups[1].Value
}

function Get-LatestRunId([string[]]$Lines) {
    # The process of the last "StreamHub vX ... lines with process N come from this build" header.
    $id = 0
    foreach ($l in $Lines) { $m = [regex]::Match($l, 'lines with process (\d+) come from this build'); if ($m.Success) { $id = [int]$m.Groups[1].Value } }
    $id
}

function Get-SessionReport {
    <# The report as Markdown, for the entries of one run (Read-LogEntries -ProcessId). $Build: the
       version line when known. #>
    param($Entries, [string]$Build = '', [switch]$Metrics)
    $e = @($Entries)
    $sb = New-Object Text.StringBuilder
    if (-not $e.Count) { return "# Session report`n`nThe log has no lines for this run." }
    $tasks = New-Object System.Collections.Generic.List[object]
    $open = New-Object System.Collections.Generic.List[object]
    $byId = @{}
    $codes = @{}; $codeExample = @{}
    $nudges = [ordered]@{}; foreach ($k in $script:NudgePatterns.Keys) { $nudges[$k] = 0 }
    $awaitAt = @{}
    $typing = @(); $noAnswer = @(); $lost = @(); $errors = @(); $slowSends = @(); $slowApi = @{}; $gets = @{}; $attach = @()
    foreach ($x in $e) {
        if (-not $Build -and $x.msg -match '^StreamHub v\S+ \(commit \w+\)') { $Build = ($x.msg -replace ': lines with process.*$', '') }
        if (-not $Build -and $x.msg -match '^Web app started on ') { $v = Get-LogValue $x.data 'ccbridge'; if ($v) { $Build = "StreamHub $v" } }
        if ($x.comp -eq 'server') {
            $m = [regex]::Match($x.msg, '^(GET|POST) (\S+) \((\d+) ms\)')
            if ($m.Success) {
                $ep = "$($m.Groups[1].Value) $($m.Groups[2].Value -replace '\?.*$', '')"
                if ($m.Groups[1].Value -eq 'GET') { $gets[$ep] = 1 + [int]$gets[$ep] }
                if ([int]$m.Groups[3].Value -ge 5000) { $slowApi[$ep] = [Math]::Max([int]$slowApi[$ep], [int]$m.Groups[3].Value) }
            }
            continue
        }
        $m = [regex]::Match($x.msg, '^Queued (q-\w+) \(([\w-]+), from (\w+)\)')
        if ($m.Success) {
            $t = [pscustomobject]@{ id = $m.Groups[1].Value; kind = $m.Groups[2].Value; source = $m.Groups[3].Value; title = "$(Get-LogValue $x.data 'title')"; queued = $x.time; started = $null; ended = $null; mode = ''; taskKind = ''; rounds = 0; messages = 0; actions = @{}; failed = New-Object System.Collections.Generic.List[string]; notes = New-Object System.Collections.Generic.List[string]; pageProblems = 0; waitMs = 0; webReads = 0; webCut = 0 }
            $tasks.Add($t); $open.Add($t); $byId[$t.id] = $t
            continue
        }
        $m = [regex]::Match($x.msg, '^Queue (q-\w+) done')
        if ($m.Success) {
            $t = $byId[$m.Groups[1].Value]
            if ($t) { $t.ended = $x.time; $t.messages = [int](Get-LogValue $x.data 'messages'); [void]$open.Remove($t) }
            continue
        }
        $cur = if ($open.Count) { $open[0] } else { $null }
        if ($cur -and -not $cur.started -and $x.msg -match '^(Turn started|Setup questions asked|Round 1)') { $cur.started = $x.time }
        if ($cur -and $x.msg -eq 'Turn started') { $cur.mode = "$(Get-LogValue $x.data 'mode')" }
        if ($cur -and $x.msg -match '^Task kind: (\w+)') { $cur.taskKind = $Matches[1] }
        if ($cur -and $x.msg -match '^Round (\d+): sending') { $cur.rounds = [Math]::Max($cur.rounds, [int]$Matches[1]) }
        if ($cur -and $x.msg -match '^Round \d+: reply parsed') {
            foreach ($a in [regex]::Matches($x.data, '"(\w+)(?: [^"]*)?"')) { if ($a.Groups[1].Value -ne 'actions') { $cur.actions[$a.Groups[1].Value] = 1 + [int]$cur.actions[$a.Groups[1].Value] } }
        }
        $m = [regex]::Match($x.msg, '^action failed \S+ \[([\w-]+)\]: (.*)$')
        if ($m.Success) {
            $c = $m.Groups[1].Value
            $codes[$c] = 1 + [int]$codes[$c]; if (-not $codeExample[$c]) { $codeExample[$c] = $m.Groups[2].Value }
            if ($cur) { $cur.failed.Add($c) }
        }
        if ($x.msg -match '^Page check .* \{?' -or $x.msg -match '^Page check ') { $n = [int](Get-LogValue $x.data 'problems'); if ($cur -and $n -gt $cur.pageProblems) { $cur.pageProblems = $n } }
        if ($x.msg -match '^status: (.*)$') {
            $st = $Matches[1]
            foreach ($k in $script:NudgePatterns.Keys) { if ($st -match $script:NudgePatterns[$k]) { $nudges[$k]++; if ($cur -and -not $cur.notes.Contains($k)) { $cur.notes.Add($k) } } }
            if ($st -match '^A big request: Copilot plans first' -and $cur -and $cur.title -match '^(Build this now|Continue and make the change now)') { if ($cur) { $cur.notes.Add('PLANNED AGAIN after approval') } }
        }
        # Waiting for the person: from a step's "-> awaiting" to its result (every kind of approval).
        $aw = [regex]::Match($x.msg, '^action (\S+) \S+ -> awaiting')
        if ($aw.Success) { $awaitAt[$aw.Groups[1].Value] = $x.time }
        $rs = [regex]::Match($x.msg, '^result (\S+) ')
        if ($rs.Success -and $awaitAt.ContainsKey($rs.Groups[1].Value)) { if ($cur) { $cur.waitMs += [int]($x.time - $awaitAt[$rs.Groups[1].Value]).TotalMilliseconds }; $awaitAt.Remove($rs.Groups[1].Value) }
        if ($x.comp -eq 'web' -and $x.msg -eq 'Read a web page' -and $cur) { $cur.webReads++; if ((Get-LogValue $x.data 'truncated') -eq 'true') { $cur.webCut++ } }
        if ($x.msg -match 'message box holds \d+ characters|Message box content does not match') { $typing += $x }
        if ($x.msg -match "answered with 'NoAnswer'|Copilot answered with" -or (Get-LogValue $x.data 'result') -eq 'NoAnswer') { $noAnswer += $x }
        if ($x.msg -match '(?i)\blost\b.*(resend|again)|sending it again|typing again') { $lost += $x }
        if ($x.msg -match '^Attachment left out') { $attach += $x }
        if ($x.level -eq 'ERROR' -or $x.msg -match 'UNEXPECTED') { $errors += $x }
        if ($x.msg -match '^Reply received' -and [int](Get-LogValue $x.data 'ms') -ge 60000) { $slowSends += $x }
    }
    $first = $e[0].time; $last = $e[-1].time
    $minutes = [Math]::Max(1, ($last - $first).TotalMinutes)
    # Findings: the patterns that mean something needs a look.
    $find = New-Object System.Collections.Generic.List[string]
    $replanned = @($tasks | Where-Object { $_.notes -contains 'PLANNED AGAIN after approval' -or ($_.title -match '^(Build this now|Continue and make the change now)' -and $_.mode -eq 'plan') })
    if ($replanned.Count) { $find.Add("**Plan loop:** $($replanned.Count) approved build(s) went to plan mode again instead of building ($(($replanned | ForEach-Object { $_.queued.ToString('HH:mm') }) -join ', '))") }
    foreach ($g in @($tasks | Where-Object { $_.title } | Group-Object { ($_.title -replace '^(Plan: )', '').Substring(0, [Math]::Min(60, ($_.title -replace '^(Plan: )', '').Length)) } | Where-Object Count -ge 3)) { $find.Add("**Same request $($g.Count) times:** ""$($g.Name)..."" (the person had to send it again, or a loop sent it)") }
    foreach ($c in @($codes.Keys | Sort-Object { -$codes[$_] })) { if ($codes[$c] -ge 2) { $find.Add("**Step failed $($codes[$c]) times [$c]:** $($codeExample[$c])") } }
    foreach ($k in $nudges.Keys) { if ($nudges[$k] -ge 2) { $find.Add("**Nudge '$k' $($nudges[$k]) times:** the helper program had to correct Copilot this way repeatedly") } }
    if ($typing.Count) { $find.Add("**Typing into Copilot failed $($typing.Count) time(s)** (first at $($typing[0].time.ToString('HH:mm:ss')): $($typing[0].msg))") }
    if ($noAnswer.Count) { $find.Add("**Copilot gave no answer $($noAnswer.Count) time(s)** (first at $($noAnswer[0].time.ToString('HH:mm:ss')))") }
    if ($lost.Count) { $find.Add("**Lost or retyped messages: $($lost.Count)** (first: $($lost[0].msg))") }
    if ($attach.Count) { $find.Add("**Attachments left out: $($attach.Count)** (first: $($attach[0].msg))") }
    if ($slowSends.Count) { $find.Add("**Slow replies:** $($slowSends.Count) Copilot reply(ies) took a minute or more") }
    foreach ($ep in @($slowApi.Keys | Sort-Object)) { $find.Add("**Slow request:** $ep took up to $([Math]::Round($slowApi[$ep] / 1000, 1)) s") }
    foreach ($ep in @($gets.Keys | Sort-Object)) { $rate = $gets[$ep] / $minutes; if ($rate -ge 20) { $find.Add("**Polling noise:** $ep about $([int]$rate) times a minute") } }
    if ($errors.Count) { $find.Add("**Errors in the log: $($errors.Count)** (first: $($errors[0].comp) $($errors[0].msg))") }
    $open = @($tasks | Where-Object { -not $_.ended })
    if ($open.Count) { $find.Add("**Did not finish: $($open.Count) task(s)** ($(($open | ForEach-Object { "$($_.queued.ToString('HH:mm')) " + ($_.title -replace '\s+', ' ').Substring(0, [Math]::Min(50, ($_.title -replace '\s+', ' ').Length)) }) -join '; ')): the app stopped, or it was still running when the log ends") }
    $waits = [int](@($tasks | ForEach-Object { $_.waitMs }) | Measure-Object -Sum).Sum
    $longWait = @($tasks | Sort-Object waitMs -Descending | Select-Object -First 1)
    if ($waits -ge 120000) { $find.Add("**Waiting for approvals: $([Math]::Round($waits / 60000, 1)) min in all** (most in the task at $($longWait[0].queued.ToString('HH:mm')): $([Math]::Round($longWait[0].waitMs / 60000, 1)) min); approvals that repeat for the same site can be given once for the whole site") }
    $cut = [int](@($tasks | ForEach-Object { $_.webCut }) | Measure-Object -Sum).Sum
    if ($cut) { $find.Add("**Web reads cut off at the size limit: $cut** (the data did not fit in the chat; saving it with ACTION web save gets all of it)") }
    foreach ($t in @($tasks | Where-Object { $_.webReads -ge 8 })) { $find.Add("**Many web reads: $($t.webReads) in the task at $($t.queued.ToString('HH:mm'))** ($($t.webCut) cut off)") }
    if (-not @($e | Where-Object { $_.level -in 'VERBOSE', 'TRACE' }).Count) { $find.Add('**The log level was info:** set Logging to verbose (command menu) for rounds, actions and timings in the next report') }
    if ($Metrics) {
        return @{
            build = $(if ($Build) { ($Build -replace '^StreamHub ', '' -replace ',.*$', '') } else { '' })
            tasks = $tasks.Count
            messages = [int](@($tasks | ForEach-Object { $_.messages }) | Measure-Object -Sum).Sum
            rounds = [int](@($tasks | ForEach-Object { $_.rounds }) | Measure-Object -Sum).Sum
            nudges = [int](@($nudges.Values) | Measure-Object -Sum).Sum
            failedSteps = [int](@($codes.Values) | Measure-Object -Sum).Sum
            pageProblems = [int](@($tasks | ForEach-Object { $_.pageProblems }) | Measure-Object -Sum).Sum
            planLoops = $replanned.Count; typing = $typing.Count; noAnswer = $noAnswer.Count; errors = $errors.Count
            minutes = [int]$minutes
        }
    }
    # The page.
    [void]$sb.AppendLine('# Session report').AppendLine()
    [void]$sb.AppendLine("- Build: $(if ($Build) { $Build } else { 'unknown' })")
    [void]$sb.AppendLine("- Time: $($first.ToString('yyyy-MM-dd HH:mm')) to $($last.ToString('HH:mm')) ($([int]$minutes) min)")
    [void]$sb.AppendLine("- Tasks: $($tasks.Count), Copilot messages: $((@($tasks | ForEach-Object { $_.messages }) | Measure-Object -Sum).Sum)")
    [void]$sb.AppendLine().AppendLine('## Findings').AppendLine()
    if ($find.Count) { foreach ($f in $find) { [void]$sb.AppendLine("- $f") } } else { [void]$sb.AppendLine('- Nothing out of the ordinary.') }
    [void]$sb.AppendLine().AppendLine('## Tasks').AppendLine()
    [void]$sb.AppendLine('| Time | Kind | Request | Mode | Rounds | Messages | Took | Actions | Notes |').AppendLine('|---|---|---|---|---|---|---|---|---|')
    foreach ($t in $tasks) {
        $took = if ($t.ended -and $t.started) { "$([int]($t.ended - $t.started).TotalSeconds) s" } elseif (-not $t.ended) { 'not finished' } else { '' }
        $acts = (@($t.actions.Keys | Sort-Object | ForEach-Object { "$_ $($t.actions[$_])" })) -join ', '
        $notes = @($t.notes)
        if ($t.failed.Count) { $notes += "failed: $((@($t.failed | Group-Object | ForEach-Object { if ($_.Count -gt 1) { "$($_.Name) x$($_.Count)" } else { $_.Name } })) -join ', ')" }
        if ($t.pageProblems) { $notes += "page problems: $($t.pageProblems)" }
        if ($t.waitMs -ge 60000) { $notes += "waited $([Math]::Round($t.waitMs / 60000, 1)) min for approvals" }
        if ($t.webReads) { $notes += "web reads: $($t.webReads)$(if ($t.webCut) { " ($($t.webCut) cut off)" })" }
        $title = ($t.title -replace '\|', '/' -replace '\s+', ' ').Trim(); if ($title.Length -gt 70) { $title = $title.Substring(0, 67) + '...' }
        [void]$sb.AppendLine("| $($t.queued.ToString('HH:mm:ss')) | $($t.kind)/$($t.source)$(if ($t.taskKind) { " ($($t.taskKind))" }) | $title | $($t.mode) | $($t.rounds) | $($t.messages) | $took | $acts | $(($notes -join '; ')) |")
    }
    if ($codes.Count) {
        [void]$sb.AppendLine().AppendLine('## Failed steps').AppendLine()
        foreach ($c in @($codes.Keys | Sort-Object { -$codes[$_] })) { [void]$sb.AppendLine("- $c x$($codes[$c]): $($codeExample[$c])") }
    }
    $sb.ToString()
}

function New-SessionReportFile {
    <# Writes the report of one run to %LOCALAPPDATA%\CCBridge\reports\session-<stamp>.md (and returns
       its path). $ProcessId 0 = the last run in the log; $LogFile defaults to today's log. #>
    param([string]$LogFile = '', [int]$ProcessId = 0, [string]$OutDir = (Join-Path $env:LOCALAPPDATA 'CCBridge\reports'))
    if (-not $LogFile) { $LogFile = Join-Path (Join-Path $env:LOCALAPPDATA 'CCBridge\logs') ('ccbridge-' + (Get-Date).ToString('yyyyMMdd') + '.log') }
    if (-not (Test-Path -LiteralPath $LogFile)) { throw "No log file at $LogFile" }
    $lines = [IO.File]::ReadAllLines($LogFile)
    if (-not $ProcessId) { $ProcessId = Get-LatestRunId $lines }
    $text = Get-SessionReport (Read-LogEntries $lines $ProcessId)
    $null = New-Item -ItemType Directory -Force -Path $OutDir
    $path = Join-Path $OutDir ("session-$((Get-Date).ToString('yyyyMMdd-HHmmss')).md")
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
    $path
}

Export-ModuleMember -Function Read-LogEntries, Get-LogValue, Get-LatestRunId, Get-SessionReport, New-SessionReportFile
