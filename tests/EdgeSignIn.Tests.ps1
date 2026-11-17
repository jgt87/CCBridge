# Edge policy BrowserSignin = 2 (forced browser sign-in), ported from the sister project ObsidiNote:
# the policy check, the profile's account type, Edge holding the profile without the debug port, the
# one-time profile sign-in, the forced sign-in block and the navigation guard. No real Edge, registry
# or Edge profile: every read is replaced through a parameter, profiles are temporary folders.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Cdp.psm1') -Force
Import-Module (Join-Path $root 'lib\Prereq.psm1') -Force
$profileDir = Join-Path $env:TEMP ('ccb-edgesignin-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

Describe 'Forced browser sign-in policy (Test-EdgeForcedSignIn)' {
    It 'is on only for BrowserSignin = 2' {
        Test-EdgeForcedSignIn -GetPolicy { param($n) if ($n -eq 'BrowserSignin') { 2 } else { $null } } | Should Be $true
        Test-EdgeForcedSignIn -GetPolicy { param($n) 1 } | Should Be $false
        Test-EdgeForcedSignIn -GetPolicy { param($n) 0 } | Should Be $false
        Test-EdgeForcedSignIn -GetPolicy { param($n) $null } | Should Be $false
    }
}

Describe 'Account type of an Edge profile (Get-EdgeProfileAccount)' {
    $null = New-Item -ItemType Directory -Force -Path $profileDir
    $ls = Join-Path $profileDir 'Local State'
    It 'tells work, personal, none and unknown apart' {
        [IO.File]::WriteAllText($ls, '{ "profile": { "info_cache": { "Default": { "edge_account_type": 2, "edge_account_tenant_id": "11111111-2222-3333-4444-555555555555" } } } }')
        Get-EdgeProfileAccount -ProfileDir $profileDir | Should Be 'work'
        [IO.File]::WriteAllText($ls, '{ "profile": { "info_cache": { "Default": { "edge_account_tenant_id": "11111111-2222-3333-4444-555555555555" } } } }')
        Get-EdgeProfileAccount -ProfileDir $profileDir | Should Be 'work'
        [IO.File]::WriteAllText($ls, '{ "profile": { "info_cache": { "Default": { "edge_account_type": 1, "edge_account_tenant_id": "9188040d-6c67-4c5b-b112-36a304b66dad" } } } }')
        Get-EdgeProfileAccount -ProfileDir $profileDir | Should Be 'personal'
        [IO.File]::WriteAllText($ls, '{ "profile": { "info_cache": { "Default": { "edge_account_type": 0 } } } }')
        Get-EdgeProfileAccount -ProfileDir $profileDir | Should Be 'none'
        [IO.File]::WriteAllText($ls, '{ "profile": { "info_cache": { } } }')
        Get-EdgeProfileAccount -ProfileDir $profileDir | Should Be 'unknown'
        Get-EdgeProfileAccount -ProfileDir (Join-Path $profileDir 'missing') | Should Be 'unknown'
    }
    It 'returns the type only, never a name or address from Local State' {
        [IO.File]::WriteAllText($ls, '{ "profile": { "info_cache": { "Default": { "edge_account_type": 2, "user_name": "someone@example.com", "gaia_name": "Some One" } } } }')
        Get-EdgeProfileAccount -ProfileDir $profileDir | Should Be 'work'
    }
    Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Edge holding the profile without the debug port (Get-EdgeProfileUse)' {
    $dir = 'C:\Data\CCBridge\edge-profile'
    $p = { param($cmd, $id = 100) [pscustomobject]@{ ProcessId = $id; CommandLine = $cmd } }
    It 'finds no Edge for the profile' {
        (Get-EdgeProfileUse -ProfileDir $dir -Port 9333 -Processes @()).state | Should Be 'none'
        (Get-EdgeProfileUse -ProfileDir $dir -Port 9333 -Processes @((& $p '"msedge.exe" --profile-directory=Default'))).state | Should Be 'none'
        (Get-EdgeProfileUse -ProfileDir $dir -Port 9333 -Processes @((& $p "msedge.exe --user-data-dir=`"$dir-old`""))).state | Should Be 'none'
    }
    It 'sees StreamHub''s Edge with the debug port, quoted or not' {
        (Get-EdgeProfileUse -ProfileDir $dir -Port 9333 -Processes @((& $p "msedge.exe --remote-debugging-port=9333 --user-data-dir=`"$dir`" --no-first-run"))).state | Should Be 'debug'
        (Get-EdgeProfileUse -ProfileDir $dir -Port 9333 -Processes @((& $p "msedge.exe --user-data-dir=$dir --remote-debugging-port=9333"))).state | Should Be 'debug'
    }
    It 'sees the profile open without the port, or with another port, and names its processes' {
        $u = Get-EdgeProfileUse -ProfileDir $dir -Port 9333 -Processes @((& $p "msedge.exe --user-data-dir=`"$dir`" https://m365.cloud.microsoft/chat" 4242))
        $u.state | Should Be 'no-debug'
        @($u.pids) -join ',' | Should Be '4242'
        (Get-EdgeProfileUse -ProfileDir $dir -Port 9333 -Processes @((& $p "msedge.exe --remote-debugging-port=9400 --user-data-dir=`"$dir`""))).state | Should Be 'no-debug'
    }
    It 'leaves helper processes out' {
        $procs = @((& $p "msedge.exe --type=renderer --user-data-dir=`"$dir`""))
        (Get-EdgeProfileUse -ProfileDir $dir -Port 9333 -Processes $procs).state | Should Be 'none'
    }
}

Describe 'Navigation guard (Test-CopilotNavigateAllowed)' {
    It 'sends an empty tab to Copilot on every attempt' {
        Test-CopilotNavigateAllowed -Url 'about:blank' | Should Be $true
        Test-CopilotNavigateAllowed -Url 'edge://newtab/' | Should Be $true
        Test-CopilotNavigateAllowed -Url '' | Should Be $true
    }
    It 'never navigates a tab already on Copilot' {
        Test-CopilotNavigateAllowed -Url 'https://m365.cloud.microsoft/chat' -IsCopilot -FirstAttempt | Should Be $false
    }
    It 'never sends Microsoft''s sign-in back to Copilot, also on the first attempt' {
        foreach ($u in 'https://login.microsoftonline.com/common/oauth2/v2.0/authorize?x=1', 'https://login.live.com/', 'https://login.microsoft.com/x', 'https://login.windows.net/x') {
            Test-CopilotNavigateAllowed -Url $u -FirstAttempt | Should Be $false
        }
    }
    It 'sends another web page only on the first attempt (later it is a sign-in on its way)' {
        Test-CopilotNavigateAllowed -Url 'https://sso.example.org/adfs/ls' -FirstAttempt | Should Be $true
        Test-CopilotNavigateAllowed -Url 'https://sso.example.org/adfs/ls' | Should Be $false
    }
    It 'does not mistake a look-alike host for Microsoft''s sign-in' {
        Test-CopilotNavigateAllowed -Url 'https://login.microsoftonline.com.example.org/' -FirstAttempt | Should Be $true
    }
}

Describe 'Copilot window closed by forced sign-in (Test-ForcedSignInBlock)' {
    It 'is a block only with the policy, no work account and no web page left' {
        Test-ForcedSignInBlock -ProfileDir 'C:\fake' -GetForced { $true } -GetAccount { 'none' } -GetPageCount { 0 } | Should Be $true
        Test-ForcedSignInBlock -ProfileDir 'C:\fake' -GetForced { $false } -GetAccount { 'none' } -GetPageCount { 0 } | Should Be $false
        Test-ForcedSignInBlock -ProfileDir 'C:\fake' -GetForced { $true } -GetAccount { 'work' } -GetPageCount { 0 } | Should Be $false
        Test-ForcedSignInBlock -ProfileDir 'C:\fake' -GetForced { $true } -GetAccount { 'unknown' } -GetPageCount { 1 } | Should Be $false
    }
    It 'names the policy and what to do in its message' {
        Get-ForcedSignInMessage | Should Match 'BrowserSignin = 2'
        Get-ForcedSignInMessage | Should Match 'sign in to Edge itself with your work account'
        Get-ProfileInUseMessage 9333 | Should Match 'port 9333'
    }
}

Describe 'One-time Edge sign-in (Invoke-EdgeProfileSignIn)' {
    It 'does nothing when the profile already has a work account' {
        $script:starts = 0
        $r = Invoke-EdgeProfileSignIn -ProfileDir $profileDir -Port 9333 -GetAccount { 'work' } -GetUse { [pscustomobject]@{ state = 'none'; pids = @() } } -StartEdge { $script:starts++ } -StopEdge { }
        $r.ok | Should Be $true
        $r.started | Should Be $false
        $script:starts | Should Be 0
    }
    It 'starts Edge without the debug port, waits for the work account, then closes that Edge' {
        $script:polls = 0; $script:started = $null; $script:stopped = @()
        $r = Invoke-EdgeProfileSignIn -ProfileDir $profileDir -Port 9333 -PollMs 1 `
            -GetAccount { $script:polls++; if ($script:polls -ge 4) { 'work' } else { 'none' } } `
            -GetUse { if ($script:polls -ge 4) { [pscustomobject]@{ state = 'no-debug'; pids = @(4242) } } else { [pscustomobject]@{ state = 'none'; pids = @() } } } `
            -StartEdge { param($d) $script:started = $d } `
            -StopEdge { param($ids) $script:stopped += $ids }
        $r.ok | Should Be $true
        $r.started | Should Be $true
        $script:started | Should Be $profileDir
        @($script:stopped) -join ',' | Should Be '4242'
    }
    It 'closes an Edge that already holds the profile before starting the sign-in' {
        $script:stopped = @(); $script:n = 0
        $r = Invoke-EdgeProfileSignIn -ProfileDir $profileDir -Port 9333 -PollMs 1 `
            -GetAccount { $script:n++; if ($script:n -ge 3) { 'work' } else { 'none' } } `
            -GetUse { if ($script:n -le 1) { [pscustomobject]@{ state = 'debug'; pids = @(77) } } else { [pscustomobject]@{ state = 'none'; pids = @() } } } `
            -StartEdge { } -StopEdge { param($ids) $script:stopped += $ids }
        $r.ok | Should Be $true
        @($script:stopped) -join ',' | Should Be '77'
    }
    It 'gives up after the timeout with what to do, without throwing' {
        $r = Invoke-EdgeProfileSignIn -ProfileDir $profileDir -Port 9333 -TimeoutSec 1 -PollMs 100 `
            -GetAccount { 'none' } -GetUse { [pscustomobject]@{ state = 'none'; pids = @() } } -StartEdge { } -StopEdge { }
        $r.ok | Should Be $false
        $r.detail | Should Match 'was not signed in within 1 s'
    }
    Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'System check row for forced sign-in (Get-EdgeSignInCheck)' {
    It 'is OK without the policy' {
        $c = Get-EdgeSignInCheck -Forced $false
        $c.name | Should Be 'Edge sign-in policy'
        $c.status | Should Be 'OK'
    }
    It 'is OK with the policy when the profile has a work account' {
        (Get-EdgeSignInCheck -Forced $true -Account 'work').status | Should Be 'OK'
    }
    It 'warns with the policy and no work account, naming the policy and what to do' {
        foreach ($a in 'none', 'personal', 'unknown') {
            $c = Get-EdgeSignInCheck -Forced $true -Account $a
            $c.status | Should Be 'WARN'
            $c.detail | Should Match 'BrowserSignin = 2'
            $c.hint | Should Match 'sign in to Edge with your work account'
        }
    }
}
