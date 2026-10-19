# Pester 3.4. The waiting card's status (WorkStatus.psm1): phase, signs of life, counts and the
# activity log, fed by the worker and the chat's events.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\WorkStatus.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

Describe 'Work status' {
    It 'starts with the task, follows the phase and keeps the newest steps' {
        $s = @{ Activity = @{ kind = ''; label = '' } }
        Start-WorkStatus $s 'chat' 'Started: chat task'
        $s.Work.phase | Should Be 'Started: chat task'
        Set-WorkPhase $s "Waiting for Copilot's reply" -Step
        (Get-WorkView $s).phase | Should Be "Waiting for Copilot's reply"
        for ($i = 0; $i -lt 30; $i++) { Add-WorkStep $s "Step $i" }
        $v = Get-WorkView $s
        $v.steps.Count | Should Be 15
        $v.steps[-1].text | Should Be 'Step 29'
        Add-WorkStep $s 'Step 29'
        (Get-WorkView $s).steps.Count | Should Be 15   # the same line twice is one line
        Stop-WorkStatus $s
        Get-WorkView $s | Should BeNullOrEmpty
    }
    It 'shows StreamHub''s own work as the phase while it runs' {
        $s = @{ Activity = @{ kind = 'page'; label = 'Checking index.html in a browser tab' } }
        Start-WorkStatus $s 'chat'
        (Get-WorkView $s).phase | Should Be 'Checking index.html in a browser tab'
    }
    It 'counts actions and changed files from the events, and logs failures and approvals' {
        $s = @{ Activity = @{ kind = ''; label = '' } }
        Start-WorkStatus $s 'chat'
        Update-WorkFromEvent $s 'action' @{ id = 'a1'; action = 'edit'; target = 'app.js'; status = 'running' }
        Update-WorkFromEvent $s 'action-result' @{ id = 'a1'; ok = $true; status = 'done' }
        Update-WorkFromEvent $s 'action' @{ id = 'a2'; action = 'run'; target = 'npm test'; status = 'awaiting' }
        (Get-WorkView $s).phase | Should Be 'Waiting for your approval: Run npm test'
        Update-WorkFromEvent $s 'action-result' @{ id = 'a2'; ok = $false; status = 'rejected' }
        Update-WorkFromEvent $s 'action' @{ id = 'k1'; action = 'write'; target = 'styles/kit/kit.css'; status = 'done'; by = 'streamhub' }
        Update-WorkFromEvent $s 'action' @{ id = 'r1'; action = 'read'; target = 'old.js'; status = 'done'; restored = $true }
        $v = Get-WorkView $s
        $v.actions | Should Be 2
        $v.changed | Should Be 1
        ($v.steps | ForEach-Object { $_.text }) -join '|' | Should Match 'Edit app\.js\|Run npm test\|Waiting for your approval: Run npm test\|Rejected: Run npm test'
    }
    It 'sends the status with the chat''s events from the agent, and nothing without a task' {
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        Add-AgentEvent $s 'assistant' @{ text = 'hi' }
        Get-WorkView $s | Should BeNullOrEmpty
        Start-WorkStatus $s 'chat'
        Add-AgentEvent $s 'assistant' @{ text = 'hi' }
        (Get-WorkView $s).steps[-1].text | Should Be 'Copilot replied'
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
