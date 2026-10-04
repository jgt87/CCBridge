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

    It 'shows no "last change" counts from before the project was opened' {
        $opened = (Get-Date).AddSeconds(1).ToString('yyyyMMdd-HHmmss-fff')
        $since = Get-LastChangeStart $p $opened
        $since | Should Be '99999999'
        @((Get-SessionChangeStats $p $since).Keys).Count | Should Be 0
        Get-LastChangeStart $p $start | Should Be (Get-LastChangeSetId $p)
    }
    Remove-Item $p -Recurse -Force
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
