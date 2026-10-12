# Allowing a part of a web site for a project when approving a read: later reads under it need no
# approval. No internet: the fetch and the approval are stood in for. Made-up sites.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-wa-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'WebFetch', 'Agent') { Import-Module (Join-Path $root "lib\$m.psm1") -Force -DisableNameChecking }

Describe 'Which part of a site can be allowed' {
    It 'offers the shared path, the folder above it and the host' {
        @(Get-WebAllowCandidates @('https://www.example.com/docs/guide?id=1', 'https://www.example.com/docs/guide?id=2')) -join ',' | Should Be 'www.example.com/docs/guide,www.example.com/docs,www.example.com'
        @(Get-WebAllowCandidates @('https://docs.example.org/en/guide/a', 'https://docs.example.org/en/guide/b/c')) -join ',' | Should Be 'docs.example.org/en/guide,docs.example.org/en,docs.example.org'
        @(Get-WebAllowCandidates @('https://a.example.com/x', 'https://b.example.com/x')).Count | Should Be 0
    }
    It 'matches whole path segments on the same host' {
        $allowed = @('www.example.com/docs/guide')
        Test-WebAllowed '' 'https://www.example.com/docs/guide?id=9' $allowed | Should Be $true
        Test-WebAllowed '' 'https://WWW.example.com/docs/guide/2026/q1' $allowed | Should Be $true
        Test-WebAllowed '' 'https://www.example.com/docs/guide-old' $allowed | Should Be $false
        Test-WebAllowed '' 'https://www.example.com/products' $allowed | Should Be $false
        Test-WebAllowed '' 'https://evil.example.com/docs/guide' $allowed | Should Be $false
        Test-WebAllowed '' 'https://www.example.com.evil.org/docs/guide' $allowed | Should Be $false
        Test-WebAllowed '' 'https://www.example.com/anything' @('www.example.com') | Should Be $true
    }
}

Describe 'A read approved for a part of a site' {
    $p = Join-Path $env:TEMP ('ccb-wa-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    $config = Get-CCBridgeConfig harness $root
    Mock -ModuleName Agent Invoke-WebFetch { param($Url) [pscustomobject]@{ ok = $true; url = $Url; type = 'text/html'; title = 'Page'; text = 'Some text'; chars = 9 } }
    It 'asks once, keeps the chosen part when the person picks it, and reads under it without asking' {
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'; $s.TurnText = 'Make a page of the guide'
        $s.Approvals['w1'] = @{ decision = 'approve'; note = ''; by = 'user'; allow = 'www.example.com/docs/guide' }
        $r = & (Get-Module Agent) { param($st) Invoke-AgentAction $st ([pscustomobject]@{ type = 'web'; arg = ''; body = "https://www.example.com/docs/guide?id=1`nhttps://www.example.com/docs/guide?id=2" }) 'w1' $null 0 } $s
        $r.ok | Should Be $true
        @($s.Events | Where-Object { $_.type -eq 'action' -and $_.status -eq 'awaiting' }).Count | Should Be 1
        @(Read-WebAllow $p) -join ',' | Should Be 'www.example.com/docs/guide'
        # A later read under it: no approval card, no waiting.
        $before = @($s.Events | Where-Object { $_.status -eq 'awaiting' }).Count
        $r2 = & (Get-Module Agent) { param($st) Invoke-AgentAction $st ([pscustomobject]@{ type = 'web'; arg = ''; body = 'https://www.example.com/docs/guide?id=3' }) 'w2' $null 0 } $s
        $r2.ok | Should Be $true
        @($s.Events | Where-Object { $_.status -eq 'awaiting' }).Count | Should Be $before
    }
    It 'never takes a part it did not offer, or one approved by another program' {
        $s = New-AgentState -Config $config -AppRoot $root; $s.ProjectRoot = $p; $s.Mode = 'auto'; $s.TurnText = 'x'
        $s.Approvals['w3'] = @{ decision = 'approve'; note = ''; by = 'user'; allow = 'other.example.net' }
        $null = & (Get-Module Agent) { param($st) Invoke-AgentAction $st ([pscustomobject]@{ type = 'web'; arg = ''; body = 'https://docs.example.org/a' }) 'w3' $null 0 } $s
        $s.Approvals['w4'] = @{ decision = 'approve'; note = ''; by = 'mcp'; allow = 'docs.example.org' }
        $null = & (Get-Module Agent) { param($st) Invoke-AgentAction $st ([pscustomobject]@{ type = 'web'; arg = ''; body = 'https://docs.example.org/b' }) 'w4' $null 0 } $s
        @(Read-WebAllow $p) -join ',' | Should Be 'www.example.com/docs/guide'
        Remove-WebAllow $p 'www.example.com/docs/guide'
        @(Read-WebAllow $p).Count | Should Be 0
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
