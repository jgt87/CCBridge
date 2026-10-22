# Copilot not connected at start (Edge closed, signed out, no network): the idle worker tries again,
# waiting longer each time, and stops by itself after about an hour; a success or a Retry in the app
# starts the count over.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Agent', 'Config') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

Describe 'Retrying the Copilot connection' {
    It 'waits 30 s, 1 min, 2 min, 5 min, then 10 min, and stops after the eighth failure' {
        $waits = & (Get-Module Agent) { @(1..8 | ForEach-Object { Get-ConnectRetryDelay $_ }) }
        $waits[0..6] -join ',' | Should Be '30,60,120,300,600,600,600'
        $waits[7] | Should BeNullOrEmpty
    }
    It 'counts failures, schedules the next try, and after the last says how to try again' {
        Mock -ModuleName Agent Connect-Copilot { throw 'Could not connect to the Copilot tab.' }
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $before = Get-Date
        { & (Get-Module Agent) { param($st) Get-Bridge $st } $s } | Should Throw 'Could not connect'
        $s.ConnectFailures | Should Be 1
        $s.Copilot | Should Be 'error'
        ([datetime]$s.NextConnectAttempt - $before).TotalSeconds | Should BeGreaterThan 29
        for ($n = 2; $n -le 8; $n++) { try { & (Get-Module Agent) { param($st) Get-Bridge $st } $s } catch { } }
        $s.ConnectFailures | Should Be 8
        $s.NextConnectAttempt | Should BeNullOrEmpty
        $s.CopilotMessage | Should Match 'stopped trying by itself after 8 attempts: press Check connection, or send a message'
        # The page gets no retry time any more: it shows the Check connection button.
        Import-Module (Join-Path $root 'lib\Server.psm1') -Force
        (& (Get-Module Server) { param($st) Get-StateSnapshot $st } $s).copilotRetryAt | Should Be ''
    }
    It 'starts the count over when it connects' {
        Mock -ModuleName Agent Connect-Copilot { [pscustomobject]@{ Session = $null } }
        Mock -ModuleName Agent Update-CopilotTheme { }
        Mock -ModuleName Agent Test-ResponseOptionsDue { $false }
        Mock -ModuleName Agent Test-CopilotPage { @() }
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $s.ConnectFailures = 5
        $null = & (Get-Module Agent) { param($st) $script:Bridge = $null; Get-Bridge $st } $s
        $s.Copilot | Should Be 'ready'
        $s.ConnectFailures | Should Be 0
    }
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
