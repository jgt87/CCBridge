# Copilot can ask for a screenshot after clicks that open the part it changed (another view, tab or
# dialog): ACTION screenshot PAGE with click / wait lines (Protocol Get-ScreenshotSteps, Agent).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Protocol.psm1') -Force

Describe 'The screenshot action' {
    It 'is read from a reply with its page and steps' {
        $fence = '````'
        $a = @(Get-ActionBlocks "${fence}text`nACTION screenshot index.html`nclick text=Month`nwait 500`n- click #next-btn`n${fence}")[0]
        $a.type | Should Be 'screenshot'
        $a.arg | Should Be 'index.html'
        $steps = @(Get-ScreenshotSteps $a.body)
        $steps.Count | Should Be 3
        $steps[0].kind | Should Be 'click'; $steps[0].target | Should Be 'text=Month'
        $steps[1].kind | Should Be 'wait'; $steps[1].ms | Should Be 500
        $steps[2].target | Should Be '#next-btn'
    }
    It 'keeps at most 5 steps, caps waits at 5 seconds and skips other lines' {
        $steps = @(Get-ScreenshotSteps ("note`n" + ((1..7 | ForEach-Object { "click #b$_" }) -join "`n") + "`nwait 99999"))
        $steps.Count | Should Be 5
        (@(Get-ScreenshotSteps 'wait 99999'))[0].ms | Should Be 5000
    }
}

Describe 'The screenshot hint and a page name that is not a page' {
    Import-Module (Join-Path $root 'lib\Config.psm1') -Force
    Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
    It 'names the page that was screenshotted, not a placeholder' {
        $h = & (Get-Module Agent) { Get-ScreenshotHint 'pages/plan.html' }
        $h | Should Match 'ACTION screenshot pages/plan\.html'
        $h | Should Not MatchExactly 'ACTION screenshot PAGE[ ,]'
    }
    It 'uses the page of the last screenshot when the action names no page file' {
        $env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
        $p = Join-Path $env:TEMP ('ccb-shotp-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        [IO.File]::WriteAllText((Join-Path $p 'home.html'), '<p>x</p>')
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = $p
        $s.PreviewPort = 1; $s.PreviewToken = 'none'; $s.LastShotPage = 'home.html'   # nothing listens: no picture, but the page is chosen
        $null = & (Get-Module Agent) { param($st) Invoke-AgentAction $st ([pscustomobject]@{ type = 'screenshot'; arg = 'PAGE'; body = 'click text=Week' }) 'a1' $null 0 } $s
        (@($s.Events | Where-Object type -eq 'action'))[0].target | Should Match '^home\.html'
        # The tab it opened is closed again (a click step once overwrote the tab it had to close).
        try { @((Invoke-RestMethod "http://127.0.0.1:$((Get-CCBridgeConfig harness $root).cdpPort)/json/list" -TimeoutSec 3) | Where-Object { $_.url -match '^http://localhost:1/preview/' }).Count | Should Be 0 } catch [System.Net.WebException] { }
        Remove-Item $p, $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
    }
}
