# Copilot's agents (Researcher, Analyst): who answered, Researcher's plan, and the agent run job.
# The frames below follow the shape recorded from a tenant with the agents (ids replaced).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force

function New-AgentFrames([string]$Origin, [string]$Text, [string]$AgentName) {
    $id = '00000000-0000-0000-0000-000000000000'
    $upd = @{ type = 1; target = 'update'; arguments = @(@{ messages = @(@{ author = 'bot'; text = $Text; contentOrigin = $Origin; messageId = $id; requestId = 'r' }); requestId = 'r' }) }
    $progress = @{ type = 1; target = 'update'; arguments = @(@{ messages = @(@{ author = 'bot'; text = 'Checking sources'; messageType = 'Progress'; contentOrigin = 'ChainOfThoughtSummary'; messageId = '1' }); requestId = 'r' }) }
    $user = @{ author = 'user'; text = 'Compare three generators'; gptIdentifiers = @(@{ id = 'x'; compliantAgentName = $AgentName }) }
    if (-not $AgentName) { $user.Remove('gptIdentifiers') }
    $done = @{ type = 2; invocationId = '0'; item = @{ messages = @($user, @{ author = 'bot'; text = $Text; contentOrigin = $Origin; messageId = $id }); result = @{ value = 'Success' }; conversationId = 'c' } }
    $sep = [string][char]0x1e
    @(($progress | ConvertTo-Json -Depth 8 -Compress) + $sep, ($upd | ConvertTo-Json -Depth 8 -Compress) + $sep, ($done | ConvertTo-Json -Depth 8 -Compress) + $sep)
}

Describe 'Agent replies' {
    It 'names the agent that answered, from the completion record' {
        Get-AgentDisplayName 'ResearcherAgent' | Should BeExactly 'Researcher'
        Get-AgentDisplayName 'analyst' | Should BeExactly 'Analyst'
        $r = Get-ReplyFromFrames (New-AgentFrames 'DeepLeo:researcher-research' '# Report' 'ResearcherAgent')
        $r.Agent | Should BeExactly 'Researcher'
        $r.Text | Should Be '# Report'          # progress lines are not part of the answer
        $r.IsPlan | Should Be $false
        (Get-ReplyFromFrames (New-AgentFrames 'DeepLeo' 'Hi' '')).Agent | Should Be ''
    }
    It 'recognises Researcher''s research plan, which waits for the person' {
        $r = Get-ReplyFromFrames (New-AgentFrames 'DeepLeo:researcher-planning' 'My plan. Which period?' 'ResearcherAgent')
        $r.IsPlan | Should Be $true
        $r.Origin | Should Be 'DeepLeo:researcher-planning'
    }
}

Describe 'Invoke-AgentRun (Copilot mocked)' {
    $p = Join-Path $env:TEMP ('ccb-agent-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    $config = Get-CCBridgeConfig harness $root
    Mock -ModuleName Agent Start-NewChat { $global:ccbNewChats++ }
    Mock -ModuleName Agent Save-AgentCharts { @() }   # needs the Copilot page
    Mock -ModuleName Agent Send-ToCopilot {
        param($State, [string]$Message, [string]$Agent, [switch]$Long)
        $global:ccbSent += , @{ text = $Message; agent = $Agent; long = [bool]$Long }
        $global:ccbReply
    }
    function New-Reply($Text, $Agent, $IsPlan = $false) { [pscustomobject]@{ Result = 'Success'; Text = $Text; Agent = $Agent; IsPlan = $IsPlan; Uncertain = 0; References = @(); ProposedActions = @(); ActionClaims = @() } }

    It 'mentions the agent in a fresh chat, shows its plan and keeps the chat for the answer' {
        $global:ccbSent = @(); $global:ccbNewChats = 0
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p
        $global:ccbReply = New-Reply 'My plan. Which period?' 'Researcher' $true
        Invoke-AgentRun $s 'researcher' 'Compare three generators'
        $global:ccbSent[0].agent | Should Be 'Researcher'
        $global:ccbSent[0].long | Should Be $true
        $global:ccbSent[0].text | Should Be 'Compare three generators'   # sent as typed
        $global:ccbNewChats | Should Be 1
        @($s.Events | Where-Object type -eq 'agent-plan').Count | Should Be 1
        ($s.Events | Where-Object type -eq 'assistant').agent | Should Be 'Researcher'
        $s.AgentChat | Should Be 'Researcher'
        # The answer goes into the same chat, without a new mention.
        $global:ccbReply = New-Reply '# Report' 'Researcher'
        Invoke-AgentRun $s 'researcher' 'Last 12 months' -FollowUp
        $global:ccbSent[1].agent | Should Be ''
        $global:ccbNewChats | Should Be 1
        $s.AgentChat | Should Be $null
        $s.NeedNewChat | Should Be $true
    }
    It 'warns when Copilot itself answered instead of the agent' {
        $global:ccbSent = @(); $global:ccbNewChats = 0
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p
        $global:ccbReply = New-Reply 'An answer' ''
        Invoke-AgentRun $s 'analyst' 'Monthly revenue'
        (@($s.Events | Where-Object type -eq 'status') | Select-Object -Last 1).text | Should Match 'came from Copilot itself, not from Analyst'
    }
    It 'never confirms a Microsoft 365 action an agent proposes' {
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p
        $global:ccbReply = New-Reply 'Draft ready' 'Researcher'; $global:ccbReply.ProposedActions = @(@{ title = 'Send email' })
        Invoke-AgentRun $s 'researcher' 'Mail the team'
        (@($s.Events | Where-Object type -eq 'human-required')).Count | Should Be 1
    }
    Remove-Item $p -Recurse -Force
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
