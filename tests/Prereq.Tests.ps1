# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Prereq.psm1') -Force

Describe 'Get-PrereqChecks' {
    $checks = @(Get-PrereqChecks -WebPort 8765 -CdpPort 9333)
    It 'checks every part StreamHub needs, each with OK, WARN or FAIL' {
        ($checks | ForEach-Object { $_.name }) -join '|' | Should Match '^Windows PowerShell\|Language mode\|Execution policy\|\.NET Framework\|Microsoft Edge\|Edge remote debugging\|Local web server\|Port 8765 \(web app\)\|Port 9333 \(Edge for Copilot\)\|OneDrive\|Data folder$'
        @($checks | Where-Object { $_.status -notin 'OK', 'WARN', 'FAIL' }).Count | Should Be 0
    }
    It 'gives a hint for everything that is not OK' {
        @($checks | Where-Object { $_.status -ne 'OK' -and -not $_.hint }).Count | Should Be 0
    }
    It 'passes on this development machine (Windows PowerShell 5.1, Edge)' {
        ($checks | Where-Object name -eq 'Windows PowerShell').status | Should Be 'OK'
        ($checks | Where-Object name -eq 'Language mode').status | Should Be 'OK'
        ($checks | Where-Object name -eq 'Microsoft Edge').status | Should Be 'OK'
    }
}

Describe 'Get-DotNetVersionText' {
    It 'names the .NET Framework version from its release number' {
        Get-DotNetVersionText 533325 | Should Be '4.8.1'
        Get-DotNetVersionText 528049 | Should Be '4.8'
        Get-DotNetVersionText 461814 | Should Be '4.7.2'
        Get-DotNetVersionText 100 | Should Be 'older than 4.5'
    }
}

Describe 'Write-PrereqReport' {
    It 'returns whether nothing failed' {
        Write-PrereqReport @([pscustomobject]@{ name = 'A'; status = 'OK'; detail = 'fine'; hint = '' }, [pscustomobject]@{ name = 'B'; status = 'WARN'; detail = 'meh'; hint = 'do x' }) 6>$null | Should Be $true
        Write-PrereqReport @([pscustomobject]@{ name = 'A'; status = 'FAIL'; detail = 'no'; hint = 'fix it' }) 6>$null | Should Be $false
    }
}

Describe 'Invoke-SafeCheck' {
    It 'turns a check that breaks into a WARN instead of an error' {
        $r = & (Get-Module Prereq) { Invoke-SafeCheck 'Broken check' { throw 'module could not load' } }
        $r.status | Should Be 'WARN'
        $r.name | Should Be 'Broken check'
        $r.detail | Should Match 'could not check: module could not load'
    }
}
Describe 'Repair-PrereqChecks' {
    $app = Join-Path $env:TEMP ('ccb-prereq-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $app 'config')
    Copy-Item (Join-Path $root 'config\harness.json') (Join-Path $app 'config\harness.json')
    $local = Join-Path $app 'config\harness.local.json'
    # A port held by "another program" (this test).
    $hold = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, 0); $hold.Start()
    $busy = ([Net.IPEndPoint]$hold.LocalEndpoint).Port

    It 'moves a busy web port to a free one and saves it' {
        $checks = @(Get-PrereqChecks -WebPort $busy -CdpPort 1 | Where-Object { $_.name -like 'Port*web*' })
        $checks[0].status | Should Be 'WARN'
        $checks[0].fix | Should Be 'port'
        $fixed = @(Repair-PrereqChecks $checks -AppRoot $app -WebPort $busy -CdpPort 1)
        $fixed[0].status | Should Be 'OK'
        $fixed[0].detail | Should Match 'fixed: .* now uses port (\d+)'
        $new = [int]([regex]::Match($fixed[0].detail, 'port (\d+)').Groups[1].Value)
        $new | Should Not Be $busy
        ([IO.File]::ReadAllText($local) | ConvertFrom-Json).port | Should Be $new
    }
    It 'keeps a port that was given with -Port' {
        $checks = @(Get-PrereqChecks -WebPort $busy -CdpPort 1 | Where-Object { $_.name -like 'Port*web*' })
        @(Repair-PrereqChecks $checks -AppRoot $app -KeepWebPort -WebPort $busy)[0].status | Should Be 'WARN'
    }
    It 'moves a busy Edge port too, away from the web port' {
        $checks = @(Get-PrereqChecks -WebPort 1 -CdpPort $busy | Where-Object { $_.name -like 'Port*Edge*' })
        $checks[0].fix | Should Be 'cdpPort'
        $fixed = @(Repair-PrereqChecks $checks -AppRoot $app -WebPort ($busy + 1) -CdpPort $busy)
        $fixed[0].status | Should Be 'OK'
        ([IO.File]::ReadAllText($local) | ConvertFrom-Json).cdpPort | Should Not Be ($busy + 1)
    }
    It 'leaves OneDrive alone with -NoLaunch, and never touches policies' {
        $od = [pscustomobject]@{ name = 'OneDrive'; status = 'WARN'; detail = 'not signed in'; hint = 'Sign in.'; link = ''; fix = 'onedrive' }
        $pol = [pscustomobject]@{ name = 'Edge remote debugging'; status = 'FAIL'; detail = 'blocked by policy'; hint = 'ask IT'; link = ''; fix = '' }
        $r = @(Repair-PrereqChecks @($od, $pol) -AppRoot $app -NoLaunch)
        $r[0].detail | Should Be 'not signed in'
        $r[1].status | Should Be 'FAIL'
    }
    It 'prints where to download what is missing' {
        $edge = [pscustomobject]@{ name = 'Microsoft Edge'; status = 'FAIL'; detail = 'msedge.exe not found'; hint = 'Install Edge.'; link = 'https://www.microsoft.com/edge/download'; fix = '' }
        $out = (Write-PrereqReport @($edge) 6>&1 | Out-String)
        $out | Should Match 'Download: https://www\.microsoft\.com/edge/download'
    }
    $hold.Stop()
    Remove-Item -LiteralPath $app -Recurse -Force
}
