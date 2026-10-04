# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# Project state (backups, chat history) of the test projects goes to a temporary folder, deleted below.
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-test-state-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

Describe 'Queue across restarts (Save-AgentQueue / Restore-AgentQueue)' {
    $config = Get-CCBridgeConfig harness $root
    $file = Join-Path $env:TEMP ('ccb-queue-' + [guid]::NewGuid().ToString('N') + '.json')

    It 'keeps history, queues waiting tasks again and fails the one that was running' {
        $a = New-AgentState -Config $config -AppRoot $root
        $a.QueueFile = $file
        $a.ProjectRoot = 'C:\Projects\demo'
        $done = Submit-AgentTask $a @{ kind = 'chat'; text = 'first' } 'user'
        $run = Submit-AgentTask $a @{ kind = 'chat'; text = 'second' } 'user'
        $wait = Submit-AgentTask $a @{ kind = 'chat'; text = 'third'; jobId = 'job-0000abcd'; projectRoot = 'C:\Projects\other'; mode = 'plan'; source = 'mcp' } 'mcp'
        $done.status = 'done'; $done.summary = 'ok'; $done.changed = @('a.txt')
        $run.status = 'running'
        Save-AgentQueue $a
        ([IO.File]::ReadAllText($file)) | Should Not Match '"text":"first"'

        $b = New-AgentState -Config $config -AppRoot $root
        $b.QueueFile = $file
        Restore-AgentQueue $b | Should Be 1
        $b.Queue.Count | Should Be 3
        (Get-QueueEntry $b $done.id).status | Should Be 'done'
        @((Get-QueueEntry $b $done.id).changed) -join ',' | Should Be 'a.txt'
        (Get-QueueEntry $b $run.id).status | Should Be 'failed'
        (Get-QueueEntry $b $run.id).error | Should Match 'stopped while this task was running'
        $task = $null
        $b.Tasks.TryDequeue([ref]$task) | Should Be $true
        $task.text | Should Be 'third'
        $task.queueId | Should Be $wait.id
        $task.mode | Should Be 'plan'
        $task.projectRoot | Should Be 'C:\Projects\other'
        $b.Jobs['job-0000abcd'].status | Should Be 'queued'
    }

    It 'does nothing without a queue file (the MCP server''s own engine)' {
        $s = New-AgentState -Config $config -AppRoot $root
        $null = Submit-AgentTask $s @{ kind = 'newchat' } 'user'
        Restore-AgentQueue $s | Should Be 0
    }

    Remove-Item $file -Force -ErrorAction SilentlyContinue
}

if ($env:CCBRIDGE_STATE_ROOT -and (Test-Path -LiteralPath $env:CCBRIDGE_STATE_ROOT)) { [IO.Directory]::Delete($env:CCBRIDGE_STATE_ROOT, $true) }
$env:CCBRIDGE_STATE_ROOT = $null