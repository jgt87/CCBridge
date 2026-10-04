<#
.SYNOPSIS
    Turns on single sign-on with your Windows work account in StreamHub's Edge profile, so Copilot
    signs in by itself after a restart (no password stored anywhere). The same as Settings >
    Sign-in > Run setup in the app.
.DESCRIPTION
    Checks this PC (joined to Microsoft Entra ID with a work account token; dsregcmd /status, only
    its yes/no fields), finds Edge's switch "Allow single sign-on for work or school sites using
    this profile" in StreamHub's Edge profile and turns it on after you confirm (-Yes skips the
    question). Writes C:\temp\StreamHub-sso-<date>.txt: what was found and which of Edge's sign-in
    settings changed (names and values only; no account names, ids or tokens). Only StreamHub's own
    profile is touched; your normal Edge and Edge policies stay as they are. -Off turns it off.
.EXAMPLE
    sso-setup.cmd
    sso-setup.cmd -Yes
    sso-setup.cmd -Off
#>
param([switch]$Yes, [switch]$Off, [string]$OutRoot = 'C:\temp')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'Log', 'Cdp', 'Config', 'Sso') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }
$sel = Get-CCBridgeConfig selectors $root
$cfg = Get-CCBridgeConfig harness $root
$port = if ($cfg.cdpPort) { [int]$cfg.cdpPort } else { 9333 }
$null = Start-CdpEdge -Port $port -Url $sel.chatUrl
$word = if ($Off) { 'off' } else { 'on' }
$confirm = if ($Yes) { $null } else { { (Read-Host "Turn single sign-on for work or school sites $word in StreamHub's Edge profile? (y/n)") -match '^(y|j)' } }
$r = Invoke-SsoSetup -Port $port -On (-not $Off) -Confirm $confirm -OutRoot $OutRoot
foreach ($l in $r.Lines) { Write-Host $l }
Write-Host ''
Write-Host "Result: $($r.Result). Log: $($r.LogFile) (send it if something did not work)" -ForegroundColor $(if ($r.Result -in 'turned on', 'already on', 'turned off', 'already off') { 'Green' } else { 'Yellow' })
