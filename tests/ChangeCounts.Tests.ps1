# Line counts in the Files tab: for the whole session, or only for the last change set.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

Describe 'Line counts per change' {
    $p = Join-Path $env:TEMP ('ccb-counts-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $p | Out-Null
    $start = (Get-Date).AddSeconds(-1).ToString('yyyyMMdd-HHmmss-fff')

    It 'counts every change since the start, or only the last change set' {
        Get-LastChangeSetId $p | Should Be ''
        $cp1 = New-Checkpoint $p 'first'
        $null = Invoke-WriteAction $p 'a.txt' "one`ntwo" $cp1
        Start-Sleep -Milliseconds 20
        $cp2 = New-Checkpoint $p 'second'
        $null = Invoke-WriteAction $p 'b.txt' 'three' $cp2
        $last = Get-LastChangeSetId $p
        $last | Should Be $cp2.Id
        $all = Get-SessionChangeStats $p $start
        @($all.Keys | Sort-Object) -join ',' | Should Be 'a.txt,b.txt'
        $one = Get-SessionChangeStats $p $last
        @($one.Keys) -join ',' | Should Be 'b.txt'
        $one['b.txt'].created | Should Be $true
    }

    It 'adds up every change of one change set in "last change" counts' {
        $cp = New-Checkpoint $p 'two edits'
        $f = Join-Path $p 'c.txt'
        [IO.File]::WriteAllText($f, "a`nb`nc`n")
        $null = Invoke-WriteAction $p 'c.txt' "a`nb`nc`n" $cp
        Add-CheckpointCount $cp 'c.txt' "a`nb`nc`n" "a`nB1`nB2`nc`n"
        [IO.File]::WriteAllText($f, "a`nB1`nB2`nc`n")
        Add-CheckpointCount $cp 'c.txt' "a`nB1`nB2`nc`n" "a`nB1`nX`nc`n"
        [IO.File]::WriteAllText($f, "a`nB1`nX`nc`n")
        # Net against the original: +2 -1; added up per change: +3 -2.
        (Get-SessionChangeStats $p $cp.Id)['c.txt'].added | Should Be 2
        $s = Get-LastChangeStats $p $cp.Id
        $s['c.txt'].added | Should Be 3
        $s['c.txt'].removed | Should Be 2
    }

    It 'shows no "last change" counts from before the project was opened' {
        $opened = (Get-Date).AddSeconds(1).ToString('yyyyMMdd-HHmmss-fff')
        $since = Get-LastChangeStart $p $opened
        $since | Should Be '99999999'
        @((Get-SessionChangeStats $p $since).Keys).Count | Should Be 0
        Get-LastChangeStart $p $start | Should Be (Get-LastChangeSetId $p)
    }
    Remove-Item $p -Recurse -Force
}

Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Describe 'Change set events' {
    It 'carry what asked for them and the lines added and removed per file' {
        $p = Join-Path $env:TEMP ('ccb-cse-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        try {
            $s = New-AgentState -Config ([pscustomobject]@{}) -AppRoot $root; $s.ProjectRoot = $p
            [IO.File]::WriteAllText((Join-Path $p 'a.txt'), "one`n")
            $cp = New-Checkpoint $p 'test'
            $null = Invoke-WriteAction $p 'a.txt' "one`ntwo`nthree`n" $cp
            Add-ChangeSetEvent $s $cp ('Add   two lines ' + ('x' * 200))
            $e = @($s.Events | Where-Object type -eq 'checkpoint')[0]
            $e.title.Length | Should Be 120
            $e.title | Should Match '^Add two lines'
            @($e.files) -join ',' | Should Be 'a.txt'
            $e.counts[0].path | Should Be 'a.txt'
            $e.counts[0].added | Should Be 2
            $e.changeSet | Should Be $cp.Id
        } finally { Remove-Item $p -Recurse -Force }
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
