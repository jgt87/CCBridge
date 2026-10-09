# A script that writes a page with stand-ins for its tags ([[LT]]html...) is refused when it is
# written, and not run when it is already there (Copilot mocked): the page is written as itself.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
$env:CCBRIDGE_ISSUE_INDEX = Join-Path $env:TEMP ('ccb-app-index-' + [guid]::NewGuid().ToString('N') + '.json')
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

Describe 'Scripts that generate a page with stand-ins' {
    $p = Join-Path $env:TEMP ('ccb-standin-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path (Join-Path $p 'Work') | Out-Null
    $old = "`$html = @'`n[[LT]]!doctype html>`n[[LT]]html>[[LT]]body>Hi[[LT]]/body>[[LT]]/html>`n'@`n`$html = `$html.Replace('[[LT]]', '<')`nSet-Content index.html `$html`n"
    [IO.File]::WriteAllText((Join-Path $p 'Work\Old-Gen.ps1'), $old)
    $config = Get-CCBridgeConfig harness $root
    $config.pageCheck = 'off'
    Mock -ModuleName Agent Start-NewChat { }
    Mock -ModuleName Agent Send-ToCopilot {
        param($State, [string]$Message)
        $global:ccbSent += , $Message
        $reply = $global:ccbReplies[$global:ccbSent.Count - 1]
        [pscustomobject]@{ Result = 'Success'; Text = $reply; Agent = ''; IsPlan = $false; Uncertain = 0; References = @(); ProposedActions = @(); ActionClaims = @() }
    }
    $fence = '````'
    It 'refuses to write such a script, refuses to run an existing one, and takes the page itself' {
        $global:ccbSent = @()
        $gen = "${fence}text`nACTION write Work/Write-Index.ps1`n$old$fence"
        $run = '```text' + "`nACTION run powershell -NoProfile -ExecutionPolicy Bypass -File Work/Old-Gen.ps1`n" + '```'
        $page = "${fence}text`nACTION write index.html`n<!doctype html>`n<html><head><meta charset=`"utf-8`"><title>Hi</title></head><body><p>Hi</p></body></html>`n$fence"
        $done = '```text' + "`nACTION done`nWrote the page.`n" + '```'
        $global:ccbReplies = @(($gen + "`n`n" + $run), ($page + "`n`n" + $done))
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'; $s.AllowCommands = $true
        Invoke-AgentTurn $s 'Make index.html say Hi'
        $global:ccbSent.Count | Should Be 2
        $global:ccbSent[1] | Should Match 'not written: line \d+: this script writes markup with the stand-in \[\[LT\]\]'
        $global:ccbSent[1] | Should Match 'not executed: Work/Old-Gen\.ps1 would write a page with stand-ins'
        (Test-Path (Join-Path $p 'Work\Write-Index.ps1')) | Should Be $false
        (Test-Path (Join-Path $p 'index.html')) | Should Be $true
        [IO.File]::ReadAllText((Join-Path $p 'index.html')) | Should Match '^<!doctype html>'
        @($s.Events | Where-Object { $_.type -eq 'action' -and $_.action -eq 'run' -and $_.status -eq 'awaiting' }).Count | Should Be 0
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $env:CCBRIDGE_ISSUE_INDEX -Force -ErrorAction SilentlyContinue
$env:CCBRIDGE_ISSUE_INDEX = $null
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
