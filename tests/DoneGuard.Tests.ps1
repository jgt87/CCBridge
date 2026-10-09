# A "done" in the same reply as a write, edit or run step that failed does not end the task: the
# failure goes back to Copilot and done is taken again in a reply of its own (Copilot mocked).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
$env:CCBRIDGE_ISSUE_INDEX = Join-Path $env:TEMP ('ccb-app-index-' + [guid]::NewGuid().ToString('N') + '.json')
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

Describe 'Done next to a failed step' {
    $p = Join-Path $env:TEMP ('ccb-done-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    [IO.File]::WriteAllText((Join-Path $p 'app.js'), "function a() {`n  return 1;`n}`n")
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
    It 'sends the failure back instead of ending the task, whichever comes first' {
        $global:ccbSent = @()
        $badEdit = "${fence}text`nACTION edit app.js`n####### SEARCH`nreturn 42;`n####### REPLACE`nreturn 2;`n####### END`n$fence"
        $done = '```text' + "`nACTION done`nChanged the return value.`n" + '```'
        $goodEdit = "${fence}text`nACTION edit app.js`n####### SEARCH`nreturn 1;`n####### REPLACE`nreturn 2;`n####### END`n$fence"
        $global:ccbReplies = @(
            ($done + "`n`n" + $badEdit),       # 1. done first, then a step that fails
            ($badEdit + "`n`n" + $done),       # 2. the failing step first, then done
            ($goodEdit + "`n`n" + $done)       # 3. a step that works, and done
        )
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        Invoke-AgentTurn $s 'Make a return 2'
        $global:ccbSent.Count | Should Be 3
        $global:ccbSent[1] | Should Match '### done\s+not accepted: a step in this reply failed'
        $global:ccbSent[2] | Should Match '### done\s+not accepted: a write, edit or run step in this reply failed'
        ([IO.File]::ReadAllText((Join-Path $p 'app.js'))).Replace("`r`n", "`n") | Should Be "function a() {`n  return 2;`n}`n"
        @($s.Events | Where-Object { $_.type -eq 'done' }).Count | Should Be 1
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $env:CCBRIDGE_ISSUE_INDEX -Force -ErrorAction SilentlyContinue
$env:CCBRIDGE_ISSUE_INDEX = $null
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
