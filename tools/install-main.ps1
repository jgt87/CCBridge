# StreamHub installer: downloads the latest release from GitHub into
# %LOCALAPPDATA%\Programs\StreamHub (no admin rights) and adds Start menu and desktop shortcuts.
# Run it again any time to update. StreamHub also updates itself when it starts.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/jgt87/StreamHub/main/install.ps1 | iex"
#
# That command fetches the one-line bootstrap install.ps1 in the repo root, which downloads this
# file and runs it with -File (some shells hand a piped script to iex line by line).
#
# Optional: set $env:STREAMHUB_DIR to install somewhere else.
#
# The rename (pre-rename name CCBridge, now StreamHub): this file runs on its own (downloaded to TEMP), so it
# carries its own copy of what lib/Update.psm1 does for the updater: a GitHub request that fails is
# tried once more on the repository's old name, and a release zip of either name is taken. An
# install in the old folder (pre-rename Programs\CCBridge) is updated where it is, on purpose: StreamHub runs
# from that folder and cannot move itself, and MCP client registrations (and any shortcut or task
# a person made) hold its path, so renaming it would break them without a word. New installs go
# to Programs\StreamHub.

$ErrorActionPreference = 'Stop'
$repo = 'jgt87/StreamHub'
function Invoke-GitHubRequest([string]$Url, [scriptblock]$Request) {
    try { return (& $Request $Url) } catch {
        $old = [regex]::Replace($Url, '(?i)(?<=/)jgt87/StreamHub(?=[/?#]|$)', 'jgt87/CCBridge')   # pre-rename repository name
        if ($old -eq $Url) { throw }
        Write-Host "  (GitHub did not answer for $repo; trying the repository's old name)" -ForegroundColor DarkGray
    }
    & $Request $old
}
$dir = if ($env:STREAMHUB_DIR) { $env:STREAMHUB_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\StreamHub' }
$oldDir = Join-Path $env:LOCALAPPDATA 'Programs\CCBridge'   # pre-rename install folder
if (-not $env:STREAMHUB_DIR -and -not (Test-Path -LiteralPath $dir) -and (Test-Path -LiteralPath $oldDir -PathType Container)) {
    $dir = $oldDir
    Write-Host "StreamHub is already installed in $oldDir (its folder name from before the rename): updating it there, so MCP clients and shortcuts that point at it keep working." -ForegroundColor DarkGray
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if ([Net.WebRequest]::DefaultWebProxy) { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials }

# The two things the installer itself needs; the full check runs after the files are in place.
function Write-Status([string]$Status, [string]$Name, [string]$Detail) {
    Write-Host '  [' -NoNewline
    Write-Host $Status -ForegroundColor $(switch ($Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }) -NoNewline
    Write-Host ']' -NoNewline
    Write-Host ((' ' * (5 - $Status.Length)) + $Name.PadRight(22)) -NoNewline
    Write-Host $Detail -ForegroundColor DarkGray
}
Write-Host 'Before installing'
$psOk = $PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5
Write-Status $(if ($psOk) { 'OK' } else { 'FAIL' }) 'Windows PowerShell' "$($PSVersionTable.PSVersion)"
$langOk = $ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage'
Write-Status $(if ($langOk) { 'OK' } else { 'FAIL' }) 'Language mode' "$($ExecutionContext.SessionState.LanguageMode)"
if (-not $langOk) { throw 'Constrained Language mode (AppLocker or WDAC) blocks StreamHub. Ask IT whether scripts may run in Full Language mode.' }
if (-not $psOk) {
    Write-Host '  Run this installer in Windows PowerShell 5.1 (powershell.exe), as shown in the README.' -ForegroundColor Red
    Write-Host '  Older Windows without 5.1: install Windows Management Framework 5.1 from https://www.microsoft.com/download/details.aspx?id=54616' -ForegroundColor Red
    return
}
Write-Host ''

Write-Host "Installing StreamHub into $dir" -ForegroundColor Cyan
$release = Invoke-GitHubRequest "https://api.github.com/repos/$repo/releases/latest" { param($u) Invoke-RestMethod $u -Headers @{ 'User-Agent' = 'StreamHub-installer' } }
$asset = @($release.assets | Where-Object { $_.name -like 'StreamHub-*.zip' }) | Select-Object -First 1
if (-not $asset) { $asset = @($release.assets | Where-Object { $_.name -like 'CCBridge-*.zip' }) | Select-Object -First 1 }   # pre-rename asset name
if (-not $asset) { throw "The latest release ($($release.tag_name)) has no StreamHub zip." }

$tmp = Join-Path $env:TEMP ('streamhub-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp
try {
    $zip = Join-Path $tmp $asset.name
    Write-Host "Downloading $($release.tag_name)..."
    $null = Invoke-GitHubRequest "$($asset.browser_download_url)" { param($u) Invoke-WebRequest $u -OutFile $zip -UseBasicParsing }
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    # The zip holds one folder (StreamHub, or the old name in a release from before the rename).
    $src = (Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1).FullName
    $null = New-Item -ItemType Directory -Force -Path $dir
    # Mirror the release in; settings in config\*.local.json are kept.
    $null = & robocopy.exe $src $dir /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XF '*.local.json' 'capture-report.json' 'probe-report.txt' /XD '.git'
    if ($LASTEXITCODE -ge 8) { throw "copying files failed (robocopy code $LASTEXITCODE)" }
} finally {
    # A file still open (a virus scanner reading the zip) must not turn a finished install into a
    # failure before the shortcuts are made: the folder is left in %TEMP% (Windows cleans it up).
    try { [IO.Directory]::Delete($tmp, $true) } catch { Write-Host "  (the download folder $tmp could not be removed yet; it can be deleted later)" -ForegroundColor DarkGray }
}

# Shortcuts: Start menu and desktop (skip with $env:STREAMHUB_NO_SHORTCUTS = '1').
$shell = New-Object -ComObject WScript.Shell
$targets = @(
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'StreamHub.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'StreamHub.lnk')
)
if ($env:STREAMHUB_NO_SHORTCUTS -eq '1') { $targets = @() }
# Shortcuts from before the rename (pre-rename CCBridge.lnk) are replaced by the StreamHub ones; StreamHub.lnk
# is written again below, so it points at this install folder (also after the folder was renamed).
foreach ($old in (Join-Path ([Environment]::GetFolderPath('Programs')) 'CCBridge.lnk'), (Join-Path ([Environment]::GetFolderPath('Desktop')) 'CCBridge.lnk')) { if ($targets.Count -and (Test-Path -LiteralPath $old)) { [IO.File]::Delete($old) } }   # pre-rename shortcut name
foreach ($lnkPath in $targets) {
    $lnk = $shell.CreateShortcut($lnkPath)
    $lnk.TargetPath = Join-Path $dir 'start.cmd'
    $lnk.WorkingDirectory = $dir
    $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,13"
    $lnk.Description = 'StreamHub - coding with Microsoft 365 Copilot Chat'
    $lnk.Save()
}

Write-Host ''
# Everything StreamHub needs on this computer, with GitHub and Copilot reachability.
try { & (Join-Path $dir 'tools\check.ps1') } catch { Write-Host "The system check could not run: $($_.Exception.Message)" -ForegroundColor Yellow }
Write-Host ''
Write-Host "StreamHub $($release.tag_name) is installed." -ForegroundColor Green
Write-Host '  Start it:  StreamHub shortcut on the desktop or in the Start menu'
Write-Host '  Updates:   automatic each time StreamHub starts (turn off with "autoUpdate": false in config\harness.local.json)'
Write-Host '  Check:     check.cmd in the StreamHub folder shows what this computer has (also at every start)'
Write-Host '  MCP:       register with your MCP client''s add command (or its JSON config, see the README) as streamhub:'
Write-Host "             powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$dir\mcp\streamhub-mcp.ps1`""
Write-Host '             (registered before the rename under the old id? remove that entry; tools\rebrand-check.ps1 prints both commands)'
