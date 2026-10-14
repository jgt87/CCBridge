# Deterministic task context and progress accounting. No model calls.
$ErrorActionPreference = 'Stop'

function Format-TaskMessage {
    <# Mandatory blocks are atomic. Optional context/output uses both ends of the remaining
       budget, so a command's final error is not lost. Never silently shorten a requirement. #>
    param([string]$Message, [string[]]$Required, [int]$Max)
    $blocks = @($Required | Where-Object { "$_".Trim() } | Select-Object -Unique)
    $optional = $Message
    foreach ($block in $blocks) { $optional = $optional.Replace($block, '') }
    $essential = $blocks -join "`n`n"
    if ($essential.Length + 2 -gt $Max) {
        throw "The request and required instructions exceed the message budget ($Max characters). Shorten the request or project instructions, or increase the prompt size in Settings. Nothing was sent with requirements cut off."
    }
    $room = $Max - $essential.Length - 2
    $mark = "`n[Optional context/output shortened in the middle. Use read ranges or grep for omitted content.]`n"
    if ($optional.Length -gt $room) {
        if ($room -lt $mark.Length) { $optional = '' }
        else {
            $keep = $room - $mark.Length
            $head = [int][Math]::Floor($keep / 2)
            $optional = $optional.Substring(0, $head) + $mark + $optional.Substring($optional.Length - ($keep - $head))
        }
    }
    ($essential + "`n`n" + $optional).Trim()
}

function Test-RoundProgress {
    <# A new successful observation counts once, including test results. Repeating the same
       action with identical output does not buy more rounds. Real file changes always count. #>
    param($Actions, $Results, $Seen)
    $progress = $false
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        for ($i = 0; $i -lt @($Results).Count; $i++) {
            $r = @($Results)[$i]
            if ($r.changedPath) { $progress = $true }
            $action = if ($r.action) { $r.action } elseif ($i -lt @($Actions).Count) { @($Actions)[$i] } else { $null }
            if ((-not $r.ok -and $action.type -ne 'run') -or -not "$($r.output)".Trim()) { continue }
            if ($action -and $action.type -notin 'read', 'glob', 'grep', 'find', 'run', 'web', 'sql') { continue }
            $observed = if ($r.ContainsKey('observation')) { "$($r.observation)" } else { "$($r.output)" }
            $key = "$($action.type)`n$($action.arg)`n$($action.body)`n$($observed.TrimEnd())"
            $hash = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key)))
            if ($Seen.Add($hash)) { $progress = $true }
        }
    } finally { $sha.Dispose() }
    $progress
}

function Save-TaskRecord {
    <# Local state, never a project file or shared with OneDrive. Full requirements are separate
       from the model's summary of its execution history. #>
    param([string]$Directory, $Record)
    $path = Join-Path $Directory 'task-record.json'
    [IO.File]::WriteAllText($path, ($Record | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    $path
}

Export-ModuleMember -Function Format-TaskMessage, Test-RoundProgress, Save-TaskRecord
