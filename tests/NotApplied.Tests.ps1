# "The change did not take effect": a follow-up that says so gets the cause looked for first, and done
# is earned, not claimed: refused while no file changed in that message (Copilot mocked).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
$env:CCBRIDGE_ISSUE_INDEX = Join-Path $env:TEMP ('ccb-app-index-' + [guid]::NewGuid().ToString('N') + '.json')
foreach ($m in 'Config', 'Protocol', 'Prompts', 'Agent') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

Describe 'Reading "the change did not take effect"' {
    It 'recognises the ways people say it, in English and Dutch' {
        foreach ($t in 'Nothing changed', 'The header still looks the same', 'It still shows the old colour', 'try again', 'The change wasn''t executed properly',
            'I don''t see the change', 'it did not work', 'the page looks exactly the same', 'Er is niets veranderd', 'Het werkt nog niet', 'De knop is nog steeds blauw', 'probeer het opnieuw') {
            Test-NotAppliedReport $t | Should Be $true
        }
    }
    It 'counts as a request to change, also worded as a question; "do not change anything" still wins' {
        Get-TaskIntent 'Nothing changed, the header is still blue' | Should Be 'change'
        Get-TaskIntent 'Why is the header still blue?' | Should Be 'change'
        Get-TaskIntent 'It still shows the old colour, do not change anything yet' | Should Be 'investigate'
    }
    It 'leaves ordinary requests alone' {
        foreach ($t in 'Make the header sticky', 'Add a donut chart for the regions', 'There is nothing else to add after this', 'Change the button colour to green', 'Is it still possible to export to Excel?') {
            Test-NotAppliedReport $t | Should Be $false
        }
    }
}

Describe 'A follow-up that says the change did not take effect' {
    $p = Join-Path $env:TEMP ('ccb-notapplied-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    [IO.File]::WriteAllText((Join-Path $p 'style.css'), ".header { color: blue; }`n")
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
    $done = '```text' + "`nACTION done`nThe header is green now.`n" + '```'
    It 'brings what Copilot claimed, asks for the cause first, and refuses done while no file changed' {
        $global:ccbSent = @()
        $edit = "${fence}text`nACTION edit style.css`n####### SEARCH`n.header { color: blue; }`n####### REPLACE`n.header { color: green; }`n####### END`n$fence"
        $global:ccbReplies = @($done, ($edit + "`n`n" + $done))
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        Add-AgentEvent $s 'done' @{ text = 'The header is green now.' }   # the earlier turn's claim
        Invoke-AgentTurn $s 'Nothing changed, the header is still blue'
        $global:ccbSent.Count | Should Be 2
        $global:ccbSent[0] | Should Match 'Task intent: change\.'   # never "answer ... Do not change project files"
        $global:ccbSent[0] | Should Match 'THE PERSON SAYS YOUR LAST CHANGE DID NOT TAKE EFFECT'
        $global:ccbSent[0] | Should Match 'Your last answer said: "The header is green now\."'
        $global:ccbSent[0] | Should Match 'First find out why it did not show'
        $global:ccbSent[1] | Should Match 'Done is not accepted yet: no file changed in this message'
        [IO.File]::ReadAllText((Join-Path $p 'style.css')) | Should Match 'color: green'
        @($s.Events | Where-Object { $_.type -eq 'status' -and $_.text -match 'Sent back to find the cause' }).Count | Should Be 1
    }
    It 'gives up refusing after three tries, and does nothing special without an earlier done' {
        $global:ccbSent = @()
        $global:ccbReplies = @($done)
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        $s.ChatKind = 'coding'   # a follow-up in a work chat keeps that chat's kind
        Add-AgentEvent $s 'done' @{ text = 'Done.' }
        Invoke-AgentTurn $s 'It still looks the same'
        $global:ccbSent.Count | Should Be 4   # the message, then three refusals, then done is taken
        $global:ccbSent = @()
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        Invoke-AgentTurn $s 'It still looks the same'
        $global:ccbSent.Count | Should Be 1
        $global:ccbSent[0] | Should Not Match 'DID NOT TAKE EFFECT'
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $env:CCBRIDGE_ISSUE_INDEX -Force -ErrorAction SilentlyContinue
$env:CCBRIDGE_ISSUE_INDEX = $null
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
