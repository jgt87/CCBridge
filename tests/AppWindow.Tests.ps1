# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
# Where the StreamHub app opens, and that its tab is never taken for Copilot.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\AppWindow.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force

Describe 'Test-LocalPageUrl' {
    It 'recognises StreamHub and page-check tabs' {
        Test-LocalPageUrl 'http://localhost:8765/' 8765 | Should Be $true
        Test-LocalPageUrl 'http://127.0.0.1:8765/preview/abc/index.html' 8765 | Should Be $true
        Test-LocalPageUrl 'http://localhost:3000/' 8765 | Should Be $false
        Test-LocalPageUrl 'http://localhost/' 8765 | Should Be $false
        Test-LocalPageUrl 'https://127.0.0.1/app' 8765 | Should Be $false
        Test-LocalPageUrl 'http://localhost/' 80 | Should Be $true
        Test-LocalPageUrl 'https://m365.cloud.microsoft/chat' 8765 | Should Be $false
    }
}

Describe 'Select-AppWindows and Get-HalfRects' {
    It 'picks the Copilot window by its Edge process and the app window by its title' {
        $w = @(
            @{ handle = 1; pid = 10; title = 'Inbox - Outlook' },
            @{ handle = 2; pid = 20; title = 'Microsoft 365 Copilot - Microsoft Edge' },
            @{ handle = 3; pid = 30; title = 'StreamHub' },
            @{ handle = 4; pid = 20; title = '' }
        )
        $p = Select-AppWindows $w @(20, 21)
        $p.copilot | Should Be 2
        $p.app | Should Be 3
        (Select-AppWindows @($w[0]) @(20)).app | Should BeNullOrEmpty
    }
    It 'splits the work area into two halves' {
        $r = Get-HalfRects @{ x = 0; y = 0; width = 1921; height = 1040 }
        "$($r.left.x),$($r.left.width) $($r.right.x),$($r.right.width)" | Should Be '0,960 960,961'
    }
}

Describe 'Get-CopilotTarget never takes the StreamHub tab' {
    $sel = Get-CCBridgeConfig selectors $root
    It 'prefers the Copilot tab' {
        Mock -ModuleName CopilotBridge Invoke-RestMethod { @([pscustomobject]@{ type = 'page'; id = 'app'; url = 'http://localhost:8765/' }, [pscustomobject]@{ type = 'page'; id = 'cp'; url = 'https://m365.cloud.microsoft/chat' }) }
        (Get-CopilotTarget 9333 $sel).id | Should Be 'cp'
    }
    It 'takes a sign-in tab, but not the app tab, when Copilot is not open yet' {
        Mock -ModuleName CopilotBridge Invoke-RestMethod { @([pscustomobject]@{ type = 'page'; id = 'app'; url = 'http://localhost:8765/' }, [pscustomobject]@{ type = 'page'; id = 'login'; url = 'https://login.microsoftonline.com/x' }) }
        (Get-CopilotTarget 9333 $sel).id | Should Be 'login'
    }
    It 'opens a new Copilot tab when only the app tab is there' {
        Mock -ModuleName CopilotBridge Invoke-RestMethod {
            param($Uri, $Method)
            if ($Method -eq 'Put') { return [pscustomobject]@{ type = 'page'; id = 'new'; url = "$Uri" } }
            @([pscustomobject]@{ type = 'page'; id = 'app'; url = 'http://localhost:8765/' })
        }
        $t = Get-CopilotTarget 9333 $sel
        $t.id | Should Be 'new'
        $t.url | Should Match 'json/new\?https://www\.microsoft365\.com/chat'
    }
}
