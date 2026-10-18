# Project progress across chats: after every work task the helper program writes down, by fixed
# rules, what was asked, how it ended, which files changed, the Done when checks not met, the
# project's own check and the to-do items left. The newest entries go into the project context, so
# a new Copilot chat (New chat, a restart of the app) knows what earlier chats did. Local state
# (progress.jsonl in the project's state folder), never OneDrive: requests can hold Microsoft 365
# data. No model: only what the task record already holds.
# ASCII only (Windows PowerShell 5.1).

$ErrorActionPreference = 'Stop'

$script:MaxEntries = 50

function Get-ProgressPath([string]$StateDir) { Join-Path $StateDir 'progress.jsonl' }

function Get-OneLine([AllowEmptyString()][string]$Text, [int]$Max) {
    # The text on one line, cut at $Max characters.
    $t = ("$Text" -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3).TrimEnd() + '...' }
    $t
}

function New-ProgressEntry {
    <# One entry from a finished task: @{ when; status; request; result; changed; more; unmet;
       verify; open }. $Verify is the task's evidence ($ev.verify): passed / failed / skipped. #>
    param([string]$Request, [string]$Status, [string]$Result, [string[]]$Changed, $Acceptance, $Verify, $Todos, [string]$Kind = '')
    $files = @(@($Changed) | Where-Object { $_ } | Sort-Object)
    $unmet = @(@($Acceptance) | Where-Object { $_ -and $_.met -eq $false } | ForEach-Object { Get-OneLine "$($_.check)" 120 })
    $vf = if (-not $Verify) { '' } elseif ($Verify.skipped) { 'not run' } elseif ($Verify.passed) { 'passed' } elseif ($Verify.preexisting) { 'failed as before the task' } else { 'failed' }
    $open = @(@($Todos) | Where-Object { $_ -and -not $_.done } | ForEach-Object { Get-OneLine "$($_.text)" 100 } | Select-Object -First 5)
    # The first line of the result is enough: the files are the truth.
    $first = @("$Result".Replace("`r`n", "`n").Split("`n") | Where-Object { $_.Trim() -and $_ -notmatch '^\s*(#+|```)' }) | Select-Object -First 1
    @{
        when = (Get-Date).ToString('yyyy-MM-dd HH:mm'); status = $Status; kind = $Kind
        request = Get-OneLine $Request 240; result = Get-OneLine "$first" 200
        changed = @($files | Select-Object -First 12); more = [Math]::Max(0, $files.Count - 12)
        unmet = $unmet; verify = $vf; open = $open
    }
}

function Add-ProgressEntry([string]$StateDir, [hashtable]$Entry) {
    # Appended as one JSON line; only the newest $script:MaxEntries are kept.
    $p = Get-ProgressPath $StateDir
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $p) { foreach ($l in [IO.File]::ReadAllLines($p)) { if ($l.Trim()) { $lines.Add($l) } } }
    $lines.Add(($Entry | ConvertTo-Json -Depth 5 -Compress))
    $keep = @($lines | Select-Object -Last $script:MaxEntries)
    [IO.File]::WriteAllText($p, (($keep -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}

function Read-ProgressEntries([string]$StateDir, [int]$Last = 5) {
    # The newest entries, oldest first; a line that does not read is skipped.
    $p = Get-ProgressPath $StateDir
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($l in [IO.File]::ReadAllLines($p)) {
        if (-not $l.Trim()) { continue }
        try { $out.Add(($l | ConvertFrom-Json)) } catch { }
    }
    @($out.ToArray() | Select-Object -Last $Last)
}

function Clear-ProgressEntries([string]$StateDir) {
    $p = Get-ProgressPath $StateDir
    if (Test-Path -LiteralPath $p) { [IO.File]::Delete($p) }
}

function Format-ProgressContext($Entries, [int]$MaxChars = 2500) {
    <# The project-context block: one line per earlier task, newest last, within $MaxChars (the
       oldest go first). '' when there are none. #>
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($Entries)) {
        if (-not $e) { continue }
        $s = "- $($e.when), $($e.status): $($e.request)"
        if ($e.result) { $s += " Result: $($e.result)" }
        $ch = @($e.changed | Where-Object { $_ })
        if ($ch.Count) { $s += " Changed: $($ch -join ', ')$(if ([int]$e.more -gt 0) { " and $($e.more) more" })." }
        if (@($e.unmet | Where-Object { $_ }).Count) { $s += " Checks not met: $(@($e.unmet) -join '; ')." }
        if ($e.verify) { $s += " Project check: $($e.verify)." }
        if (@($e.open | Where-Object { $_ }).Count) { $s += " Still open: $(@($e.open) -join '; ')." }
        $lines.Add($s)
    }
    if (-not $lines.Count) { return '' }
    $head = 'Earlier work in this project (kept by the helper program from earlier tasks, newest last; the files are the truth, read them before relying on this):'
    while ($lines.Count -gt 1 -and ($head.Length + ($lines | Measure-Object -Property Length -Sum).Sum + $lines.Count) -gt $MaxChars) { $lines.RemoveAt(0) }
    $head + "`n" + ($lines -join "`n")
}

Export-ModuleMember -Function Get-ProgressPath, New-ProgressEntry, Add-ProgressEntry, Read-ProgressEntries, Clear-ProgressEntries, Format-ProgressContext
