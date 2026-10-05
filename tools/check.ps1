<#
.SYNOPSIS
    Checks whether this computer has everything StreamHub needs, and shows the status of each part.
.DESCRIPTION
    Runs by itself (check.cmd), after installing (install.ps1) and at every start (ccbridge.ps1,
    without the online checks). Repairs what is safe (a busy port, OneDrive sign-in; -NoFix only
    reports) and names where to download what is missing. Exit code 1 when a check failed.
.EXAMPLE
    check.cmd
#>
param([switch]$Offline, [switch]$Quiet, [switch]$NoFix, [ValidateSet('', 'python', 'pytest', 'node', 'dotnet', 'git')][string]$Install = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Prereq.psm1') -Force
Import-Module (Join-Path $root 'lib\ToolInstall.psm1') -Force
# check.cmd -Install NAME: one optional tool for your user (no admin rights), then the check.
if ($Install) { & (Join-Path $root 'tools\install-tool.ps1') -Name $Install; Write-Host '' }
Add-ToolPaths   # tools StreamHub installed for this user count too
$port = 8765; $cdp = 9333
try {
    Import-Module (Join-Path $root 'lib\Config.psm1') -Force
    $cfg = Get-CCBridgeConfig harness $root
    if ($cfg.port) { $port = [int]$cfg.port }; if ($cfg.cdpPort) { $cdp = [int]$cfg.cdpPort }
} catch { }
$checks = Get-PrereqChecks -WebPort $port -CdpPort $cdp -Online:(-not $Offline) -Tools
# Safe repairs: a busy port gets a free one, OneDrive opens to sign in (-NoFix only reports).
if (-not $NoFix) { $checks = @(Repair-PrereqChecks $checks -AppRoot $root -WebPort $port -CdpPort $cdp) }
$ok = Write-PrereqReport $checks
Write-Host ''
$optional = @($checks | Where-Object { $_.status -in 'INFO', 'WARN' -and $_.name -in 'Python', 'Node.js', '.NET SDK', 'Git' })
# Newer releases of tools that are installed (the official sources; skipped offline).
if (-not $Offline) {
    foreach ($u in @(try { Get-InstallableTools | Where-Object { $_.update } } catch { })) {
        Write-Host "Update available: $($u.label) $(Get-VersionNumber $u.detail) -> $($u.latest)$(if ($u.canInstall) { " (check.cmd -Install $($u.name))" } else { " ($($u.hint -replace '^Newer: [^ ]+ ', ''))" })" -ForegroundColor Cyan
    }
}
if ($optional.Count) { Write-Host "Optional tools can be installed for your user (no admin rights): check.cmd -Install python, pytest, node, dotnet or git, or in StreamHub under Settings > This computer." -ForegroundColor Cyan }
if ($ok) { Write-Host 'Everything StreamHub needs is in place.' -ForegroundColor Green }
else { Write-Host 'StreamHub cannot work until the FAIL items are fixed.' -ForegroundColor Red }
if (-not $ok) { exit 1 }
