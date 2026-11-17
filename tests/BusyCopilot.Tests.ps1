# Pressing Stop while Copilot is still working cancels its work (a long Microsoft 365 task was
# cancelled this way at the 5-minute reply limit). At the limit the reply loop waits on while the
# page still shows Stop, up to MaxTimeoutSec. Copilot's page and connection are mocked.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force

Describe 'Send-CopilotPrompt keeps waiting while Copilot is busy' {
    Mock -ModuleName CopilotBridge Set-PageReplyBaseline { }
    Mock -ModuleName CopilotBridge Set-CopilotInput { }
    Mock -ModuleName CopilotBridge Invoke-CopilotSend { }
    Mock -ModuleName CopilotBridge Wait-Pacing { }
    Mock -ModuleName CopilotBridge Receive-CdpEvent { Start-Sleep -Milliseconds 100; $null }
    Mock -ModuleName CopilotBridge Test-CopilotGaveUp { $false }
    Mock -ModuleName CopilotBridge Stop-CopilotReply { $global:ccbStops++; 'stopped' }
    Mock -ModuleName CopilotBridge Get-PageReplyText { [pscustomobject]@{ how = 'none'; text = ''; parts = 0 } }
    $bridge = [pscustomobject]@{ Session = [pscustomobject]@{ Events = New-Object System.Collections.Queue; Ws = $null; Lost = $false }
        Selectors = [pscustomobject]@{ stopButton = 'button.stop'; chatUrl = 'https://www.microsoft365.com/chat'; chatHosts = @('m365.cloud.microsoft') }; AttachErrors = @(); SaveFrames = $false; PageCheckMs = 200; PageStableSec = 1.0; Pacing = @{ lateReplySec = 0 } }
    # The tab's address when the bridge asks for it (location.href).
    Mock -ModuleName CopilotBridge Invoke-CdpEval { 'https://m365.cloud.microsoft/chat/conversation/abc123?auth=2#top' }

    It 'waits past the reply limit while the Stop button shows, up to the cap, then leaves Copilot running with its chat kept' {
        $global:ccbStops = 0
        Mock -ModuleName CopilotBridge Get-PageReplyState { [pscustomobject]@{ fresh = 0; lastFresh = $false; replies = 1; copies = 0; stop = $true; lastLen = 10; lastHasCopy = $false; bar = ''; agentBusy = $false } }
        $w = [Diagnostics.Stopwatch]::StartNew()
        $err = $null
        try { $null = Send-CopilotPrompt $bridge 'hello' -TimeoutSec 1 -MaxTimeoutSec 4 -StallSec 0 } catch { $err = $_.Exception.Message }
        $err | Should Match '^Copilot is still working after 1 min\. .*left it running'
        $w.Elapsed.TotalSeconds | Should BeGreaterThan 3.5
        $global:ccbStops | Should Be 0   # Stop would cancel Copilot's work
        $bridge.PendingChat.address | Should Be 'https://m365.cloud.microsoft/chat/conversation/abc123'   # no query or fragment
        $bridge.PendingChat.since | Should Not BeNullOrEmpty
        $bridge.PSObject.Properties.Remove('PendingChat')
    }
    It 'stops at the reply limit when Copilot no longer shows that it is working' {
        $global:ccbStops = 0
        Mock -ModuleName CopilotBridge Get-PageReplyState { [pscustomobject]@{ fresh = 0; lastFresh = $false; replies = 1; copies = 0; stop = $false; lastLen = 10; lastHasCopy = $false; bar = ''; agentBusy = $false } }
        $w = [Diagnostics.Stopwatch]::StartNew()
        $err = $null
        try { $null = Send-CopilotPrompt $bridge 'hello' -TimeoutSec 1 -MaxTimeoutSec 4 -StallSec 0 } catch { $err = $_.Exception.Message }
        $err | Should Match 'No complete reply within [12] s'
        $w.Elapsed.TotalSeconds | Should BeLessThan 3.5
    }
    It 'never calls a request lost (and sends it again) while the page shows Copilot at work' {
        $global:ccbStops = 0
        Mock -ModuleName CopilotBridge Get-PageReplyState { [pscustomobject]@{ fresh = 0; lastFresh = $false; replies = 1; copies = 0; stop = $true; lastLen = 0; lastHasCopy = $false; bar = ''; agentBusy = $false } }
        $r = $null; $err = $null
        try { $r = & (Get-Module CopilotBridge) { param($b) Send-CopilotPromptUnlocked -Bridge $b -Text 'hello' -TimeoutSec 3 -MaxTimeoutSec 3 -StallSec 0 -LostSec 1 } $bridge } catch { $err = $_.Exception.Message }
        if ($r) { $r.Result | Should Not Be 'Lost' }
        $err | Should Match 'Copilot is still working'
        $global:ccbStops | Should Be 0
        $bridge.PSObject.Properties.Remove('PendingChat')
    }
    It 'still calls a request lost when the page shows nothing at all' {
        Mock -ModuleName CopilotBridge Get-PageReplyState { [pscustomobject]@{ fresh = 0; lastFresh = $false; replies = 1; copies = 0; stop = $false; lastLen = 0; lastHasCopy = $false; bar = ''; agentBusy = $false } }
        $r = & (Get-Module CopilotBridge) { param($b) Send-CopilotPromptUnlocked -Bridge $b -Text 'hello' -TimeoutSec 10 -MaxTimeoutSec 10 -StallSec 0 -LostSec 1 } $bridge
        $r.Result | Should Be 'Lost'
    }
}

Describe 'A chat left running: its address and reading its answer later' {
    $sel = [pscustomobject]@{ chatUrl = 'https://www.microsoft365.com/chat'; chatHosts = @('m365.cloud.microsoft') }
    It 'keeps https, a Copilot host and the path only, and refuses anything else' {
        ConvertTo-CopilotChatAddress 'https://M365.cloud.microsoft/chat/conversation/x1?code=secret#y' $sel | Should Be 'https://m365.cloud.microsoft/chat/conversation/x1'
        ConvertTo-CopilotChatAddress 'https://www.microsoft365.com/chat' $sel | Should Be 'https://www.microsoft365.com/chat'
        ConvertTo-CopilotChatAddress 'http://m365.cloud.microsoft/chat' $sel | Should Be $null
        ConvertTo-CopilotChatAddress 'https://login.microsoftonline.com/common/oauth2' $sel | Should Be $null
        ConvertTo-CopilotChatAddress 'https://m365.cloud.microsoft.evil.example/chat' $sel | Should Be $null
        ConvertTo-CopilotChatAddress 'not a url' $sel | Should Be $null
        ConvertTo-CopilotChatAddress '' $sel | Should Be $null
    }

    Mock -ModuleName CopilotBridge Use-CopilotLock { & $Body }
    Mock -ModuleName CopilotBridge Wait-CopilotEditor { $true }
    Mock -ModuleName CopilotBridge Invoke-Cdp { $global:ccbNavigated = $Params.url; $null }
    $bridge = [pscustomobject]@{ Session = [pscustomobject]@{ Lost = $false }; Selectors = [pscustomobject]@{ chatUrl = 'https://www.microsoft365.com/chat'; chatHosts = @('m365.cloud.microsoft') } }

    It 'opens the chat when the tab is elsewhere, and reads the last answer once Copilot is done' {
        $global:ccbNavigated = $null
        Mock -ModuleName CopilotBridge Invoke-CdpEval { 'https://m365.cloud.microsoft/chat' }
        Mock -ModuleName CopilotBridge Get-PageReplyState { [pscustomobject]@{ stop = $false; agentBusy = $false } }
        Mock -ModuleName CopilotBridge Get-PageReplyText { [pscustomobject]@{ how = 'state'; text = 'The report is ready.'; parts = 1 } }
        $r = Read-CopilotChatAnswer -Bridge $bridge -Address 'https://m365.cloud.microsoft/chat/conversation/abc123' -WaitSec 0
        $global:ccbNavigated | Should Be 'https://m365.cloud.microsoft/chat/conversation/abc123'
        $r.busy | Should Be $false
        $r.text | Should Be 'The report is ready.'
    }
    It 'stays on the chat when the tab shows it, and says when Copilot is still at work' {
        $global:ccbNavigated = $null
        Mock -ModuleName CopilotBridge Invoke-CdpEval { 'https://m365.cloud.microsoft/chat/conversation/abc123?x=1' }
        Mock -ModuleName CopilotBridge Get-PageReplyState { [pscustomobject]@{ stop = $false; agentBusy = $true } }
        $r = Read-CopilotChatAnswer -Bridge $bridge -Address 'https://m365.cloud.microsoft/chat/conversation/abc123' -WaitSec 0
        $global:ccbNavigated | Should Be $null
        $r.busy | Should Be $true
        $r.text | Should Be ''
    }
    It 'never opens an address that is not a Copilot chat' {
        { Read-CopilotChatAnswer -Bridge $bridge -Address 'https://evil.example/chat' } | Should Throw 'Not a Copilot chat address'
    }
}

Describe 'The length the message box should show (Get-TypedLength)' {
    It 'leaves out line breaks and the zero-width characters the box measurement leaves out' {
        # Seen: a prompt with text copied from Microsoft pages (zero-width spaces in it) was refused as
        # "message box holds 75010 characters, expected 75024".
        $zw = [string][char]0x200B
        Get-TypedLength "ab${zw}c`r`nd" | Should Be 4
        Get-TypedLength ("x" * 10 + ([string][char]0x200C) * 3) | Should Be 10
        Get-TypedLength '' | Should Be 0
    }
}
