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