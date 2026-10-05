# A reply that proposes work instead of doing it becomes a plan to approve and build
# (Protocol Test-ProposalText, Agent Publish-ProposalPlan). The texts are made up.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Protocol.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

$proposal = @"
Proposed Year view:

- Add a fourth toggle button: Day | Week | Month | Year
- Year view shows twelve small month grids
- Clicking a month opens the Month view for it
- Keep the side panels unchanged
"@

Describe 'Test-ProposalText' {
    It 'recognises a proposal heading or proposal words with a list of at least three points' {
        Test-ProposalText $proposal | Should Be $true
        Test-ProposalText "I would suggest the following:`n1. Split the page into parts`n2. Move the data to JSON`n3. Add a loading state" | Should Be $true
        Test-ProposalText "Would you like me to implement this?`n- a filter box`n- a sort button`n- an export link" | Should Be $true
        Test-ProposalText "Mijn voorstel:`n- een filter`n- een sorteerknop`n- een exportknop" | Should Be $true
    }
    It 'leaves summaries of finished work, short lists and code alone' {
        Test-ProposalText "Changed index.html:`n- added the toggle`n- added the grid`n- fixed the header" | Should Be $false
        Test-ProposalText "I suggest one change:`n- rename the button`n- move it left" | Should Be $false
        Test-ProposalText "Here is the code:`n``````js`n// Proposed:`n- a`n- b`n- c`n``````" | Should Be $false
        Test-ProposalText '' | Should Be $false
    }
}

Describe 'Publish-ProposalPlan' {
    $p = Join-Path $env:TEMP ('ccb-prop-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    $config = Get-CCBridgeConfig harness $root
    It 'offers a proposal from a turn that changed nothing as a plan, and writes it to PLAN.md' {
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p
        $from = [int]$s.Seq
        Add-AgentEvent $s 'done' @{ text = $proposal }
        Publish-ProposalPlan $s @{ text = 'Could the calendar get a year view?' } $from | Should Be $true
        $ev = @($s.Events | Where-Object type -eq 'plan-ready')
        $ev.Count | Should Be 1
        $ev[0].plan | Should Match 'Proposed Year view'
        $ev[0].request | Should Be 'Could the calendar get a year view?'
        [IO.File]::ReadAllText((Join-Path $p '.streamhub\PLAN.md')) | Should Match "Copilot's proposal"
    }
    It 'does nothing when the turn changed files or the reply is no proposal' {
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p
        $from = [int]$s.Seq
        Add-AgentEvent $s 'checkpoint' @{ id = 'x'; files = @('index.html') }
        Add-AgentEvent $s 'done' @{ text = $proposal }
        Publish-ProposalPlan $s @{ text = 'Add a year view' } $from | Should Be $false
        $s2 = New-AgentState -Config $config -AppRoot $root; $s2.ProjectRoot = $p
        Add-AgentEvent $s2 'done' @{ text = 'The page loads its data from data/example.json.' }
        Publish-ProposalPlan $s2 @{ text = 'Where does the data come from?' } 0 | Should Be $false
        @($s.Events + $s2.Events | Where-Object type -eq 'plan-ready').Count | Should Be 0
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
