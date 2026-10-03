<#
.SYNOPSIS
    Checks whether this computer has everything StreamHub needs, and shows the status of each part.
.DESCRIPTION
    Runs by itself (check.cmd), after installing (install.ps1) and at every start (ccbridge.ps1,
    without the online checks). Read-only. Exit code 1 when a check failed.
.EXAMPLE
    check.cmd
#>
param([switch]$Offline, [switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Prereq.psm1') -Force
$port = 8765; $cdp = 9333
try {
    Import-Module (Join-Path $root 'lib\Config.psm1') -Force
    $cfg = Get-CCBridgeConfig harness $root
    if ($cfg.port) { $port = [int]$cfg.port }; if ($cfg.cdpPort) { $cdp = [int]$cfg.cdpPort }
} catch { }
$checks = Get-PrereqChecks -WebPort $port -CdpPort $cdp -Online:(-not $Offline)
$ok = Write-PrereqReport $checks
Write-Host ''
if ($ok) { Write-Host 'Everything StreamHub needs is in place.' -ForegroundColor Green }
else { Write-Host 'StreamHub cannot work until the FAIL items are fixed.' -ForegroundColor Red }
if (-not $ok) { exit 1 }
