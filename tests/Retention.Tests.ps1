# Retention: History/, evidence/, reviews/ and undo backups keep the newest N and nothing older
# than D days (0 = no limit); the newest change set always stays; other files are never touched.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Retention.psm1') -Force
Import-Module (Join-Path $root 'lib\Workspace.psm1') -Force

function New-RetentionProject {
    $p = Join-Path $env:TEMP ('ccb-ret-' + [guid]::NewGuid().ToString('N'))
    foreach ($d in '.streamhub\History', '.streamhub\Evidence', '.streamhub\Reviews', 'Logs', 'Source') { New-Item -ItemType Directory (Join-Path $p $d) -Force | Out-Null }
    $p
}
function Add-Aged($Path, [int]$DaysOld) { [IO.File]::WriteAllText($Path, 'x'); (Get-Item $Path).LastWriteTime = (Get-Date).AddDays(-$DaysOld) }

Describe 'Select-Expired' {
    $items = 0..4 | ForEach-Object { [pscustomobject]@{ Time = (Get-Date).AddDays(-$_ * 10); Paths = @("p$_") } }
    It 'keeps the newest N and drops what is older than D days' {
        @(Select-Expired $items 3 0 | ForEach-Object { $_.Paths[0] }) -join ',' | Should Be 'p3,p4'
        @(Select-Expired $items 0 25 | ForEach-Object { $_.Paths[0] }) -join ',' | Should Be 'p3,p4'
        @(Select-Expired $items 0 0).Count | Should Be 0
        @(Select-Expired $items 0 1 -KeepNewest | ForEach-Object { $_.Paths[0] }) -join ',' | Should Be 'p1,p2,p3,p4'
    }
}

Describe 'Invoke-ProjectRetention' {
    It 'cleans History per item, evidence and reviews, and leaves other files alone' {
        $p = New-RetentionProject
        foreach ($i in 1..4) { Add-Aged (Join-Path $p ".streamhub\History\meetings-2026100$i-080000.json") (4 - $i) }
        Add-Aged (Join-Path $p '.streamhub\History\prices-20260101-080000.md') 200
        foreach ($i in 1..3) { Add-Aged (Join-Path $p ".streamhub\Evidence\task-2026100$i-080000.md") (3 - $i) }
        foreach ($i in 1..3) { Add-Aged (Join-Path $p ".streamhub\Reviews\r$i.md") (3 - $i); Add-Aged (Join-Path $p ".streamhub\Reviews\r$i.json") (3 - $i) }
        Add-Aged (Join-Path $p 'Logs\old.log') 900
        Add-Aged (Join-Path $p 'source\data.csv') 900
        $cfg = @{ retention = @{ historyCount = 2; historyDays = 90; evidenceCount = 1; evidenceDays = 0; reviewsCount = 2; reviewsDays = 0; backupsCount = 0; backupsDays = 0 } }
        $r = Invoke-ProjectRetention $p $cfg
        $r.history | Should Be 3          # two oldest meetings versions, and prices (older than 90 days)
        $r.evidence | Should Be 2
        $r.reviews | Should Be 1          # one report = its .md and .json
        @(Get-ChildItem (Join-Path $p '.streamhub\History')).Count | Should Be 2
        Test-Path (Join-Path $p '.streamhub\Reviews\r1.md') | Should Be $false
        Test-Path (Join-Path $p '.streamhub\Reviews\r1.json') | Should Be $false
        Test-Path (Join-Path $p 'Logs\old.log') | Should Be $true
        Test-Path (Join-Path $p 'source\data.csv') | Should Be $true
        Remove-Item $p -Recurse -Force
    }
    It 'keeps the newest undo change set however old, and reports only with -WhatIf' {
        $p = New-RetentionProject
        $bk = Join-Path (Get-ProjectStateDir $p) 'backups'
        foreach ($id in '20250101-080000-000', '20250201-080000-000', '20250301-080000-000') { New-Item -ItemType Directory (Join-Path $bk $id) -Force | Out-Null }
        $cfg = @{ retention = @{ backupsCount = 0; backupsDays = 30 } }
        (Invoke-ProjectRetention $p $cfg -WhatIf).backups | Should Be 2
        @(Get-ChildItem $bk -Directory).Count | Should Be 3
        (Invoke-ProjectRetention $p $cfg).backups | Should Be 2
        @(Get-ChildItem $bk -Directory | ForEach-Object Name) -join ',' | Should Be '20250301-080000-000'
        Remove-Item $p -Recurse -Force
    }
    It 'cleans every project state folder at start: undo change sets and chat history' {
        $base = Join-Path $env:TEMP ('ccb-stateroot-' + [guid]::NewGuid().ToString('N'))
        foreach ($proj in 'a-1', 'b-2') {
            foreach ($id in '20250101-080000-000', '20250201-080000-000') { New-Item -ItemType Directory (Join-Path $base "$proj\backups\$id") -Force | Out-Null }
        }
        [IO.File]::WriteAllLines((Join-Path $base 'a-1\chat-history.jsonl'), [string[]](1..250 | ForEach-Object { "{`"seq`":$_}" }))
        $r = Invoke-StateRetention @{ retention = @{ backupsCount = 0; backupsDays = 30; chatEvents = 100 } } -StateRoot $base
        $r.backups | Should Be 2
        $r.chatEvents | Should Be 150
        @(Get-ChildItem (Join-Path $base 'a-1\backups') -Directory).Count | Should Be 1
        @([IO.File]::ReadAllLines((Join-Path $base 'a-1\chat-history.jsonl'))).Count | Should Be 100
        [IO.File]::ReadAllLines((Join-Path $base 'a-1\chat-history.jsonl'))[0] | Should Be '{"seq":151}'
        Remove-Item $base -Recurse -Force
    }
    It 'keeps saved charts per item, counts the charts of one answer as one, and leaves exports alone' {
        $p = New-RetentionProject
        $ex = Join-Path $p 'Runbooks\Exports'; New-Item -ItemType Directory $ex -Force | Out-Null
        try {
            foreach ($i in 1..3) { Add-Aged (Join-Path $ex "sales-chart-2026100$i-080000.png") (3 - $i) }
            Add-Aged (Join-Path $ex 'analyst-chart-20261001-090000-1.png') 1
            Add-Aged (Join-Path $ex 'analyst-chart-20261001-090000-2.png') 1    # same answer as -1
            Add-Aged (Join-Path $ex 'analyst-chart-20260101-090000.png') 200    # older than the days limit
            Add-Aged (Join-Path $ex 'sales.json') 400                           # an export: never touched
            Add-Aged (Join-Path $ex 'my-chart.png') 400                         # not StreamHub's name pattern
            $cfg = @{ retention = @{ chartsCount = 2; chartsDays = 90; historyCount = 0; historyDays = 0; evidenceCount = 0; evidenceDays = 0; reviewsCount = 0; reviewsDays = 0; backupsCount = 0; backupsDays = 0 } }
            $r = Invoke-ProjectRetention $p $cfg
            $r.charts | Should Be 2
            Test-Path (Join-Path $ex 'sales-chart-20261001-080000.png') | Should Be $false   # the oldest of three, count 2
            Test-Path (Join-Path $ex 'sales-chart-20261003-080000.png') | Should Be $true
            Test-Path (Join-Path $ex 'analyst-chart-20261001-090000-1.png') | Should Be $true
            Test-Path (Join-Path $ex 'analyst-chart-20261001-090000-2.png') | Should Be $true
            Test-Path (Join-Path $ex 'analyst-chart-20260101-090000.png') | Should Be $false
            Test-Path (Join-Path $ex 'sales.json') | Should Be $true
            Test-Path (Join-Path $ex 'my-chart.png') | Should Be $true
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'uses the defaults when the settings have none' {
        (Get-RetentionSettings $null).historyCount | Should Be 20
        (Get-RetentionSettings @{ retention = @{ historyCount = 5 } }).historyCount | Should Be 5
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
