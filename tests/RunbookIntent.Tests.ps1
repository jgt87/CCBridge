# Whether a message runs a runbook: fixed rules for the clear cases, the person chooses when a message
# names a runbook without saying to run it, and Copilot can run one with ACTION runbook NAME when it
# reads the request that way. Copilot is not called here; runbook contents are made-up test data.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $root 'lib\Protocol.psm1') -Force
Import-Module (Join-Path $root 'lib\Runbook.psm1') -Force
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

$days = @([pscustomobject]@{ name = 'day-01'; title = 'Monday Calendar Export'; path = 'Runbooks/day-01.runbook.md' }, [pscustomobject]@{ name = 'day-02'; title = 'Tuesday Calendar Export'; path = 'Runbooks/day-02.runbook.md' })

Describe 'Get-RunbookRunRequest: the person chooses when it is not clear' {
    It 'asks for a longer message that names a runbook without a run word or a change' {
        $r = Get-RunbookRunRequest 'I looked at the output of day-01 yesterday and the numbers seemed fine to me overall' $days
        $r.name | Should Be 'day-01'
        $r.ask | Should Be $true
    }
    It 'still runs clear requests and leaves changes to Copilot' {
        (Get-RunbookRunRequest 'day-01' $days).ask | Should BeNullOrEmpty
        (Get-RunbookRunRequest 'please run day-02 now so I get the latest calendar data for this month' $days).ask | Should BeNullOrEmpty
        Get-RunbookRunRequest 'day-02 should use the second day of the month instead of a weekday name' $days | Should BeNullOrEmpty
    }
}

Describe 'ACTION runbook NAME (Copilot runs a runbook)' {
    It 'is read from a reply like the other actions' {
        $reply = "Running it now.`n" + '```text' + "`nACTION runbook day-01`n" + '```'
        $a = @(Get-ActionBlocks $reply)
        $a.Count | Should Be 1
        $a[0].type | Should Be 'runbook'
        $a[0].arg | Should Be 'day-01'
    }
    It 'sends the runbook rules (with the action) when a message names one of the project''s runbooks' {
        $ctx = @{ Traits = @('code'); Paths = @('Runbooks/day-01.runbook.md', 'src/app.js') }
        @(Get-PromptModules 'can you give me the day-01 data again' $ctx) -contains 'rules:runbook' | Should Be $true
        @(Get-PromptModules 'make the button blue' $ctx) -contains 'rules:runbook' | Should Be $false
        Get-PromptPart $root 'rules:runbook' | Should Match 'ACTION runbook NAME'
    }

    $p = Join-Path $env:TEMP ('ccb-rbint-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'Runbooks') | Out-Null
    [IO.File]::WriteAllText((Join-Path $p 'Runbooks\day-01.runbook.md'), "---`ntitle: Example Calendar Export`noutput: Runbooks/Exports/day-01.json`nitemsKey: items`n---`nList the example items as JSON.")
    $config = Get-CCBridgeConfig harness $root
    $act = { param($st, $arg) & (Get-Module Agent) { param($s2, $a2) Invoke-AgentAction $s2 ([pscustomobject]@{ type = 'runbook'; arg = $a2; body = '' }) 'a1' $null 0 } $st $arg }
    It 'queues the runbook to run after the reply (auto mode), and refuses unknown names' {
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'
        $r = & $act $s 'day-01'
        $r.ok | Should Be $true
        $r.output | Should Match 'runs right after this reply'
        $queued = @($s.Tasks.ToArray())
        $queued.Count | Should Be 1
        $queued[0].kind | Should Be 'runbook'
        $queued[0].name | Should Be 'day-01'
        $bad = & $act $s 'day-99'
        $bad.ok | Should Be $false
        $bad.output | Should Match "no runbook named 'day-99'.*day-01"
        @($s.Tasks.ToArray()).Count | Should Be 1
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
