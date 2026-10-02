# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force

Describe 'Submit-AgentTask' {
    $config = Get-CCBridgeConfig harness $root
    $state = New-AgentState -Config $config -AppRoot $root

    It 'records the task in the queue and hands it to the worker' {
        $e = Submit-AgentTask $state @{ kind = 'chat'; text = "fix   the`nbutton" } 'mcp'
        $e.status | Should Be 'queued'
        $e.source | Should Be 'mcp'
        $e.title | Should Be 'fix the button'
        $task = $null
        $state.Tasks.TryDequeue([ref]$task) | Should Be $true
        $task.queueId | Should Be $e.id
    }

    It 'finds an entry by queue id or job id' {
        $e = Submit-AgentTask $state @{ kind = 'ask'; text = 'hi'; jobId = 'job-1234abcd' } 'mcp'
        (Get-QueueEntry $state $e.id).id | Should Be $e.id
        (Get-QueueEntry $state 'job-1234abcd').id | Should Be $e.id
    }

    It 'keeps the last 100 entries' {
        1..105 | ForEach-Object { $null = Submit-AgentTask $state @{ kind = 'newchat' } 'user' }
        $state.Queue.Count | Should Be 100
    }
}

Describe 'Get-ChangeSetContents (review by the calling program)' {
    $proj = Join-Path $env:TEMP ('ccb-test-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $proj
    [IO.File]::WriteAllText((Join-Path $proj 'a.txt'), "one`ntwo`n")
    [IO.File]::WriteAllText((Join-Path $proj 'same.txt'), "x`n")

    It 'returns old and new contents of changed and created files, not unchanged ones' {
        $cp = New-Checkpoint $proj
        & (Get-Module Executor) { param($p, $k) foreach ($n in 'a.txt', 'same.txt', 'b.txt') { Save-CheckpointFile $k $p (Join-Path $p $n) } } $proj $cp
        [IO.File]::WriteAllText((Join-Path $proj 'a.txt'), "one`nTWO`n")
        [IO.File]::WriteAllText((Join-Path $proj 'b.txt'), "new`n")
        $c = @(Get-ChangeSetContents $proj $cp)
        @($c).Count | Should Be 2
        $a = $c | Where-Object { $_.path -eq 'a.txt' }
        $a.old | Should Be "one`ntwo`n"
        $a.new | Should Be "one`nTWO`n"
        ($c | Where-Object { $_.path -eq 'b.txt' }).created | Should Be $true
    }

    Remove-Item $proj -Recurse -Force -ErrorAction SilentlyContinue
}
