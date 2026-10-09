# Data copies: a JS file that only wraps a JSON file's data follows that JSON (lib/DataMirror.psm1).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\DataMirror.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Review.psm1') -Force

function Add-File($p, $rel, $text) { $full = Join-Path $p $rel; New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null; [IO.File]::WriteAllText($full, $text) }
function New-MirrorProject {
    $p = Join-Path $env:TEMP ('ccb-mirror-' + [guid]::NewGuid().ToString('N'))
    Add-File $p 'data\calendar-data.json' '{"meetings":[{"title":"Standup","minutes":15}]}'
    Add-File $p 'calendar-data.js' "window.calendarData = {""meetings"":[{""title"":""Standup"",""minutes"":30}]};`n"   # differs: 30
    Add-File $p 'js\people.js' "const people = [""Ann""];"                                                          # no JSON named people
    Add-File $p 'app.js' "window.app = {}; console.log('not data only');"
    Add-File $p 'index.html' '<script src="calendar-data.js"></script>'
    $p
}

Describe 'Read-DataWrapper' {
    It 'recognises a file that only wraps JSON data, and nothing else' {
        (Read-DataWrapper 'window.x = {"a":1};').name | Should Be 'x'
        (Read-DataWrapper "// note`nconst list = [1,2]").decl | Should Be 'const '
        (Read-DataWrapper "// Generated from data/x.json by the helper program. Do not edit.`nwindow.x = {};").source | Should Be 'data/x.json'
        Read-DataWrapper "window.x = {}; console.log(1);" | Should Be $null
        Read-DataWrapper "window.x = function () {};" | Should Be $null
        Read-DataWrapper "window.x = {a: 1};" | Should Be $null    # not JSON (unquoted key): left alone
    }
}

Describe 'Update-DataMirrors' {
    It 'rewrites a copy that differs from its JSON, marks it, and keeps the old version in a change set' {
        $p = New-MirrorProject
        try {
            @(Find-DataMirrors $p | ForEach-Object { "$($_.js)<-$($_.json)" }) -join ',' | Should Be 'calendar-data.js<-data/calendar-data.json'
            $r = Update-DataMirrors $p
            $r.items[0].status | Should Be 'updated'
            $r.items[0].differed | Should Be $true
            $text = [IO.File]::ReadAllText((Join-Path $p 'calendar-data.js'))
            $text | Should Match '^// Generated from data/calendar-data\.json by the helper program'
            $text | Should Match 'window\.calendarData = \{"meetings":\[\{"title":"Standup","minutes":15\}\]\};'
            $r.checkpoint.Files.Keys -contains 'calendar-data.js' | Should Be $true
            [IO.File]::ReadAllText((Join-Path $p 'app.js')) | Should Match 'not data only'               # other scripts untouched
            @((Update-DataMirrors $p).items).Count | Should Be 0                                          # up to date: nothing to do
            # The JSON changes (a runbook ran): the copy follows.
            [IO.File]::WriteAllText((Join-Path $p 'data\calendar-data.json'), '{"meetings":[]}')
            (Update-DataMirrors $p).items[0].status | Should Be 'updated'
            [IO.File]::ReadAllText((Join-Path $p 'calendar-data.js')) | Should Match 'window\.calendarData = \{"meetings":\[\]\};'
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'only marks a copy that already matches, and reports an invalid or missing source' {
        $p = New-MirrorProject
        try {
            [IO.File]::WriteAllText((Join-Path $p 'calendar-data.js'), "window.calendarData = {""meetings"":[{""title"":""Standup"",""minutes"":15}]};")
            (Update-DataMirrors $p).items[0].status | Should Be 'marked'
            [IO.File]::WriteAllText((Join-Path $p 'data\calendar-data.json'), '{ not json')
            $r = Update-DataMirrors $p
            $r.items[0].status | Should Be 'invalid-source'
            @(Format-DataMirrorNotes $r)[0] | Should Match 'not valid JSON'
            Remove-Item (Join-Path $p 'data\calendar-data.json')
            (Update-DataMirrors $p).items[0].status | Should Be 'missing-source'
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'refuses Copilot''s edits to a copy, and code review skips it' {
        $p = New-MirrorProject
        try {
            $null = Update-DataMirrors $p
            { Invoke-WriteAction $p 'calendar-data.js' 'window.calendarData = {};' $null } | Should Throw 'change data/calendar-data.json'
            { Invoke-WriteAction $p 'app.js' 'window.app = {}; // changed' $null } | Should Not Throw
            $files = (Get-ReviewFiles $p).files
            $files -contains 'calendar-data.js' | Should Be $false
            $files -contains 'app.js' | Should Be $true
        } finally { Remove-Item $p -Recurse -Force }
    }
}
Describe 'Sync-DataMirrors' {
    It 'shows a rewritten copy in the chat as a write card with its diff, by StreamHub' {
        Import-Module (Join-Path $root 'lib\Config.psm1') -Force
        Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
        $p = New-MirrorProject
        try {
            $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p
            Sync-DataMirrors $s
            $evts = @($s.Events)
            $card = @($evts | Where-Object { $_.type -eq 'action' })[0]
            $card.action | Should Be 'write'
            $card.by | Should Be 'streamhub'
            $card.target | Should Match '^calendar-data\.js \(data copy of data/calendar-data\.json\)'
            $card.preview.old | Should Match '"minutes":30'
            $card.preview.new | Should Match '"minutes":15'
            $done = @($evts | Where-Object { $_.type -eq 'action-result' -and $_.id -eq $card.id })[0]
            $done.status | Should Be 'ok'
            $done.changed | Should Be $true
            @($evts | Where-Object { $_.type -eq 'checkpoint' }).Count | Should Be 1
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'does nothing with the setting turned off, and copies are then ordinary files' {
        $p = New-MirrorProject
        try {
            Mock -ModuleName Agent Test-DataCopiesOn { $false }
            Mock -ModuleName Executor Test-DataCopiesOn { $false }
            Mock -ModuleName Review Test-DataCopiesOn { $false }
            $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p
            Sync-DataMirrors $s
            @($s.Events).Count | Should Be 0
            [IO.File]::ReadAllText((Join-Path $p 'calendar-data.js')) | Should Match '"minutes":30'
            [IO.File]::WriteAllText((Join-Path $p 'calendar-data.js'), "// Generated from data/calendar-data.json by the helper program. Do not edit.`nwindow.calendarData = {};")
            { Invoke-WriteAction $p 'calendar-data.js' 'window.calendarData = {"a":1};' $null } | Should Not Throw
            (Get-ReviewFiles $p).files -contains 'calendar-data.js' | Should Be $true
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'converts a data file only when asked (-Import), never because a project opened or a task ended' {
        $p = Join-Path $env:TEMP ('ccb-mirror-' + [guid]::NewGuid().ToString('N'))
        Add-File $p 'sales.csv' "region,amount`nNorth,120`n"
        try {
            $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p
            Sync-DataMirrors $s
            Test-Path (Join-Path $p 'data') | Should Be $false
            Sync-DataMirrors $s -Import
            Test-Path (Join-Path $p 'data\sales.json') | Should Be $true
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'opens a project at once: Set-Project leaves the data work to the idle worker' {
        Import-Module (Join-Path $root 'lib\Server.psm1') -Force
        $od = Join-Path $env:TEMP ('ccb-mirror-' + [guid]::NewGuid().ToString('N'))
        Add-File $od 'sales.csv' "region,amount`nNorth,120`n"
        # Set-Project records the project StreamHub opens next time: kept as it was.
        $last = Join-Path $env:LOCALAPPDATA 'CCBridge\last-project.txt'
        $lastText = if (Test-Path -LiteralPath $last) { [IO.File]::ReadAllText($last) } else { $null }
        try {
            $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
            & (Get-Module Server) { param($st, $path) Set-Project $st $path } $s $od
            $s.OpenSync | Should Be $od
            Test-Path (Join-Path $od 'data') | Should Be $false
        } finally {
            Remove-Item $od -Recurse -Force
            if ($null -ne $lastText) { [IO.File]::WriteAllText($last, $lastText) } else { Remove-Item -LiteralPath $last -ErrorAction SilentlyContinue }
        }
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
