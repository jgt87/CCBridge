# Retention: how much of what StreamHub generates per project is kept (Settings > Retention).
#   .streamhub/History/ earlier versions of runbook and fetch data, per runbook or fetch prompt
#   .streamhub/evidence/ one file per task
#   .streamhub/reviews/ code review reports (NAME.md and NAME.json count as one)
#   undo backups        change sets in %LOCALAPPDATA%\CCBridge\projects\...\backups (the newest
#                       one always stays, so "Undo last change set" keeps working)
# Per item: keep the newest COUNT and nothing older than DAYS (0 = no limit). Runs when a project
# opens and after each task. Only these generated files are ever removed: never Source/, Logs/ or
# any other file of the project.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Workspace', 'Layout') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:Defaults = [ordered]@{
    historyCount = 20; historyDays = 90
    evidenceCount = 100; evidenceDays = 90
    reviewsCount = 20; reviewsDays = 180
    backupsCount = 100; backupsDays = 30
}

function Get-RetentionSettings($Config) {
    # The retention numbers from the settings (harness "retention"), defaults where unset.
    $out = [ordered]@{}
    foreach ($k in $script:Defaults.Keys) {
        $v = $null
        if ($Config -and $Config.retention) { $v = if ($Config.retention -is [hashtable]) { $Config.retention[$k] } else { $Config.retention.$k } }
        $out[$k] = if ($null -ne $v -and "$v" -match '^\d+$') { [int]$v } else { [int]$script:Defaults[$k] }
    }
    $out
}

function Select-Expired {
    <# Of one group (newest first by Time), the items to remove: past the newest $Count, or older
       than $Days. $KeepNewest keeps the newest item whatever its age. #>
    param($Items, [int]$Count, [int]$Days, [switch]$KeepNewest, [datetime]$Now = (Get-Date))
    $sorted = @($Items | Sort-Object Time -Descending)
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        if ($KeepNewest -and $i -eq 0) { continue }
        if (($Count -gt 0 -and $i -ge $Count) -or ($Days -gt 0 -and $sorted[$i].Time -lt $Now.AddDays(-$Days))) { $sorted[$i] }
    }
}

function Remove-RetentionItem($Item) {
    foreach ($p in @($Item.Paths)) {
        try {
            if (Test-Path -LiteralPath $p -PathType Container) {
                Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
                [IO.Directory]::Delete($p, $true)
            } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
                (Get-Item -LiteralPath $p -Force).Attributes = 'Normal'
                [IO.File]::Delete($p)
            }
        } catch { Write-CCBLog verbose retention "Could not remove $p`: $($_.Exception.Message)" }
    }
}

function Invoke-ProjectRetention {
    <# Applies the retention settings to one project. Returns what was removed per item. -WhatIf
       only reports. $Now is for tests. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, $Config, [switch]$WhatIf, [datetime]$Now = (Get-Date))
    $r = Get-RetentionSettings $Config
    $removed = [ordered]@{ history = 0; evidence = 0; reviews = 0; backups = 0 }
    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { return $removed }
    $apply = { param($kind, $items) foreach ($x in @($items)) { if (-not $WhatIf) { Remove-RetentionItem $x }; $removed[$kind]++ } }

    # History/: per runbook or fetch prompt (NAME-yyyyMMdd-HHmmss.ext).
    $hist = Join-Path $ProjectRoot ((Get-LayoutPath History).Replace('/', '\'))
    if (Test-Path -LiteralPath $hist) {
        $files = @(Get-ChildItem -LiteralPath $hist -File | ForEach-Object { [pscustomobject]@{ Group = ($_.Name -replace '-\d{8}-\d{6}(\.[^.]+)$', ''); Time = $_.LastWriteTime; Paths = @($_.FullName) } })
        foreach ($g in ($files | Group-Object Group)) { & $apply 'history' (Select-Expired $g.Group $r.historyCount $r.historyDays -Now $Now) }
    }
    # evidence/: one file per task.
    $ev = Join-Path $ProjectRoot ((Get-LayoutPath Evidence).Replace('/', '\'))
    if (Test-Path -LiteralPath $ev) {
        $files = @(Get-ChildItem -LiteralPath $ev -File -Filter 'task-*.md' | ForEach-Object { [pscustomobject]@{ Time = $_.LastWriteTime; Paths = @($_.FullName) } })
        & $apply 'evidence' (Select-Expired $files $r.evidenceCount $r.evidenceDays -Now $Now)
    }
    # reviews/: NAME.md and NAME.json are one report.
    $rv = Join-Path $ProjectRoot ((Get-LayoutPath Reviews).Replace('/', '\'))
    if (Test-Path -LiteralPath $rv) {
        $reports = @(Get-ChildItem -LiteralPath $rv -File | Where-Object { $_.Extension -in '.md', '.json' } | Group-Object BaseName | ForEach-Object {
            [pscustomobject]@{ Time = ($_.Group | Measure-Object LastWriteTime -Maximum).Maximum; Paths = @($_.Group | ForEach-Object FullName) } })
        & $apply 'reviews' (Select-Expired $reports $r.reviewsCount $r.reviewsDays -Now $Now)
    }
    # Undo backups: change sets by their id (yyyyMMdd-HHmmss-fff); the newest one always stays.
    $bk = Join-Path (Get-ProjectStateDir $ProjectRoot) 'backups'
    if (Test-Path -LiteralPath $bk) {
        $sets = @(Get-ChildItem -LiteralPath $bk -Directory | ForEach-Object {
            $t = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($_.Name.Substring(0, [Math]::Min(15, $_.Name.Length)), 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$t)) { $t = $_.LastWriteTime }
            [pscustomobject]@{ Time = $t; Paths = @($_.FullName) } })
        & $apply 'backups' (Select-Expired $sets $r.backupsCount $r.backupsDays -KeepNewest -Now $Now)
    }
    $total = ($removed.Values | Measure-Object -Sum).Sum
    if ($total -and -not $WhatIf) { Write-CCBLog info retention "Removed old generated items" @{ project = $ProjectRoot; history = $removed.history; evidence = $removed.evidence; reviews = $removed.reviews; backups = $removed.backups } }
    $removed
}

function Invoke-StateRetention {
    <# At instance start, for every project's state folder in %LOCALAPPDATA% (also projects that
       are not opened any more): undo change sets (count and days; the newest stays) and the chat
       history (the newest chatEvents events). Returns @{ backups; chatEvents }. $StateRoot is for tests. #>
    param($Config, [string]$StateRoot = '', [datetime]$Now = (Get-Date))
    $base = if ($StateRoot) { $StateRoot } elseif ($env:CCBRIDGE_STATE_ROOT) { $env:CCBRIDGE_STATE_ROOT } else { Join-Path $env:LOCALAPPDATA 'CCBridge\projects' }
    $r = Get-RetentionSettings $Config
    $keepEvents = 1500
    if ($Config -and $Config.retention) { $v = if ($Config.retention -is [hashtable]) { $Config.retention['chatEvents'] } else { $Config.retention.chatEvents }; if ("$v" -match '^\d+$' -and [int]$v -ge 100) { $keepEvents = [int]$v } }
    $out = [ordered]@{ backups = 0; chatEvents = 0 }
    if (-not (Test-Path -LiteralPath $base)) { return $out }
    foreach ($dir in Get-ChildItem -LiteralPath $base -Directory) {
        $bk = Join-Path $dir.FullName 'backups'
        if (Test-Path -LiteralPath $bk) {
            $sets = @(Get-ChildItem -LiteralPath $bk -Directory | ForEach-Object {
                $t = [datetime]::MinValue
                if (-not [datetime]::TryParseExact($_.Name.Substring(0, [Math]::Min(15, $_.Name.Length)), 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$t)) { $t = $_.LastWriteTime }
                [pscustomobject]@{ Time = $t; Paths = @($_.FullName) } })
            foreach ($x in @(Select-Expired $sets $r.backupsCount $r.backupsDays -KeepNewest -Now $Now)) { Remove-RetentionItem $x; $out.backups++ }
        }
        $chat = Join-Path $dir.FullName 'chat-history.jsonl'
        if (Test-Path -LiteralPath $chat) {
            $lines = @([IO.File]::ReadAllLines($chat) | Where-Object { $_.Trim() })
            if ($lines.Count -gt $keepEvents) {
                [IO.File]::WriteAllLines($chat, [string[]]@($lines | Select-Object -Last $keepEvents), (New-Object Text.UTF8Encoding($false)))
                $out.chatEvents += $lines.Count - $keepEvents
            }
        }
    }
    if ($out.backups -or $out.chatEvents) { Write-CCBLog info retention 'Cleaned the project state folders at start' @{ backups = $out.backups; chatEvents = $out.chatEvents } }
    $out
}

Export-ModuleMember -Function Get-RetentionSettings, Select-Expired, Invoke-ProjectRetention, Invoke-StateRetention
