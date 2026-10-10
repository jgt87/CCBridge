# The round budget of a message (maxRounds) is against loops, not against work: a message that keeps
# changing files goes on past it (up to three times), one that stops changing files ends (Copilot mocked).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
$env:CCBRIDGE_ISSUE_INDEX = Join-Path $env:TEMP ('ccb-app-index-' + [guid]::NewGuid().ToString('N') + '.json')
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

Describe 'Test-RoundsLeft' {
    It 'always goes on within the budget, past it only while files change, never past three times the budget' {
        (Test-RoundsLeft 12 5 0).go | Should Be $true
        (Test-RoundsLeft 12 11 0).go | Should Be $true
        (Test-RoundsLeft 12 12 0).go | Should Be $false          # the budget, nothing ever changed
        (Test-RoundsLeft 12 12 12).go | Should Be $true          # the budget, this round changed files
        (Test-RoundsLeft 12 12 12).extend | Should Be $true
        (Test-RoundsLeft 12 13 12).go | Should Be $true          # the round before changed files
        $r = Test-RoundsLeft 12 14 12                            # two rounds without a change
        $r.go | Should Be $false
        $r.idle | Should Be $true
        $r.reason | Should Match 'changed no files'
        (Test-RoundsLeft 12 35 35).go | Should Be $true
        $h = Test-RoundsLeft 12 36 36                            # three times the budget
        $h.go | Should Be $false
        $h.idle | Should Be $false
        $h.hard | Should Be 36
        (Test-RoundsLeft 25 75 75).hard | Should Be 60
        (Test-RoundsLeft 1 1 1).hard | Should Be 3
    }
}

Describe 'A message that keeps building goes on past the round budget' {
    $p = Join-Path $env:TEMP ('ccb-rounds-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    [IO.File]::WriteAllText((Join-Path $p 'notes.md'), "# Notes`n")
    $config = Get-CCBridgeConfig harness $root
    $config.pageCheck = 'off'
    $config.maxRounds = 3
    Mock -ModuleName Agent Start-NewChat { }
    Mock -ModuleName Agent Send-ToCopilot {
        param($State, [string]$Message)
        $global:ccbSent += , $Message
        $i = $global:ccbSent.Count - 1
        $reply = if ($i -lt $global:ccbReplies.Count) { $global:ccbReplies[$i] } else { $global:ccbReplies[-1] }
        [pscustomobject]@{ Result = 'Success'; Text = $reply; Agent = ''; IsPlan = $false; Uncertain = 0; References = @(); ProposedActions = @(); ActionClaims = @() }
    }
    $fence = '````'
    $write = { param($n) "${fence}text`nACTION write part$n.md`n# Part $n`n`nText of part $n.`n$fence" }
    $read = '```text' + "`nACTION read notes.md`n" + '```'
    $done = '```text' + "`nACTION done`nAll parts written.`n" + '```'
    It 'continues while every round writes a file, and ends at done' {
        $global:ccbSent = @()
        $global:ccbReplies = @((& $write 1), (& $write 2), (& $write 3), (& $write 4), (& $write 5), (& $write 6), (& $write 7), $done)
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        Invoke-AgentTurn $s 'Write the seven parts'
        $global:ccbSent.Count | Should Be 8
        Test-Path (Join-Path $p 'part7.md') | Should Be $true
        @($s.Events | Where-Object { $_.type -eq 'done' }).Count | Should Be 1
        @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -like 'Past 3 rounds, but the last round still changed files*' }).Count | Should Be 1
    }
    It 'stops at the budget when the rounds change nothing, and two rounds after the last change' {
        $global:ccbSent = @()
        $global:ccbReplies = @($read, $read, $read, $read, $read)
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        Invoke-AgentTurn $s 'Read the notes'
        $global:ccbSent.Count | Should Be 3
        @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -like 'Stopped after 3 rounds*' }).Count | Should Be 1
        $global:ccbSent = @()
        $global:ccbReplies = @((& $write 8), (& $write 9), $read, $read, $read, $read)
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        Invoke-AgentTurn $s 'Write two parts'
        $global:ccbSent.Count | Should Be 4
        @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -like 'Stopped after 4 rounds (the last two rounds changed no files)*' }).Count | Should Be 1
    }
    It 'stops at three times the budget even while files change' {
        $global:ccbSent = @()
        $global:ccbReplies = @(1..12 | ForEach-Object { & $write (20 + $_) })
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        Invoke-AgentTurn $s 'Write many parts'
        $global:ccbSent.Count | Should Be 9
        @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -like 'Stopped after 9 rounds*' }).Count | Should Be 1
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $env:CCBRIDGE_ISSUE_INDEX -Force -ErrorAction SilentlyContinue
