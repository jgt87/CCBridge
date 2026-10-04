# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
# Undo also covers what run commands change, and says per file which lines came back or went.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# Project state (backups, chat history) of the test projects goes to a temporary folder, deleted below.
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-test-state-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

Describe 'Undo of changes made by commands' {
    $proj = Join-Path $env:TEMP ('ccb-undo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'src'), (Join-Path $proj 'source')
    $write = { param($rel, $text) [IO.File]::WriteAllText((Join-Path $proj $rel), $text) }
    & $write 'src\app.js' "const a = 1;`nconst b = 2;`n"
    & $write 'notes.txt' "keep me`n"
    & $write 'source\data.csv' "x,y`n"

    It 'puts what a command changed, deleted and created into the change set' {
        $cp = New-Checkpoint $proj 'test'
        $snap = Start-RunSnapshot $cp $proj
        # The "command": changes one file, deletes one, creates one.
        & $write 'src\app.js' "const a = 1;`nconst b = 3;`nconst c = 4;`n"
        [IO.File]::Delete((Join-Path $proj 'notes.txt'))
        & $write 'out.txt' "made by the command`n"
        $done = Complete-RunSnapshot $cp $proj $snap
        (@($done.changed) | Sort-Object) -join ',' | Should Be 'notes.txt,out.txt,src/app.js'
        $cp.Files['src/app.js'] | Should Be 'existed'
        $cp.Files['notes.txt'] | Should Be 'existed'
        $cp.Files['out.txt'] | Should Be 'new'
        $cp.Files.ContainsKey('source/data.csv') | Should Be $false
        Clear-RunSnapshot $cp
        Test-Path (Join-Path $cp.Dir 'prerun') | Should Be $false
        $script:cp = $cp
    }

    It 'undoes it, and says per file which lines came back and which went' {
        $details = @(Undo-LastCheckpoint $proj -Detailed)
        [IO.File]::ReadAllText((Join-Path $proj 'src\app.js')) | Should Be "const a = 1;`nconst b = 2;`n"
        [IO.File]::ReadAllText((Join-Path $proj 'notes.txt')) | Should Be "keep me`n"
        Test-Path (Join-Path $proj 'out.txt') | Should Be $false
        $app = $details | Where-Object path -eq 'src/app.js'
        "$($app.added)/$($app.removed)" | Should Be '1/2'        # "b = 2" back; "b = 3" and "c = 4" gone
        $app.preview.new | Should Be "const a = 1;`nconst b = 2;`n"
        ($details | Where-Object path -eq 'notes.txt').added | Should Be 1
        $out = $details | Where-Object path -eq 'out.txt'
        $out.deleted | Should Be $true
        $out.removed | Should Be 1
    }

    It 'still returns just the file names without -Detailed' {
        $cp = New-Checkpoint $proj 'again'
        $snap = Start-RunSnapshot $cp $proj
        & $write 'notes.txt' "changed`n"
        $null = Complete-RunSnapshot $cp $proj $snap
        Undo-LastCheckpoint $proj | Should Be 'notes.txt'
    }

    It 'leaves a step without file changes out of the change sets' {
        $cp = New-Checkpoint $proj 'nothing'
        $snap = Start-RunSnapshot $cp $proj
        $done = Complete-RunSnapshot $cp $proj $snap
        @($done.changed).Count | Should Be 0
        $cp.Files.Count | Should Be 0
    }

    It 'marks files a step created as new in the Files tab, also an empty one' {
        $since = (Get-Date).AddSeconds(-1).ToString('yyyyMMdd-HHmmss-fff')
        $cp = New-Checkpoint $proj 'new files'
        $snap = Start-RunSnapshot $cp $proj
        & $write 'made.ps1' "line 1`nline 2`n"
        & $write 'blank.txt' ''
        & $write 'notes.txt' "keep me`nand more`n"
        $null = Complete-RunSnapshot $cp $proj $snap
        $stats = Get-SessionChangeStats $proj $since
        "$($stats['made.ps1'].added) $($stats['made.ps1'].created)" | Should Be '2 True'
        $stats['blank.txt'].created | Should Be $true
        "$($stats['notes.txt'].added) $([bool]$stats['notes.txt'].created)" | Should Be '1 False'
        $null = Undo-LastCheckpoint $proj
    }
    It 'removes folders a step created once their files are undone, but keeps folders with other files' {
        $cp = New-Checkpoint $proj 'new folders'
        $snap = Start-RunSnapshot $cp $proj
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $proj 'tools\gen'), (Join-Path $proj 'src\extra')
        & $write 'tools\gen\make.ps1' "x`n"
        & $write 'src\extra\more.js' "y`n"
        $null = Complete-RunSnapshot $cp $proj $snap
        $null = Undo-LastCheckpoint $proj
        Test-Path (Join-Path $proj 'tools') | Should Be $false
        Test-Path (Join-Path $proj 'src\extra') | Should Be $false
        Test-Path (Join-Path $proj 'src\app.js') | Should Be $true
    }
    [IO.Directory]::Delete($proj, $true)
}

if ($env:CCBRIDGE_STATE_ROOT -and (Test-Path -LiteralPath $env:CCBRIDGE_STATE_ROOT)) { [IO.Directory]::Delete($env:CCBRIDGE_STATE_ROOT, $true) }
$env:CCBRIDGE_STATE_ROOT = $null