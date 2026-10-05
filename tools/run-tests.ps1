<#
.SYNOPSIS
    Runs the whole Pester suite the way it has to run: in Windows PowerShell 5.1 with its own module
    paths (PowerShell 7's paths make some tests fail falsely). Exit code 1 when a test fails.
    Used by build-release.ps1 as the release gate.
#>
param([string]$Path)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
if (-not $Path) { $Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests' }
$r = Invoke-Pester $Path -PassThru -Quiet
Write-Host "tests: $($r.PassedCount) passed, $($r.FailedCount) failed"
if ($r.FailedCount) {
    $r.TestResult | Where-Object { -not $_.Passed } | ForEach-Object { Write-Host "  FAILED: $($_.Describe) / $($_.Name)" -ForegroundColor Red }
    exit 1
}
