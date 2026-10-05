# History: one file of a change set before and right after it (Executor Get-ChangeSetFileDiff).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

Describe 'Get-ChangeSetFileDiff' {
    $p = Join-Path $env:TEMP ('ccb-csdiff-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    $write = { param($rel, $text) [IO.File]::WriteAllText((Join-Path $p $rel), $text) }
    $change = {
        param([string[]]$Rels, [scriptblock]$Do)
        Start-Sleep -Milliseconds 20   # change set ids are timestamps
        $cp = New-Checkpoint $p
        foreach ($r in $Rels) { Save-CheckpointFile $cp $p (Join-Path $p $r) }
        & $Do
        $cp.Id
    }
    & $write 'app.js' "a`nb`nc`n"
    $first = & $change @('app.js', 'new.txt') { & $write 'app.js' "a`nB`nc`n"; & $write 'new.txt' "hello`n" }
    $second = & $change @('app.js') { & $write 'app.js' "a`nB`nc`nd`n" }

    It 'shows a change set''s own change, not the later ones' {
        $d = Get-ChangeSetFileDiff $p $first 'app.js'
        $d.old | Should Be "a`nb`nc`n"
        $d.new | Should Be "a`nB`nc`n"      # right after the first change set: kept by the second
        $d.after | Should Be 'later'
        $d.laterId | Should Be $second
        $d.exists | Should Be $true
    }
    It 'compares the newest change set with the file as it is now, and shows created and deleted files' {
        $d = Get-ChangeSetFileDiff $p $second 'app.js'
        $d.old | Should Be "a`nB`nc`n"
        $d.new | Should Be "a`nB`nc`nd`n"
        $d.after | Should Be 'now'
        $n = Get-ChangeSetFileDiff $p $first 'new.txt'
        $n.exists | Should Be $false
        $n.old | Should Be ''
        $n.new | Should Be "hello`n"
        Remove-Item (Join-Path $p 'new.txt')
        (Get-ChangeSetFileDiff $p $first 'new.txt').deleted | Should Be $true
    }
    It 'refuses unknown change sets and files outside the change set' {
        { Get-ChangeSetFileDiff $p '20990101-000000-000' 'app.js' } | Should Throw 'no longer kept'
        { Get-ChangeSetFileDiff $p '../x' 'app.js' } | Should Throw 'not a change set'
        { Get-ChangeSetFileDiff $p $second 'new.txt' } | Should Throw 'not part of change set'
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
