$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$base = Join-Path $env:TEMP ('ccb-guidance-' + [guid]::NewGuid().ToString('N'))
$env:CCBRIDGE_STATE_ROOT = Join-Path $base 'state'
foreach ($m in 'Config', 'Agent', 'TaskGuidance', 'Prompts', 'Handoff') { Import-Module (Join-Path $root "lib/$m.psm1") -Force }
$null = New-Item -ItemType Directory -Force -Path $base

Describe 'Required context survives message budgets' {
    It 'preserves the full request, instructions and the final error within the budget' {
        $request = 'Implement the change. ' + ('constraint ' * 100) + 'NEVER REMOVE THE DATA'
        $notes = 'Project rule: preserve the public API.'
        $message = ('context ' * 2000) + $notes + $request + "`nERROR: final useful diagnosis"
        $out = Format-TaskMessage $message @($request, $notes) 2000
        $out.Length | Should BeLessThan 2001
        $out.Contains($request) | Should Be $true
        $out.Contains($notes) | Should Be $true
        $out | Should Match 'ERROR: final useful diagnosis'
    }
    It 'refuses a budget that cannot hold required instructions instead of losing them' {
        { Format-TaskMessage 'optional' @('x' * 1000) 500 } | Should Throw 'required instructions exceed'
    }
    It 'keeps the original request beyond character 600 in handoff facts and on disk' {
        $request = ('first requirement ' * 100) + "`nLast requirement: preserve customer records."
        (Format-HandoffFacts -Request $request).Contains($request) | Should Be $true
        $file = Save-TaskRecord $base @{ request = $request; verification = @{ passed = $false }; remaining = @('last step') }
        $saved = [IO.File]::ReadAllText($file) | ConvertFrom-Json
        $saved.request | Should BeExactly $request
        $saved.verification.passed | Should Be $false
    }
}

Describe 'Task intent is separate from the code subject' {
    It 'distinguishes questions and investigations from authorized changes' {
        Get-TaskIntent 'How can I fix the parser?' | Should Be 'answer'
        Get-TaskIntent 'Review the parser and identify issues' | Should Be 'investigate'
        Get-TaskIntent 'Review the parser and fix all issues' | Should Be 'change'
        Get-TaskIntent 'Inspect the parser without changing files' | Should Be 'investigate'
        Get-TaskIntent 'Can you fix the parser?' | Should Be 'change'
        Get-TaskIntent 'Continue' '' 'investigate' | Should Be 'investigate'
        Get-TaskIntent 'Implement the plan' 'plan' | Should Be 'investigate'
    }
    It 'does not retry a legitimate answer with bullets or sample code as a change request' {
        & (Get-Module Agent) {
            foreach ($intent in 'answer', 'investigate') {
                Test-NeedsActionNudge @{ Mode = 'auto'; TaskIntent = $intent } 'coding' "- Issue one`n- Issue two" 0 2 | Should Be $false
            }
            Test-NeedsActionNudge @{ Mode = 'auto'; TaskIntent = 'change' } 'coding' "- Open the file`n- Replace the value" 0 2 | Should Be $true
        }
    }
}

Describe 'Evidence based progress' {
    It 'counts fresh reads and test failures once, not identical observations' {
        $seen = New-Object 'Collections.Generic.HashSet[string]'
        $a = @{ type = 'read'; arg = 'a.txt'; body = '' }
        $r = @{ ok = $true; output = 'a'; changedPath = $null }
        Test-RoundProgress @($a) @($r) $seen | Should Be $true
        Test-RoundProgress @($a) @($r) $seen | Should Be $false
        $a.arg = 'b.txt'; $r.output = 'b'
        Test-RoundProgress @($a) @($r) $seen | Should Be $true
        $a = @{ type = 'run'; body = 'npm test'; arg = '' }
        $r = @{ ok = $false; output = 'FAIL: expected 2, received 1' }
        Test-RoundProgress @($a) @($r) $seen | Should Be $true
        Test-RoundProgress @($a) @($r) $seen | Should Be $false
        Get-ExploreNudge 3 @() $false | Should Not Match 'Create the files now|list.*complete|nothing more to find'
    }
}

Describe 'Instructions before mutations in the real turn loop' {
    Mock -ModuleName Agent Start-NewChat { }
    Mock -ModuleName Agent Send-ToCopilot {
        param($State, $Message)
        $global:guidanceSent += , $Message
        $i = [Math]::Min($global:guidanceSent.Count - 1, $global:guidanceReplies.Count - 1)
        @{ Result = 'Success'; Text = $global:guidanceReplies[$i]; References = @(); ProposedActions = @(); ActionClaims = @() }
    }
    It 'defers a write to a newly discovered folder, sends its complete notes, then permits reconsidered edits' {
        $p = Join-Path $base 'project'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $p 'src')
        $notes = '# Folder rules' + "`n" + ('Keep these instructions. ' * 150) + 'Last rule: use plain text.'
        [IO.File]::WriteAllText((Join-Path $p 'src/AGENTS.md'), $notes)
        $write = '````text' + "`nACTION write src/note.md`nA note.`n" + '````'
        $done = '```text' + "`nACTION done`nFinished.`n" + '```'
        $global:guidanceReplies = @($write, $write, $done); $global:guidanceSent = @()
        $c = Get-CCBridgeConfig harness $root; $c.pageCheck = 'off'; $c.reviewAfterChanges = 'off'
        $s = New-AgentState -Config $c -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        Invoke-AgentTurn $s 'Write a note'
        $global:guidanceSent[1] | Should Match 'No actions in this reply were executed'
        $global:guidanceSent[1].Contains($notes) | Should Be $true
        [IO.File]::ReadAllText((Join-Path $p 'src/note.md')).Trim() | Should Be 'A note.'
        @($s.Events | Where-Object { $_.type -eq 'action' -and $_.action -eq 'write' }).Count | Should Be 1
    }
    It 'accepts an investigation answer without retrying it into edits' {
        $global:guidanceReplies = @("- Parser reads the file.`n- Validation checks the result."); $global:guidanceSent = @()
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root; $s.ProjectRoot = Join-Path $base 'project'; $s.Mode = 'auto'
        Invoke-AgentTurn $s 'Explain how the parser works'
        $global:guidanceSent.Count | Should Be 1
        $global:guidanceSent[0] | Should Match 'Task intent: answer'
    }
}

$resolved = [IO.Path]::GetFullPath($base)
if ($resolved.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\ccb-guidance-', [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
$env:CCBRIDGE_STATE_ROOT = $null
