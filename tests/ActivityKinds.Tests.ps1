# What StreamHub is busy with, with a kind for the waiting indicator's light lines (Agent
# Enter-Activity / Exit-Activity, Server Get-ActivityView).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force
Import-Module (Join-Path $root 'lib\Server.psm1') -Force

Describe 'Activity kinds' {
    $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
    It 'sets a kind and label for a step and puts back what was there before' {
        $outer = & (Get-Module Agent) { param($st) Enter-Activity $st 'tests' 'Running the tests' } $s
        $inner = & (Get-Module Agent) { param($st) Enter-Activity $st 'page' 'Checking index.html in a browser tab' } $s
        $s.Activity.kind | Should Be 'page'
        & (Get-Module Agent) { param($st, $p) Exit-Activity $st $p } $s $inner
        $s.Activity.kind | Should Be 'tests'; $s.Activity.label | Should Be 'Running the tests'
        & (Get-Module Agent) { param($st, $p) Exit-Activity $st $p } $s $outer
        $s.Activity.label | Should Be ''
    }
    It 'sends the kind to the app; the background index run is index' {
        $s.Activity.kind = 'wait'; $s.Activity.label = 'Pausing before the next step'
        (& (Get-Module Server) { param($st) Get-ActivityView $st } $s).kind | Should Be 'wait'
        $s.Activity.label = ''
        $s.Indexing.label = 'Indexing the project'
        $v = & (Get-Module Server) { param($st) Get-ActivityView $st } $s
        $v.kind | Should Be 'index'; $v.background | Should Be $true
    }
}
