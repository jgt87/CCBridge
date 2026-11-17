# The Work IQ switch from a capture (lib/CopilotBridge.psm1 Get-WorkIqToggleCandidates, used by
# tools/capture-copilot.ps1): two control snapshots, Work IQ on then off, as the capture records them
# (JSON, so a field the page did not have is missing, not empty).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force

function ConvertFrom-Snapshot([string]$Json) { $a = ConvertFrom-Json $Json; , @($a) }

Describe 'Get-WorkIqToggleCandidates' {
    It 'finds the control whose state flipped, with its selector, state attribute and on value' {
        $on = ConvertFrom-Snapshot '[{"tag":"button","role":"switch","testid":"work-web-toggle","aria":"Work","checked":"true"},{"tag":"button","aria":"Send","text":"Send"}]'
        $off = ConvertFrom-Snapshot '[{"tag":"button","role":"switch","testid":"work-web-toggle","aria":"Work","checked":"false"},{"tag":"button","aria":"Send","text":"Send"}]'
        $c = @(Get-WorkIqToggleCandidates -On $on -Off $off)
        $c.Count | Should Be 1
        $c[0].toggle | Should Be "[data-testid='work-web-toggle']"
        $c[0].stateAttribute | Should Be 'aria-checked'
        $c[0].onValue | Should Be 'true'
        $c[0].label | Should Be 'Work'
    }

    It 'falls back to a stable id, then the label or title, and skips generated ids with digits' {
        $on = ConvertFrom-Snapshot '[{"tag":"button","id":"workToggle","pressed":"true"},{"tag":"button","id":"fluent-r3","aria":"Web","pressed":"false"},{"tag":"div","role":"tab","title":"Work tab","selected":"true"}]'
        $off = ConvertFrom-Snapshot '[{"tag":"button","id":"workToggle","pressed":"false"},{"tag":"button","id":"fluent-r3","aria":"Web","pressed":"true"},{"tag":"div","role":"tab","title":"Work tab","selected":"false"}]'
        $c = @(Get-WorkIqToggleCandidates -On $on -Off $off)
        ($c | ForEach-Object { $_.toggle }) -contains '#workToggle' | Should Be $true
        ($c | ForEach-Object { $_.toggle }) -contains "button[aria-label='Web']" | Should Be $true
        ($c | ForEach-Object { $_.toggle }) -contains "div[title='Work tab']" | Should Be $true
        ($c | Where-Object { $_.toggle -eq 'div[title=''Work tab'']' }).stateAttribute | Should Be 'aria-selected'
        ($c | Where-Object { $_.toggle -eq "button[aria-label='Web']" }).onValue | Should Be 'false'   # the value while Work IQ is on
    }

    It 'puts a control named for work or IQ first' {
        $on = ConvertFrom-Snapshot '[{"tag":"button","aria":"Show menu","expanded":"true","pressed":"true"},{"tag":"button","aria":"Work IQ","checked":"true"}]'
        $off = ConvertFrom-Snapshot '[{"tag":"button","aria":"Show menu","pressed":"false"},{"tag":"button","aria":"Work IQ","checked":"false"}]'
        $c = @(Get-WorkIqToggleCandidates -On $on -Off $off)
        $c.Count | Should Be 2
        $c[0].label | Should Be 'Work IQ'
    }

    It 'gives nothing when no state changed, a control is in one snapshot only, or it has nothing to find it by' {
        $same = ConvertFrom-Snapshot '[{"tag":"button","aria":"Work","checked":"true"}]'
        @(Get-WorkIqToggleCandidates -On $same -Off $same).Count | Should Be 0
        $on = ConvertFrom-Snapshot '[{"tag":"button","aria":"Work","checked":"true"}]'
        $off = ConvertFrom-Snapshot '[{"tag":"button","aria":"Web","checked":"false"}]'
        @(Get-WorkIqToggleCandidates -On $on -Off $off).Count | Should Be 0
        $on = ConvertFrom-Snapshot '[{"tag":"button","text":"Work","checked":"true"}]'
        $off = ConvertFrom-Snapshot '[{"tag":"button","text":"Work","checked":"false"}]'
        @(Get-WorkIqToggleCandidates -On $on -Off $off).Count | Should Be 0
        @(Get-WorkIqToggleCandidates -On @() -Off @()).Count | Should Be 0
    }

    It 'reads a snapshot that arrives as one nested array (a JSON array read in a pipeline)' {
        $on = @('[{"tag":"button","aria":"Work","checked":"true"}]' | ConvertFrom-Json)
        $off = @('[{"tag":"button","aria":"Work","checked":"false"}]' | ConvertFrom-Json)
        (@(Get-WorkIqToggleCandidates -On $on -Off $off))[0].toggle | Should Be "button[aria-label='Work']"
    }

    It 'escapes quotes and backslashes in a label for the selector' {
        $on = ConvertFrom-Snapshot '[{"tag":"button","aria":"Use O''Brien\\work","checked":"true"}]'
        $off = ConvertFrom-Snapshot '[{"tag":"button","aria":"Use O''Brien\\work","checked":"false"}]'
        (@(Get-WorkIqToggleCandidates -On $on -Off $off))[0].toggle | Should Be "button[aria-label='Use O\'Brien\\work']"
    }
}
