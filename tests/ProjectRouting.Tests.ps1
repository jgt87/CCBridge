# Project identity belongs to a queued task, and cannot change while it runs.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$base = Join-Path $env:TEMP ('ccb-routing-' + [guid]::NewGuid().ToString('N'))
$env:CCBRIDGE_STATE_ROOT = Join-Path $base 'state'
foreach ($m in 'Agent', 'Server', 'Workspace', 'Executor') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }
$a = Join-Path $base 'a'; $b = Join-Path $base 'b'
$null = New-Item -ItemType Directory -Force -Path $a, $b

function Test-GateAvailable($Gate) {
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript({ param($g) $ok = [Threading.Monitor]::TryEnter($g); if ($ok) { [Threading.Monitor]::Exit($g) }; $ok }).AddArgument($Gate)
        [bool]($ps.Invoke()[0])
    } finally { $ps.Dispose() }
}

Describe 'Project capture in the queue' {
    It 'captures the project for every kind of project work, independently of later caller changes' {
        foreach ($kind in 'chat', 'agent', 'fetch', 'runbook', 'chain', 'script', 'review', 'packages', 'undo', 'export', 'testrun-report') {
            $s = New-AgentState -Config @{} -AppRoot $root; $s.ProjectRoot = $a
            $request = @{ kind = $kind; text = 'test' }
            $entry = Submit-AgentTask $s $request
            $s.ProjectRoot = $b; $request.projectRoot = $b
            $task = $null; $null = $s.Tasks.TryDequeue([ref]$task)
            $task.projectRoot | Should Be $a
            $entry.task.projectRoot | Should Be $a
            $entry.projectRoot | Should Be $a
        }
    }
    It 'keeps an explicit project and restores older queue entries of all project kinds' {
        $file = Join-Path $base 'queue.json'
        $s = New-AgentState -Config @{} -AppRoot $root; $s.ProjectRoot = $a; $s.QueueFile = $file
        foreach ($kind in 'chat', 'runbook', 'undo', 'packages', 'agent', 'export') {
            $entry = Submit-AgentTask $s @{ kind = $kind; projectRoot = $b }
            $entry.task.projectRoot | Should Be $b
            $entry.task.Remove('projectRoot')   # queue written by an older version
        }
        Save-AgentQueue $s
        $restored = New-AgentState -Config @{} -AppRoot $root; $restored.QueueFile = $file
        Restore-AgentQueue $restored | Should Be 6
        $task = $null
        while ($restored.Tasks.TryDequeue([ref]$task)) { $task.projectRoot | Should Be $b }
    }
}

Describe 'Worker project routing' {
    Mock -ModuleName Agent Initialize-CCBLog { }
    Mock -ModuleName Agent Invoke-DueSchedules { }
    Mock -ModuleName Agent Reset-Bridge { }
    Mock -ModuleName Agent Sync-ProtectedVault { }
    Mock -ModuleName Agent Invoke-ProjectRetention { }
    Mock -ModuleName Agent Sync-DataMirrors { }
    Mock -ModuleName Agent Publish-PackagesNeeded { }
    Mock -ModuleName Agent Invoke-ProjectHooks { }
    Mock -ModuleName Agent Write-TurnPlan { }
    Mock -ModuleName Agent Publish-ProposalPlan { }
    Mock -ModuleName Agent Save-AgentQueue {
        param($State)
        if ($State.Queue.Count -and $State.Queue[0].status -in 'done', 'failed') { $State.Stop = $true }
    }
    Mock -ModuleName Agent Invoke-AgentTurn {
        param($State, $Text)
        $State.TestGateHeld = [Threading.Monitor]::IsEntered($State.ProjectGate)
        [IO.File]::WriteAllText((Join-Path $State.ProjectRoot 'task.txt'), $Text)
    }

    It 'runs a queued write in its captured project and restores the selected project' {
        $s = New-AgentState -Config @{} -AppRoot $root; $s.ProjectRoot = $a; $s.Headless = $true
        $null = Submit-AgentTask $s @{ kind = 'chat'; text = 'for project a'; noRunbook = $true }
        $s.ProjectRoot = $b
        Start-AgentWorker $s
        [IO.File]::ReadAllText((Join-Path $a 'task.txt')) | Should Be 'for project a'
        Test-Path -LiteralPath (Join-Path $b 'task.txt') | Should Be $false
        $s.TestGateHeld | Should Be $true
        $s.ProjectRoot | Should Be $b
        Test-GateAvailable $s.ProjectGate | Should Be $true
    }
    It 'undoes the explicit MCP project, not the project open in the app' {
        foreach ($p in $a, $b) {
            $f = Join-Path $p 'undo.txt'; [IO.File]::WriteAllText($f, 'original')
            $cp = New-Checkpoint $p 'routing test'; Save-CheckpointFile $cp $p $f
            [IO.File]::WriteAllText($f, 'changed')
        }
        $s = New-AgentState -Config @{} -AppRoot $root; $s.ProjectRoot = $a; $s.Headless = $true
        $null = Submit-AgentTask $s @{ kind = 'undo'; projectRoot = $b; source = 'mcp' } 'mcp'
        Start-AgentWorker $s
        [IO.File]::ReadAllText((Join-Path $a 'undo.txt')) | Should Be 'changed'
        [IO.File]::ReadAllText((Join-Path $b 'undo.txt')) | Should Be 'original'
        $s.ProjectRoot | Should Be $a
        Test-GateAvailable $s.ProjectGate | Should Be $true
    }
    It 'refuses a removed project without falling back to the open project' {
        $s = New-AgentState -Config @{} -AppRoot $root; $s.ProjectRoot = $a; $s.Headless = $true
        $entry = Submit-AgentTask $s @{ kind = 'undo'; projectRoot = (Join-Path $base 'missing') }
        Start-AgentWorker $s
        $entry.status | Should Be 'failed'
        [IO.File]::ReadAllText((Join-Path $a 'undo.txt')) | Should Be 'changed'
        $s.ProjectRoot | Should Be $a
        Test-GateAvailable $s.ProjectGate | Should Be $true
    }
    It 'does not give a task submitted without a project a later opened project' {
        $s = New-AgentState -Config @{} -AppRoot $root; $s.Headless = $true
        $entry = Submit-AgentTask $s @{ kind = 'chat'; text = 'no project'; noRunbook = $true }
        $s.ProjectRoot = $b
        Start-AgentWorker $s
        $entry.status | Should Be 'failed'
        $entry.error | Should Match 'Open or create a project first'
        Test-Path -LiteralPath (Join-Path $b 'task.txt') | Should Be $false
        $s.ProjectRoot | Should Be $b
        Test-GateAvailable $s.ProjectGate | Should Be $true
    }
    It 'restores the project and releases the gate even when task cleanup throws' {
        Mock -ModuleName Agent Sync-DataMirrors { throw 'cleanup failed' }
        $s = New-AgentState -Config @{} -AppRoot $root; $s.ProjectRoot = $b; $s.Headless = $true
        $null = Submit-AgentTask $s @{ kind = 'chat'; projectRoot = $a; text = 'cleanup test'; noRunbook = $true }
        { Start-AgentWorker $s } | Should Throw 'cleanup failed'
        $s.ProjectRoot | Should Be $b
        Test-GateAvailable $s.ProjectGate | Should Be $true
    }
}

Describe 'Opening projects safely' {
    It 'refuses a switch while busy without changing any project state' {
        $s = New-AgentState -Config @{} -AppRoot $root; $s.ProjectRoot = $a; $s.Busy = $true
        { & (Get-Module Server) { param($s, $p) Set-Project $s $p } $s $b } | Should Throw 'A task is still running in a. Wait for it to finish or press Stop'
        $s.ProjectRoot | Should Be $a
        $s.Events.Count | Should Be 0
        # For the page an answer, not an error with an id: it waits for the person.
        $busy = & (Get-Module Server) { param($s, $p) try { Set-Project $s $p } catch { Get-ProjectSwitchBusy $s $_ $p } } $s $b
        $busy.ok | Should Be $false
        $busy.busy | Should Be 'task'
        $busy.retry | Should Be $false
        Test-GateAvailable $s.ProjectGate | Should Be $true
    }
    It 'refuses a switch while another runspace owns the project, even between busy phases' {
        $s = New-AgentState -Config @{} -AppRoot $root; $s.ProjectRoot = $a
        $ready = New-Object Threading.ManualResetEvent($false)
        $release = New-Object Threading.ManualResetEvent($false)
        $ps = [powershell]::Create()
        try {
            [void]$ps.AddScript({ param($g, $ready, $release)
                [Threading.Monitor]::Enter($g)
                try { [void]$ready.Set(); [void]$release.WaitOne(10000) } finally { [Threading.Monitor]::Exit($g) }
            }).AddArgument($s.ProjectGate).AddArgument($ready).AddArgument($release)
            $handle = $ps.BeginInvoke()
            $ready.WaitOne(5000) | Should Be $true
            # The worker getting the open project ready: told to stop at its next step, and the page
            # gets a note to show while it tries again by itself.
            $busy = & (Get-Module Server) { param($s, $p) try { Set-Project $s $p } catch { Get-ProjectSwitchBusy $s $_ $p } } $s $b
            $busy.busy | Should Be 'preparing'
            $busy.retry | Should Be $true
            $busy.message | Should Be 'Opening b as soon as StreamHub has finished getting a ready (its data copies, UI kit and pages are brought up to date after it opens).'
            $s.SwitchWanted | Should Be $true
            $s.ProjectRoot | Should Be $a
            # Any other error stays an error.
            & (Get-Module Server) { param($s) try { throw 'Folder not found' } catch { Get-ProjectSwitchBusy $s $_ 'x' } } $s | Should BeNullOrEmpty
        } finally { [void]$release.Set(); if ($handle) { $null = $ps.EndInvoke($handle) }; $ps.Dispose(); $ready.Dispose(); $release.Dispose() }
        Test-GateAvailable $s.ProjectGate | Should Be $true
    }
    It 'shows both versions of a nested file after layout migration' {
        Mock -ModuleName Server Invoke-ProjectRetention { }
        Mock -ModuleName Server Publish-PackagesNeeded { }
        Mock -ModuleName Server Read-ChatHistory { @{ type = 'user' } }
        Mock -ModuleName Server Reset-StaleIssueFixes { }
        Mock -ModuleName Server Sync-ProjectSchedules { }
        Mock -ModuleName Server Start-IssueIndexer { $true }
        $p = Join-Path $base 'migration'
        $local = Join-Path $base 'local'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $p 'exports'), (Join-Path $p 'src'), (Join-Path $local 'CCBridge')
        [IO.File]::WriteAllText((Join-Path $p 'exports\data.json'), '{}')
        [IO.File]::WriteAllText((Join-Path $p 'src\app.js'), "fetch('../exports/data.json');")
        $s = New-AgentState -Config @{} -AppRoot $root
        $wasLocal = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $local
            & (Get-Module Server) { param($s, $p) Set-Project $s $p } $s $p
        } finally { $env:LOCALAPPDATA = $wasLocal }
        $card = @($s.Events | Where-Object { $_.type -eq 'action' -and $_.target -eq 'src/app.js' })[0]
        $card.preview.old | Should Be "fetch('../exports/data.json');"
        $card.preview.new | Should Be "fetch('../Runbooks/Exports/data.json');"
        Test-GateAvailable $s.ProjectGate | Should Be $true
    }
}

$resolvedBase = [IO.Path]::GetFullPath($base)
if ($resolvedBase.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\ccb-routing-', [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolvedBase -Recurse -Force }
$env:CCBRIDGE_STATE_ROOT = $null
