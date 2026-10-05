# External links from the app open as a real new tab in StreamHub's Edge (AppWindow.psm1), because
# Edge's Split screen otherwise sends them to the other pane (replacing Copilot). Edge is mocked.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\AppWindow.psm1') -Force

Describe 'Test-ExternalLink' {
    It 'accepts web links to other sites only' {
        Test-ExternalLink 'https://github.com/jgt87/CCBridge/blob/abc1234/CHANGELOG.md' | Should Be $true
        Test-ExternalLink 'http://example.org/page?a=1#x' | Should Be $true
        Test-ExternalLink 'http://localhost:8765/' | Should Be $false
        Test-ExternalLink 'javascript:alert(1)' | Should Be $false
        Test-ExternalLink 'file:///C:/Windows/notepad.exe' | Should Be $false
        Test-ExternalLink 'https://a b.example' | Should Be $false
    }
}

Describe 'Open-LinkInEdgeTab' {
    Mock -ModuleName AppWindow Connect-Cdp { [pscustomobject]@{ Ws = $null } }
    Mock -ModuleName AppWindow Disconnect-Cdp { }
    Mock -ModuleName AppWindow Invoke-Cdp { param($Session, $Method, $Params) $global:ccbOpened += , @{ method = $Method; url = $Params.url } }
    It 'opens a new tab through Edge when the app is a tab there' {
        $global:ccbOpened = @()
        Mock -ModuleName AppWindow Invoke-RestMethod {
            param($Uri)
            if ("$Uri" -like '*json/list') { return @([pscustomobject]@{ type = 'page'; url = 'https://m365.cloud.microsoft/chat' }, [pscustomobject]@{ type = 'page'; url = 'http://localhost:8765/' }) }
            [pscustomobject]@{ webSocketDebuggerUrl = 'ws://127.0.0.1:9333/devtools/browser/x' }
        }
        Open-LinkInEdgeTab 'https://github.com/jgt87/CCBridge/blob/abc/CHANGELOG.md' 8765 9333 | Should Be 'new-tab'
        $global:ccbOpened.Count | Should Be 1
        $global:ccbOpened[0].method | Should Be 'Target.createTarget'
        $global:ccbOpened[0].url | Should Be 'https://github.com/jgt87/CCBridge/blob/abc/CHANGELOG.md'
    }
    It 'leaves the link to the browser when the app is elsewhere, and refuses other addresses' {
        $global:ccbOpened = @()
        Mock -ModuleName AppWindow Invoke-RestMethod { param($Uri) @([pscustomobject]@{ type = 'page'; url = 'https://m365.cloud.microsoft/chat' }) }
        Open-LinkInEdgeTab 'https://example.org/' 8765 9333 | Should Be 'not-here'
        $global:ccbOpened.Count | Should Be 0
        { Open-LinkInEdgeTab 'javascript:alert(1)' 8765 9333 } | Should Throw 'only http and https'
    }
    It 'also opens the project''s own pages on the preview address (Open app), and no other local page' {
        $global:ccbOpened = @()
        Mock -ModuleName AppWindow Invoke-RestMethod {
            param($Uri)
            if ("$Uri" -like '*json/list') { return @([pscustomobject]@{ type = 'page'; url = 'http://localhost:8765/' }) }
            [pscustomobject]@{ webSocketDebuggerUrl = 'ws://127.0.0.1:9333/devtools/browser/x' }
        }
        $prefix = 'http://localhost:8765/preview/TOKEN/'
        Open-LinkInEdgeTab ($prefix + 'dist/index.html') 8765 9333 -PreviewPrefix $prefix | Should Be 'new-tab'
        $global:ccbOpened[0].url | Should Be 'http://localhost:8765/preview/TOKEN/dist/index.html'
        { Open-LinkInEdgeTab 'http://localhost:8765/api/files' 8765 9333 -PreviewPrefix $prefix } | Should Throw 'only http and https'
        { Open-LinkInEdgeTab 'http://localhost:8765/preview/OTHER/x.html' 8765 9333 -PreviewPrefix $prefix } | Should Throw 'only http and https'
    }
}
