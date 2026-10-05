# History > Restore: undo a chosen change set and every newer one (Invoke-UndoTask in Agent.psm1).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-test-state-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

Describe 'Restore to before a change set' {
    It 'undoes the chosen change set and every newer one, one undo event each, older ones stay' {
        $p = Join-Path $env:TEMP ('ccb-restore-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Force -Path $p
        $f = Join-Path $p 'app.js'
        [IO.File]::WriteAllText($f, 'v0')
        $ids = @()
        foreach ($v in 'v1', 'v2', 'v3') {
            Start-Sleep -Milliseconds 20   # change sets are ordered by their ids (time stamps)
            $cp = New-Checkpoint $p "to $v"
            Save-CheckpointFile $cp $p $f
            [IO.File]::WriteAllText($f, $v)
            $ids += $cp.Id
        }
        try {
            $s = New-AgentState -Config ([pscustomobject]@{}) -AppRoot $root
            $s.ProjectRoot = $p
            Invoke-UndoTask $s $ids[1]                     # restore to before "to v2"
            [IO.File]::ReadAllText($f) | Should Be 'v1'
            @($s.Events | Where-Object type -eq 'undo').Count | Should Be 2
            Get-LastChangeSetId $p | Should Be $ids[0]      # the older change set stays
            Invoke-UndoTask $s 'gone-id'
            (@($s.Events) | Where-Object type -eq 'error' | Select-Object -Last 1).text | Should Match 'can no longer be undone'
            Invoke-UndoTask $s ''                          # plain Undo: the newest one
            [IO.File]::ReadAllText($f) | Should Be 'v0'
        } finally { Remove-Item $p -Recurse -Force }
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
