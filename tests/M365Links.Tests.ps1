# Microsoft 365 file links (SharePoint, OneDrive) in a request: Copilot opens them itself with the
# user's access; the web action never fetches them (it only gets a sign-in page). Made-up addresses.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\WebFetch.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

$link = 'https://contoso.sharepoint.com/:x:/r/sites/Reporting/_layouts/15/Doc.aspx?sourcedoc=%7BABC%7D&file=Example%20List.csv&action=default'

Describe 'Microsoft 365 links' {
    It 'recognises SharePoint, OneDrive and Microsoft 365 addresses, not other sites' {
        Test-M365Address $link | Should Be $true
        Test-M365Address 'https://contoso-my.sharepoint.com/personal/x/Documents/a.xlsx' | Should Be $true
        Test-M365Address 'https://1drv.ms/x/s!abc' | Should Be $true
        Test-M365Address 'https://m365.cloud.microsoft/chat' | Should Be $true
        Test-M365Address 'https://example.com/report.csv' | Should Be $false
        Test-M365Address 'https://sharepoint.com.example.org/x' | Should Be $false
    }
    It 'finds the links in a message' {
        @(Get-M365Links "Can you make a dashboard based on this data? $link and https://example.com/x").Count | Should Be 1
    }
    It 'adds the rule for such a message' {
        $ids = @(& (Get-Module Prompts) { param($t) Get-PromptModules -Text $t -Context @{ Paths = @() } } "Make a dashboard from $link")
        $ids -contains 'rules:m365links' | Should Be $true
    }
    It 'does not fetch such a link with the web action, and tells Copilot to open it itself' {
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $r = & (Get-Module Agent) { param($st, $u) Invoke-AgentAction $st ([pscustomobject]@{ type = 'web'; arg = $u; body = '' }) 'w1' $null 0 } $s $link
        $r.ok | Should Be $false
        $r.output | Should Match 'open it yourself'
        $r.output | Should Match 'data/NAME\.csv'
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
