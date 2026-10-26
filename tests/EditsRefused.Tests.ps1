# An answer-only task that refused Copilot's edits: the next short agreeing reply is a change
# (Get-TaskIntent -Proposal), the card's "Apply these edits" applies the refused edits as written
# (Invoke-AgentTurn -Replay), and "Send again as a change" sends the request as a change (Copilot mocked).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
$env:CCBRIDGE_ISSUE_INDEX = Join-Path $env:TEMP ('ccb-app-index-' + [guid]::NewGuid().ToString('N') + '.json')
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

Describe 'A reply to a proposal' {
    It 'takes a short agreeing reply as approval only after a proposal' {
        foreach ($t in 'sounds good', 'yes', 'ok', 'Perfect!', 'ja', 'that works for me', 'continue') {
            Get-TaskIntent $t '' 'answer' -Proposal | Should Be 'change'
        }
        Get-TaskIntent 'sounds good' '' 'answer' | Should Be 'answer'
        foreach ($t in 'thanks', 'no, not now', 'why that chart?', 'what would it look like', 'laat maar', 'wait') {
            Get-TaskIntent $t '' 'answer' -Proposal | Should Not Be 'change'
        }
        Get-TaskIntent 'yes but do not change anything yet' '' 'answer' -Proposal | Should Be 'investigate'
        Get-TaskIntent 'yes' 'plan' 'answer' -Proposal | Should Be 'investigate'
    }
}

Describe 'Edits refused in an answer-only task' {
    $p = Join-Path $env:TEMP ('ccb-refused-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    [IO.File]::WriteAllText((Join-Path $p 'app.js'), "function a() {`n  return 1;`n}`n")
    $config = Get-CCBridgeConfig harness $root
    $config.pageCheck = 'off'
    Mock -ModuleName Agent Start-NewChat { }
    Mock -ModuleName Agent Send-ToCopilot {
        param($State, [string]$Message)
        $global:ccbSent += , $Message
        $reply = $global:ccbReplies[$global:ccbSent.Count - 1]
        [pscustomobject]@{ Result = 'Success'; Text = $reply; Agent = ''; IsPlan = $false; Uncertain = 0; References = @(); ProposedActions = @(); ActionClaims = @() }
    }
    $fence = '````'
    $edit = "${fence}text`nACTION edit app.js`n####### SEARCH`nreturn 1;`n####### REPLACE`nreturn 2;`n####### END`n$fence"
    $done = '```text' + "`nACTION done`nThe change is ready.`n" + '```'
    $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'

    It 'keeps the refused edits and offers them on a card' {
        $global:ccbSent = @(); $global:ccbReplies = @(($edit + "`n`n" + $done), $done)
        Invoke-AgentTurn $s 'What would make a return 2?'
        ([IO.File]::ReadAllText((Join-Path $p 'app.js'))) | Should Match 'return 1;'
        $card = @($s.Events | Where-Object { $_.type -eq 'edits-refused' })
        $card.Count | Should Be 1
        $card[0].count | Should Be 1
        @($card[0].files) | Should Be 'app.js'
        $card[0].request | Should Be 'What would make a return 2?'
        $s.PendingProposal | Should Be $true
        @($s.Events | Where-Object { $_.type -eq 'plan-ready' }).Count | Should Be 0
    }
    It 'applies them as written without asking Copilot first, then lets Copilot finish' {
        $id = @($s.Events | Where-Object { $_.type -eq 'edits-refused' })[0].replayId
        $global:ccbSent = @(); $global:ccbReplies = @($done)
        Invoke-AgentTurn $s 'What would make a return 2?' -Shown -Intent change -Replay $id
        ([IO.File]::ReadAllText((Join-Path $p 'app.js'))) | Should Match 'return 2;'
        $global:ccbSent.Count | Should Be 1
        $global:ccbSent[0] | Should Match 'The person approved the file changes you wrote earlier'
        $s.RefusedReplay | Should Be $null
    }
    It 'says so when the edits are no longer there' {
        $global:ccbSent = @(); $global:ccbReplies = @()
        Invoke-AgentTurn $s 'What would make a return 2?' -Shown -Intent change -Replay 'gone'
        $global:ccbSent.Count | Should Be 0
        @($s.Events | Select-Object -Last 1)[0].text | Should Match 'no longer available'
        $s.Busy | Should Be $false
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $env:CCBRIDGE_ISSUE_INDEX -Force -ErrorAction SilentlyContinue
$env:CCBRIDGE_ISSUE_INDEX = $null
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
