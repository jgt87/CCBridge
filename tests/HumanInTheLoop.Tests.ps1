# Human in the loop: Microsoft 365 actions and data deletion always need a person.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
Import-Module (Join-Path $root 'lib\CopilotBridge.psm1') -Force
Import-Module (Join-Path $root 'lib\Agent.psm1') -Force

Describe 'Get-CommandRisk' {
    It 'flags commands that act on Microsoft 365' {
        foreach ($c in @(
            'powershell -c "Send-MailMessage -To a@b.c -Subject x -SmtpServer smtp.contoso.com"',
            'powershell -c "$o = New-Object -ComObject Outlook.Application; $o.CreateItem(0).Send()"',
            'powershell -c "Connect-MgGraph; Remove-MgUserEvent -UserId me -EventId 1"',
            'curl -X POST https://graph.microsoft.com/v1.0/me/sendMail',
            'pwsh -c "Connect-MicrosoftTeams; Remove-Team -GroupId x"',
            'powershell -c "Connect-PnPOnline https://contoso.sharepoint.com"')) {
            (Get-CommandRisk $c).m365 | Should Be $true
        }
    }

    It 'flags commands that delete data' {
        foreach ($c in @('del /q data\*.json', 'rd /s /q output', 'powershell -c "Remove-Item -Recurse x"', 'rm -rf build', 'git clean -fdx', 'robocopy a b /MIR')) {
            (Get-CommandRisk $c).destructive | Should Be $true
        }
    }

    It 'leaves ordinary build and test commands alone' {
        foreach ($c in @('dotnet build', 'npm test', 'powershell -NoProfile -Command Invoke-Pester .\tests', 'python -m pytest', 'git status', 'echo deleted > log.txt')) {
            $r = Get-CommandRisk $c
            ($r.m365 -or $r.destructive) | Should Be $false
        }
    }
}

Describe 'Microsoft 365 action proposals in replies' {
    $bridge = Get-Module CopilotBridge

    It 'finds confirmation buttons in adaptive cards and action messages' {
        $item = @'
{"messages":[
 {"author":"bot","text":"Here is a draft.","adaptiveCards":[{"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"To: Anna"}],"actions":[{"type":"Action.Submit","title":"Send"},{"type":"Action.OpenUrl","title":"Open in Outlook"}]}]},
 {"author":"bot","messageType":"ActionConfirmation","text":"Cancel the meeting Weekly sync?"},
 {"author":"bot","messageType":"HintInvocation"},
 {"author":"bot","messageType":"Progress","text":"Working"}]}
'@ | ConvertFrom-Json
        $found = @(& $bridge { param($i) Get-ProposedActions $i } $item)
        $found.Count | Should Be 2
        ($found | Where-Object kind -eq 'button').title | Should Be 'Send'
        ($found | Where-Object kind -eq 'ActionConfirmation').title | Should Match 'Weekly sync'
    }

    It 'reports nothing for an ordinary reply' {
        $item = '{"messages":[{"author":"bot","text":"Done.","adaptiveCards":[{"type":"AdaptiveCard","body":[{"type":"TextBlock","text":"Done."}]}]}]}' | ConvertFrom-Json
        @(& $bridge { param($i) Get-ProposedActions $i } $item).Count | Should Be 0
    }

    It 'notices claims of completed Microsoft 365 actions but not code talk' {
        @(& $bridge { param($t) Get-ActionClaims $t } 'I have sent the email to Anna. The meeting has been cancelled.').Count | Should Be 2
        @(& $bridge { param($t) Get-ActionClaims $t } 'I removed the unused function and moved the helper to utils.ps1.').Count | Should Be 0
    }
}

Describe 'Agent refuses risky commands without a person' {
    It 'refuses a mail-sending command when headless, even in auto mode with commands allowed' {
        $proj = Join-Path $env:TEMP ('ccb-hitl-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $proj | Out-Null
        $cfg = [pscustomobject]@{ commandTimeoutSec = 30; autoApproveCommands = @('.*') }
        $state = New-AgentState -Config $cfg -AppRoot $root
        $state.Headless = $true; $state.AllowCommands = $true; $state.Mode = 'auto'; $state.ProjectRoot = $proj
        $action = [pscustomobject]@{ type = 'run'; arg = ''; body = 'powershell -c "Send-MailMessage -To x@y.z -Subject hi -SmtpServer smtp.x"'; edits = @() }
        $res = & (Get-Module Agent) { param($s, $a) Invoke-AgentAction $s $a 'a1' $null 0 } $state $action
        $res.ok | Should Be $false
        $res.output | Should Match 'need a person'
        @($state.Events | Where-Object { $_.type -eq 'human-required' }).Count | Should Be 1
        Remove-Item $proj -Recurse -Force
    }

    # The command line only names a script: what the script does is read too (Executor Get-RunScripts).
    $newRun = {
        param([string]$Script, [bool]$Headless)
        $proj = Join-Path $env:TEMP ('ccb-hitl-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $proj 'Scripts') | Out-Null
        [IO.File]::WriteAllText((Join-Path $proj 'Scripts\job.ps1'), $Script)
        $cfg = [pscustomobject]@{ commandTimeoutSec = 30; autoApproveCommands = @('.*') }
        $state = New-AgentState -Config $cfg -AppRoot $root
        $state.Headless = $Headless; $state.AllowCommands = $true; $state.Mode = 'auto'; $state.ProjectRoot = $proj
        $action = [pscustomobject]@{ type = 'run'; arg = ''; body = 'powershell -NoProfile -ExecutionPolicy Bypass -File Scripts/job.ps1'; edits = @() }
        $res = & (Get-Module Agent) { param($s, $a) Invoke-AgentAction $s $a 'a1' $null 0 } $state $action
        Remove-Item $proj -Recurse -Force
        @{ res = $res; state = $state }
    }
    It 'refuses a script that sends mail or reaches beyond the project when headless' {
        $r = & $newRun "Send-MailMessage -To x@y.z -Subject hi -SmtpServer smtp.x`n" $true
        $r.res.ok | Should Be $false
        $r.res.output | Should Match 'sends email \(in Scripts/job\.ps1\)'
        $r = & $newRun "Set-ItemProperty HKCU:\Software\X -Name a -Value 1`n" $true
        $r.res.ok | Should Be $false
        $r.res.output | Should Match 'changes the Windows registry \(in Scripts/job\.ps1\).*needs a person'
    }
    It 'asks a person (hold to run) with the whole script on the card, also in auto mode' {
        $global:ccbPersonOnly = $null
        Mock -ModuleName Agent Wait-Approval { param($State, $Id, $PersonOnly) $global:ccbPersonOnly = $PersonOnly; @{ decision = 'reject'; by = 'user'; note = '' } }
        $r = & $newRun "`$dist = `$args[0]`nRemove-Item `$dist -Recurse`nStop-Process -Name excel`n" $false
        $global:ccbPersonOnly | Should Be $true
        $card = @($r.state.Events | Where-Object { $_.type -eq 'action' -and $_.status -eq 'awaiting' })[0]
        $card.preview.path | Should Be 'Scripts/job.ps1'
        $card.preview.new | Should Match 'Stop-Process -Name excel'
        $card.warning | Should Match 'cannot check where this deletes'
        $card.warning | Should Match 'stops other programs \(in Scripts/job\.ps1\)'
    }
}
