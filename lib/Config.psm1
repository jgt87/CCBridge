# Settings: config\<name>.json ships with CCBridge; config\<name>.local.json holds this machine's
# overrides (for example the Work IQ selector) and is never touched by updates.

$ErrorActionPreference = 'Stop'

function Merge-JsonObject($Base, $Override) {
    foreach ($p in $Override.PSObject.Properties) {
        $current = $Base.PSObject.Properties[$p.Name]
        if ($current -and $current.Value -is [pscustomobject] -and $p.Value -is [pscustomobject]) {
            Merge-JsonObject $current.Value $p.Value
        } else {
            $Base | Add-Member -Force -NotePropertyName $p.Name -NotePropertyValue $p.Value
        }
    }
}

function Get-CCBridgeConfig {
    <# Returns config\<Name>.json merged with config\<Name>.local.json (if present). #>
    param([Parameter(Mandatory)][ValidateSet('harness', 'selectors')][string]$Name, [string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $dir = Join-Path $AppRoot 'config'
    $config = Get-Content (Join-Path $dir "$Name.json") -Raw | ConvertFrom-Json
    $local = Join-Path $dir "$Name.local.json"
    if (Test-Path $local) {
        $override = Get-Content $local -Raw | ConvertFrom-Json
        if ($override) { Merge-JsonObject $config $override }
    }
    $config
}

function Get-CCBridgeVersion([string]$AppRoot) {
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $v = Join-Path $AppRoot 'version.txt'
    if (Test-Path $v) { return ([IO.File]::ReadAllText($v)).Trim() }
    try { $sha = & git -C $AppRoot rev-parse --short HEAD 2>$null; if ($sha) { return "git-$sha" } } catch { }
    'dev'
}

function Set-CCBridgeLocalSetting {
    <# Writes one setting into config\<Name>.local.json (kept across updates). #>
    param([Parameter(Mandatory)][ValidateSet('harness', 'selectors')][string]$Name, [Parameter(Mandatory)][string]$Key, $Value, [string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $file = Join-Path $AppRoot "config\$Name.local.json"
    $obj = if (Test-Path $file) { Get-Content $file -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    if (-not $obj) { $obj = [pscustomobject]@{} }
    $obj | Add-Member -Force -NotePropertyName $Key -NotePropertyValue $Value
    [IO.File]::WriteAllText($file, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
}

function Get-CCBridgeEnvironment {
    <# Facts that help diagnose a machine; no personal data. #>
    param([string]$AppRoot)
    if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    $harness = Get-CCBridgeConfig harness $AppRoot
    $sel = Get-CCBridgeConfig selectors $AppRoot
    [ordered]@{
        ccbridge = Get-CCBridgeVersion $AppRoot
        installKind = $(if (Test-Path (Join-Path $AppRoot '.git')) { 'git' } elseif (Test-Path (Join-Path $AppRoot 'version.txt')) { 'release' } else { 'copy' })
        powershell = $PSVersionTable.PSVersion.ToString()
        languageMode = $ExecutionContext.SessionState.LanguageMode.ToString()
        os = [Environment]::OSVersion.VersionString
        culture = (Get-Culture).Name
        edge = $(if ($edge) { (Get-Item $edge).VersionInfo.ProductVersion } else { 'not found' })
        oneDrive = [ordered]@{ commercial = [bool]$env:OneDriveCommercial; consumer = [bool]$env:OneDriveConsumer; oneDrive = [bool]$env:OneDrive
            used = $(if ($env:OneDriveCommercial -and (Test-Path $env:OneDriveCommercial)) { 'OneDriveCommercial' } elseif ($env:OneDrive -and (Test-Path $env:OneDrive)) { 'OneDrive' } elseif ($env:OneDriveConsumer -and (Test-Path $env:OneDriveConsumer)) { 'OneDriveConsumer' } else { 'none' }) }
        localOverrides = @(Get-ChildItem (Join-Path $AppRoot 'config') -Filter '*.local.json' -ErrorAction SilentlyContinue | ForEach-Object Name)
        settings = [ordered]@{ port = $harness.port; cdpPort = $harness.cdpPort; workIq = $harness.workIq; autoUpdate = $harness.autoUpdate; saveReplyFrames = $harness.saveReplyFrames; promptCharBudget = $harness.promptCharBudget; maxRounds = $harness.maxRounds }
        workIqToggleConfigured = [bool]$sel.workIq.toggle
    }
}

Export-ModuleMember -Function Get-CCBridgeConfig, Get-CCBridgeVersion, Set-CCBridgeLocalSetting, Get-CCBridgeEnvironment
