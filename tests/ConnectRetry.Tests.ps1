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

# The sign-in in the Copilot tab does not hold up the worker: the connect task returns while the
# person signs in, the idle worker looks for the message box, and the project is got ready meanwhile.
Describe 'Signing in to Copilot while the worker goes on' {
    $newState = {
        Mock -ModuleName Agent Update-CopilotTheme { }
        Mock -ModuleName Agent Test-ResponseOptionsDue { $false }
        Mock -ModuleName Agent Test-CopilotPage { @() }
        Mock -ModuleName Agent Disconnect-Copilot { }
        $st = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        & (Get-Module Agent) { $script:Bridge = $null; $script:PendingBridge = $null }
        $st
    }
    $pending = { & (Get-Module Agent) { $script:PendingBridge } }

    It 'returns from the connect task while the person still has to sign in' {
        $s = & $newState
        Mock -ModuleName Agent Connect-Copilot { [pscustomobject]@{ Session = $null; SignInPending = $true } }
        & (Get-Module Agent) { param($st) Start-CopilotConnect $st } $s
        Assert-MockCalled -ModuleName Agent Connect-Copilot -Scope It -Times 1 -Exactly -ParameterFilter { $NoSignInWait }
        $s.Copilot | Should Be 'connecting'
        $s.CopilotMessage | Should Match 'Sign in to Copilot in its tab'
        & $pending | Should Not BeNullOrEmpty
        ([datetime]$s.SignInDeadline - (Get-Date)).TotalSeconds | Should BeGreaterThan 300
    }
    It 'is ready at once when already signed in' {
        $s = & $newState
        Mock -ModuleName Agent Connect-Copilot { [pscustomobject]@{ Session = $null; SignInPending = $false } }
        & (Get-Module Agent) { param($st) Start-CopilotConnect $st } $s
        $s.Copilot | Should Be 'ready'
        & $pending | Should BeNullOrEmpty
        $s.SignInDeadline | Should BeNullOrEmpty
    }
    It 'notices the sign-in while idle' {
        $s = & $newState
        Mock -ModuleName Agent Connect-Copilot { [pscustomobject]@{ Session = $null; SignInPending = $true } }
        & (Get-Module Agent) { param($st) Start-CopilotConnect $st } $s
        Mock -ModuleName Agent Wait-CopilotEditor { $false }
        & (Get-Module Agent) { param($st) Update-PendingSignIn $st } $s
        $s.Copilot | Should Be 'connecting'
        Mock -ModuleName Agent Wait-CopilotEditor { $true }
        & (Get-Module Agent) { param($st) Update-PendingSignIn $st } $s
        $s.Copilot | Should Be 'ready'
        & $pending | Should BeNullOrEmpty
        & (Get-Module Agent) { [bool]$script:Bridge } | Should Be $true
        Assert-MockCalled -ModuleName Agent Disconnect-Copilot -Scope It -Times 0 -Exactly
    }
    It 'gives up when the time for signing in has passed, and retries later' {
        $s = & $newState
        Mock -ModuleName Agent Connect-Copilot { [pscustomobject]@{ Session = $null; SignInPending = $true } }
        Mock -ModuleName Agent Wait-CopilotEditor { $false }
        & (Get-Module Agent) { param($st) Start-CopilotConnect $st } $s
        $s.SignInDeadline = (Get-Date).AddSeconds(-1)
        & (Get-Module Agent) { param($st) Update-PendingSignIn $st } $s
        $s.Copilot | Should Be 'error'
        $s.CopilotMessage | Should Match 'not signed in'
        $s.ConnectFailures | Should Be 1
        $s.NextConnectAttempt | Should Not BeNullOrEmpty
        & $pending | Should BeNullOrEmpty
    }
    It 'attaches again when a sign-in redirect replaced the tab, within the same time' {
        $s = & $newState
        Mock -ModuleName Agent Connect-Copilot { [pscustomobject]@{ Session = $null; SignInPending = $true } }
        & (Get-Module Agent) { param($st) Start-CopilotConnect $st } $s
        $deadline = [datetime]$s.SignInDeadline
        Mock -ModuleName Agent Wait-CopilotEditor { throw 'The connection to the tab was lost' }
        & (Get-Module Agent) { param($st) Update-PendingSignIn $st } $s
        Assert-MockCalled -ModuleName Agent Connect-Copilot -Scope It -Times 2 -Exactly
        [datetime]$s.SignInDeadline | Should Be $deadline
        & $pending | Should Not BeNullOrEmpty
        $s.Copilot | Should Be 'connecting'
    }
    It 'lets a task that needs Copilot wait for the sign-in' {
        $s = & $newState
        Mock -ModuleName Agent Connect-Copilot { [pscustomobject]@{ Session = $null; SignInPending = $true } }
        & (Get-Module Agent) { param($st) Start-CopilotConnect $st } $s
        Mock -ModuleName Agent Wait-CopilotEditor { $true }
        $b = & (Get-Module Agent) { param($st) Get-Bridge $st } $s
        $b.SignInPending | Should Be $true
        $s.Copilot | Should Be 'ready'
        Assert-MockCalled -ModuleName Agent Connect-Copilot -Scope It -Times 1 -Exactly
    }
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
