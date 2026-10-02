# CCBridge installer: downloads the latest release from GitHub into
# %LOCALAPPDATA%\Programs\CCBridge (no admin rights) and adds Start menu and desktop shortcuts.
# Run it again any time to update. CCBridge also updates itself when it starts.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/jgt87/CCBridge/main/install.ps1 | iex"
#
# Optional: set $env:CCBRIDGE_DIR to install somewhere else.

$ErrorActionPreference = 'Stop'
$repo = 'jgt87/CCBridge'
$dir = if ($env:CCBRIDGE_DIR) { $env:CCBRIDGE_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\CCBridge' }

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if ([Net.WebRequest]::DefaultWebProxy) { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials }

Write-Host "Installing StreamHub into $dir" -ForegroundColor Cyan
$release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'CCBridge-installer' }
$asset = @($release.assets | Where-Object { $_.name -like 'CCBridge-*.zip' }) | Select-Object -First 1
if (-not $asset) { throw "The latest release ($($release.tag_name)) has no StreamHub zip." }

$tmp = Join-Path $env:TEMP ('ccbridge-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp
try {
    $zip = Join-Path $tmp $asset.name
    Write-Host "Downloading $($release.tag_name)..."
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $src = Join-Path $tmp 'CCBridge'
    $null = New-Item -ItemType Directory -Force -Path $dir
    # Mirror the release in; settings in config\*.local.json are kept.
    $null = & robocopy.exe $src $dir /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XF '*.local.json' 'capture-report.json' 'probe-report.txt' /XD '.git'
    if ($LASTEXITCODE -ge 8) { throw "copying files failed (robocopy code $LASTEXITCODE)" }
} finally {
    [IO.Directory]::Delete($tmp, $true)
}

# Shortcuts: Start menu and desktop (skip with $env:CCBRIDGE_NO_SHORTCUTS = '1').
$shell = New-Object -ComObject WScript.Shell
$targets = @(
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'StreamHub.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'StreamHub.lnk')
)
if ($env:CCBRIDGE_NO_SHORTCUTS -eq '1') { $targets = @() }
# Shortcuts from before the rename (CCBridge.lnk) are replaced by the StreamHub ones.
foreach ($old in (Join-Path ([Environment]::GetFolderPath('Programs')) 'CCBridge.lnk'), (Join-Path ([Environment]::GetFolderPath('Desktop')) 'CCBridge.lnk')) { if ($targets.Count -and (Test-Path -LiteralPath $old)) { [IO.File]::Delete($old) } }
foreach ($lnkPath in $targets) {
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = Join-Path $dir 'start.cmd'
    $lnk.WorkingDirectory = $dir
    $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
    $lnk.Description = 'StreamHub - coding with Microsoft 365 Copilot Chat'
    $lnk.Save()
}

Write-Host ''
Write-Host "StreamHub $($release.tag_name) is installed." -ForegroundColor Green
Write-Host '  Start it:  StreamHub shortcut on the desktop or in the Start menu'
Write-Host '  Updates:   automatic each time StreamHub starts (turn off with "autoUpdate": false in config\harness.local.json)'
Write-Host '  MCP:       register in your MCP client with'
Write-Host "             powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$dir\mcp\ccbridge-mcp.ps1`""
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Host "             or: claude mcp add ccbridge -s user -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$dir\mcp\ccbridge-mcp.ps1`""
}
