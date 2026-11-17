# A chat Copilot was left running in at the time cap (Agent Resolve-PendingChat, Start-NewChat,
# Send-ToCopilot): its answer is read into the transcript once Copilot is done, a new request is
# refused while Copilot still works, and the person's New chat leaves it running. The bridge is mocked.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-pending-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

Describe 'Resolve-PendingChat' {
    Mock -ModuleName Agent Get-Bridge { [pscustomobject]@{ Session = $null } }
    $config = Get-CCBridgeConfig harness $root
    function New-PendingState {
        $s = New-AgentState -Config $config -AppRoot $root
        $s.PendingChat = [pscustomobject]@{ address = 'https://m365.cloud.microsoft/chat/conversation/abc123'; since = '2026-11-17T10:42:00'; waitedSec = 1800 }
        $s
    }
    $resolve = { param($st, [switch]$Button) & (Get-Module Agent) { param($x, $b) Resolve-PendingChat $x -FromButton:$b } $st $Button }

    It 'reads the answer into the transcript once Copilot is done, and continues that chat from Read the answer' {
        Mock -ModuleName Agent Read-CopilotChatAnswer { @{ busy = $false; text = 'Here is the summary of the three meetings.'; how = 'state' } }
        $s = New-PendingState
        $s.NeedNewChat = $true
        & $resolve $s -Button
        $s.PendingChat | Should Be $null
        @($s.Events | Where-Object { $_.type -eq 'assistant' -and $_.text -eq 'Here is the summary of the three meetings.' }).Count | Should Be 1
        @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -match 'answer to the earlier request \(sent at 10:42\), read from its chat\.$' }).Count | Should Be 1
        $s.NeedNewChat | Should Be $false
    }

    It 'says that changes in that answer were not carried out' {
        Mock -ModuleName Agent Read-CopilotChatAnswer { $f = '```'; @{ busy = $false; text = "Done.`n`n${f}text`nACTION write notes.md`nhello`n$f`n"; how = 'state' } }
        $s = New-PendingState
        & $resolve $s -Button
        @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -match 'were not carried out' }).Count | Should Be 1
    }

    It 'from Read the answer, says Copilot is still at work and keeps the chat' {
        Mock -ModuleName Agent Read-CopilotChatAnswer { @{ busy = $true; text = ''; how = '' } }
        $s = New-PendingState
        & $resolve $s -Button
        $s.PendingChat | Should Not Be $null
        @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -match 'still working on the earlier request \(sent at 10:42\)\. Try Read the answer again later' }).Count | Should Be 1
        @($s.Events | Where-Object type -eq 'assistant').Count | Should Be 0
    }

    It 'refuses a new request while Copilot still works, and a New chat leaves it running' {
        Mock -ModuleName Agent Read-CopilotChatAnswer { @{ busy = $true; text = ''; how = '' } }
        Mock -ModuleName Agent New-CopilotChat { $global:ccbNewChats++ }
        $global:ccbNewChats = 0
        $s = New-PendingState
        { & $resolve $s } | Should Throw 'Wait until it is done and use Read the answer, or start a New chat'
        { & (Get-Module Agent) { param($x) Start-NewChat $x } $s } | Should Throw 'still working'
        $global:ccbNewChats | Should Be 0
        & (Get-Module Agent) { param($x) Start-NewChat $x -Force } $s
        $global:ccbNewChats | Should Be 1
        $s.PendingChat | Should Not Be $null   # Read the answer can still open it later
    }

    It 'reads a finished answer before a new chat is opened, so it is not lost' {
        Mock -ModuleName Agent Read-CopilotChatAnswer { @{ busy = $false; text = 'Finished analysis.'; how = 'state' } }
        Mock -ModuleName Agent New-CopilotChat { }
        $s = New-PendingState
        & (Get-Module Agent) { param($x) Start-NewChat $x } $s
        $s.PendingChat | Should Be $null
        @($s.Events | Where-Object { $_.type -eq 'assistant' -and $_.text -eq 'Finished analysis.' }).Count | Should Be 1
    }

    It 'without an address, reads the page the tab still shows' {
        Mock -ModuleName Agent Get-PageReplyState { [pscustomobject]@{ stop = $false; agentBusy = $false } }
        Mock -ModuleName Agent Get-PageReplyText { [pscustomobject]@{ how = 'state'; text = 'Answer on the page.'; parts = 1 } }
        $s = New-PendingState
        $s.PendingChat.address = $null
        & $resolve $s -Button
        @($s.Events | Where-Object { $_.type -eq 'assistant' -and $_.text -eq 'Answer on the page.' }).Count | Should Be 1
    }

    It 'says so when nothing is waiting' {
        $s = New-AgentState -Config $config -AppRoot $root
        & $resolve $s -Button
        @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -match 'no answer left to read' }).Count | Should Be 1
    }
}

Remove-Item -Recurse -Force $env:CCBRIDGE_STATE_ROOT -ErrorAction SilentlyContinue
$env:CCBRIDGE_STATE_ROOT = $null
