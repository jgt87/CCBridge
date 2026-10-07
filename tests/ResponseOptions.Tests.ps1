# Copilot's response picker options (Advanced reasoning, models...): read weekly or on request
# (Agent Test-ResponseOptionsDue, Update-ResponseOptions; Copilot is mocked).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Agent', 'Config') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

Describe 'When the response options are read again' {
    $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
    $now = [datetime]'2026-10-08T12:00:00'
    It 'reads them when never read, and again after the set number of days' {
        $s.ResponseOptionsRead = ''; $s.ResponseOptionsTried = $null; $s.Config.responseOptionsDays = 7
        Test-ResponseOptionsDue $s $now | Should Be $true
        $s.ResponseOptionsRead = '2026-10-05T09:00:00'
        Test-ResponseOptionsDue $s $now | Should Be $false
        $s.ResponseOptionsRead = '2026-09-30T09:00:00'
        Test-ResponseOptionsDue $s $now | Should Be $true
    }
    It 'only on request with 0 days, and not again within an hour of a failed read' {
        $s.ResponseOptionsRead = '2026-01-01T09:00:00'; $s.Config.responseOptionsDays = 0
        Test-ResponseOptionsDue $s $now | Should Be $false
        $s.Config.responseOptionsDays = 7; $s.ResponseOptionsTried = '2026-10-08T11:30:00'
        Test-ResponseOptionsDue $s $now | Should Be $false
    }
}

Describe 'Reading the response options' {
    $env:CCB_TEST_RO_FILE = Join-Path $env:TEMP ('ccb-ro-' + [guid]::NewGuid().ToString('N') + '.json')
    Mock -ModuleName Agent Get-ResponseOptionsFile { $env:CCB_TEST_RO_FILE }   # a mock runs in the module's scope
    It 'keeps what the picker offers in the state and the file, and says so when asked' {
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        Mock -ModuleName Agent Get-CopilotResponseOptions { @([pscustomobject]@{ path = 'Auto'; title = 'Auto'; description = 'Decides'; parent = '' }, [pscustomobject]@{ path = 'GPT > GPT-6.1 Sol'; title = 'GPT-6.1 Sol'; description = ''; parent = 'GPT' }) }
        Update-ResponseOptions $s ([pscustomobject]@{ Session = $null }) -Report
        @($s.ResponseOptions).Count | Should Be 2
        $s.ResponseOptionsRead | Should Not BeNullOrEmpty
        $saved = & (Get-Module Agent) { Read-ResponseOptionsFile }
        (@($saved.options) | ForEach-Object { $_.path }) -join '|' | Should Be 'Auto|GPT > GPT-6.1 Sol'
        @(Get-AgentEvents $s 0 | Where-Object { $_.text -match "response picker offers: Auto, GPT > GPT-6\.1 Sol" }).Count | Should Be 1
    }
    It 'keeps the old list when the picker cannot be read' {
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $s.ResponseOptions = @(@{ path = 'Auto' }); $s.ResponseOptionsRead = '2026-10-01T09:00:00'
        Mock -ModuleName Agent Get-CopilotResponseOptions { @() }
        Update-ResponseOptions $s ([pscustomobject]@{ Session = $null }) -Report
        $s.ResponseOptionsRead | Should Be '2026-10-01T09:00:00'
        @(Get-AgentEvents $s 0 | Where-Object { $_.type -eq 'error' -and $_.text -match 'Could not read Copilot''s response options' }).Count | Should Be 1
    }
    Remove-Item $env:CCB_TEST_RO_FILE -Force -ErrorAction SilentlyContinue; $env:CCB_TEST_RO_FILE = $null
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
