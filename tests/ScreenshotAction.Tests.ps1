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
