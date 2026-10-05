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
        Selectors = [pscustomobject]@{ stopButton = 'button.stop' }; AttachErrors = @(); SaveFrames = $false; PageCheckMs = 200; PageStableSec = 1.0; Pacing = @{ lateReplySec = 0 } }

    It 'waits past the reply limit while the Stop button shows, up to the cap, then stops' {
        $global:ccbStops = 0
        Mock -ModuleName CopilotBridge Get-PageReplyState { [pscustomobject]@{ fresh = 0; lastFresh = $false; replies = 1; copies = 0; stop = $true; lastLen = 10; lastHasCopy = $false; bar = ''; agentBusy = $false } }
        $w = [Diagnostics.Stopwatch]::StartNew()
        $err = $null
        try { $null = Send-CopilotPrompt $bridge 'hello' -TimeoutSec 1 -MaxTimeoutSec 4 -StallSec 0 } catch { $err = $_.Exception.Message }
        $err | Should Match 'No complete reply within [3-5] s'
        $w.Elapsed.TotalSeconds | Should BeGreaterThan 3.5
        $global:ccbStops | Should Be 1
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
        $err | Should Match 'No complete reply'
    }
    It 'still calls a request lost when the page shows nothing at all' {
        Mock -ModuleName CopilotBridge Get-PageReplyState { [pscustomobject]@{ fresh = 0; lastFresh = $false; replies = 1; copies = 0; stop = $false; lastLen = 0; lastHasCopy = $false; bar = ''; agentBusy = $false } }
        $r = & (Get-Module CopilotBridge) { param($b) Send-CopilotPromptUnlocked -Bridge $b -Text 'hello' -TimeoutSec 10 -MaxTimeoutSec 10 -StallSec 0 -LostSec 1 } $bridge
        $r.Result | Should Be 'Lost'
    }
}
