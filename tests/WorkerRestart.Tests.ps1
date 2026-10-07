# The task worker stopping unexpectedly (Server restarts it): the running task is marked failed,
# the busy state and live views are cleared, and an error card says what happened.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Agent', 'Config', 'Server') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

Describe 'After the task worker stopped' {
    It 'marks the running task failed, clears the busy state and says so' {
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $null = Submit-AgentTask $s @{ kind = 'chat'; text = 'Make the header sticky' } 'user' 'Make the header sticky'
        $null = Submit-AgentTask $s @{ kind = 'chat'; text = 'Next one' } 'user' 'Next one'
        $s.Queue[0].status = 'running'
        $s.Busy = $true; $s.Activity.label = 'Checking js/app.js'; $s.RunLive = @{ id = 'x' }
        $failed = @(Reset-AfterWorkerStop $s 'Object reference not set to an instance of an object')
        $failed.Count | Should Be 1
        $s.Queue[0].status | Should Be 'failed'
        $s.Queue[0].error | Should Match "task worker stopped while this task was running \(Object reference"
        $s.Queue[1].status | Should Be 'queued'
        $s.Busy | Should Be $false
        $s.Activity.label | Should Be ''
        $s.RunLive | Should BeNullOrEmpty
        $card = @(Get-AgentEvents $s 0 | Where-Object { $_.type -eq 'error' })[-1]
        $card.code | Should Be 'WORKER-RESTART'
        $card.text | Should Match 'stopped unexpectedly and was restarted: Object reference .* \(Make the header sticky\) was stopped and marked failed'
    }
    It 'names why the worker ended' {
        $ps = [powershell]::Create()
        [void]$ps.AddScript('throw "worker broke"')
        try { $ps.Invoke() } catch { }
        & (Get-Module Server) { param($w) Get-WorkerStopReason $w } $ps | Should Match 'worker broke'
        $ps.Dispose()
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
