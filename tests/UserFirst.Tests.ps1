# The person's request comes first: when they ask to change something chosen earlier (a chart's form)
# and Copilot keeps it as "intentional", the request goes back once with that said (Copilot mocked).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
$env:CCBRIDGE_ISSUE_INDEX = Join-Path $env:TEMP ('ccb-app-index-' + [guid]::NewGuid().ToString('N') + '.json')
foreach ($m in 'Config', 'Protocol', 'Prompts', 'Agent') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

Describe 'Reading a reply that keeps an earlier choice' {
    It 'recognises a defence of what is there, in English and Dutch, not an ordinary answer' {
        Test-DefendedChoice 'The switch to a bar chart was intentional: bars filter better.' | Should Be $true
        Test-DefendedChoice 'This is by design and not a bug.' | Should Be $true
        Test-DefendedChoice 'De staafgrafiek is een bewuste keuze.' | Should Be $true
        Test-DefendedChoice 'I changed the chart to a ring and kept the filters.' | Should Be $false
        Test-DefendedChoice ('```js' + "`n// intentional`n" + '```') | Should Be $false
    }
    It 'recognises a request to change something already there' {
        Test-ChangeAsk 'Change the graph back to a donut' | Should Be $true
        Test-ChangeAsk 'make it a donut again' | Should Be $true
        Test-ChangeAsk 'Zet de grafiek terug naar een donut' | Should Be $true
        Test-ChangeAsk 'Why does the total differ from the report?' | Should Be $false
    }
}

Describe 'A change request Copilot answers with "intentional"' {
    $p = Join-Path $env:TEMP ('ccb-userfirst-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    [IO.File]::WriteAllText((Join-Path $p 'index.html'), "<html><body><div id=`"c`" data-kit-chart=`"bar`"></div></body></html>`n")
    $config = Get-CCBridgeConfig harness $root
    $config.pageCheck = 'off'
    Mock -ModuleName Agent Start-NewChat { }
    Mock -ModuleName Agent Send-ToCopilot {
        param($State, [string]$Message)
        $global:ccbSent += , $Message
        $reply = $global:ccbReplies[[Math]::Min($global:ccbSent.Count, $global:ccbReplies.Count) - 1]
        [pscustomobject]@{ Result = 'Success'; Text = $reply; Agent = ''; IsPlan = $false; Uncertain = 0; References = @(); ProposedActions = @(); ActionClaims = @() }
    }
    $fence = '````'
    It 'sends the request back once, the person first, and then the change is made' {
        $global:ccbSent = @()
        $edit = "${fence}text`nACTION edit index.html`n####### SEARCH`ndata-kit-chart=`"bar`"`n####### REPLACE`ndata-kit-chart=`"ring`"`n####### END`n$fence"
        $global:ccbReplies = @(
            ('The change to a bar chart was intentional, not a bug: bars work better as filters.' + "`n" + '```text' + "`nACTION done`nKept the bar chart.`n" + '```'),
            ($edit + "`n`n" + '```text' + "`nACTION done`nThe chart is a ring again.`n" + '```')
        )
        $s = New-AgentState -Config $config -AppRoot $p; $s.AppRoot = $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        Invoke-AgentTurn $s 'Change the graph back to a donut'
        $global:ccbSent.Count | Should Be 2
        # The request goes with it (every message of the turn carries it), and why it comes first.
        $global:ccbSent[1] | Should Match 'Change the graph back to a donut'
        $global:ccbSent[1] | Should Match 'You kept what is there instead of making the change the person asked for'
        $global:ccbSent[1] | Should Match 'that something was intentional is no reason to keep it'
        ([IO.File]::ReadAllText((Join-Path $p 'index.html'))) | Should Match 'data-kit-chart="ring"'
        @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -match 'what you ask comes first' }).Count | Should Be 1
    }
    It 'sends it back only once, and not for a question' {
        $global:ccbSent = @()
        $global:ccbReplies = @('It was intentional.' + "`n" + '```text' + "`nACTION done`nKept it.`n" + '```')
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        Invoke-AgentTurn $s 'Change the graph back to a donut'
        $global:ccbSent.Count | Should Be 2
        $global:ccbSent = @()
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        Invoke-AgentTurn $s 'Why is the graph a bar chart now?'
        $global:ccbSent.Count | Should Be 1
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $env:CCBRIDGE_ISSUE_INDEX -Force -ErrorAction SilentlyContinue
$env:CCBRIDGE_ISSUE_INDEX = $null
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
