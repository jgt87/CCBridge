<#
.SYNOPSIS
  After the update to the renamed release (CCBridge became StreamHub, 2026-11-24), on a PC where
  StreamHub is installed: where the data folder and the projects folder are (new name, old name,
  both), whether the one-time move ran (the log's "migrate" lines), the install folder, the
  shortcuts, and the commands that register the MCP server again as streamhub (printed, never run).
  Changes nothing. The log is masked like StreamHub's own (user name, profile and OneDrive paths,
  email addresses, ids) and can be sent as it is.
  Runbook: docs/runbooks/rebrand-check.md.
.PARAMETER OutDir
  Folder for the log (default: the Desktop).
.PARAMETER NoOpen
  Do not open Explorer at the log.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\Programs\StreamHub\tools\rebrand-check.ps1"
#>
param([string]$OutDir = '', [switch]$NoOpen)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\Log.psm1')
Import-Module (Join-Path $root 'lib\AppPaths.psm1')

$newName = 'StreamHub'; $oldName = 'CCBridge'
$lines = New-Object Collections.Generic.List[string]
function Add-Line([string]$Text = '') { $lines.Add($Text) }
function Get-FolderState([string]$New, [string]$Old) {
    $n = Test-Path -LiteralPath $New -PathType Container; $o = Test-Path -LiteralPath $Old -PathType Container
    if ($n -and $o) { 'both (the new one is used; the old one was left as it is)' }
    elseif ($n) { 'new name only (moved, or a new install)' }
    elseif ($o) { 'old name only (not moved yet: still in use at the last start)' }
    else { 'neither (nothing there yet)' }
}

Add-Line "StreamHub rename check $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Add-Line ''

# 1. The install.
$verFile = Join-Path $root 'version.txt'
$version = if (Test-Path -LiteralPath $verFile) { ([IO.File]::ReadAllText($verFile)).Trim() } else { 'no version.txt (a development copy)' }
Add-Line '[Install]'
Add-Line "  version:        $version"
Add-Line "  install folder: $root"
Add-Line "  folder name:    $(Split-Path -Leaf $root)$(if ((Split-Path -Leaf $root) -eq $oldName) { ' (the name from before the rename, kept on purpose: StreamHub cannot move the folder it runs from)' })"
Add-Line "  new start file: $(Test-Path -LiteralPath (Join-Path $root 'streamhub.ps1'))"
Add-Line "  old MCP file:   $(Test-Path -LiteralPath (Join-Path $root 'mcp\ccbridge-mcp.ps1')) (starts the new MCP server for clients registered before the rename)"
foreach ($n in $newName, $oldName) {
    $p = Join-Path $env:LOCALAPPDATA "Programs\$n"
    Add-Line "  Programs\$($n.PadRight(10)) $(if (Test-Path -LiteralPath $p) { 'exists' } else { 'not there' })"
}
Add-Line ''

# 2. The data folder.
$dataNew = Join-Path $env:LOCALAPPDATA $newName
$dataOld = Join-Path $env:LOCALAPPDATA $oldName
$dataDir = Get-AppDataDir
Add-Line '[Data folder]'
Add-Line "  state:          $(Get-FolderState $dataNew $dataOld)"
Add-Line "  in use:         $dataDir"
Add-Line "  Edge profile:   $(if (Test-Path -LiteralPath (Join-Path $dataDir 'edge-profile')) { 'there (the Copilot sign-in moves with it)' } else { 'not there yet' })"
$stateDirs = @(Get-ChildItem -LiteralPath (Join-Path $dataDir 'projects') -Directory -ErrorAction SilentlyContinue)
Add-Line "  project state:  $($stateDirs.Count) folder(s)"
Add-Line ''

# 3. The projects folder.
$od = ''
foreach ($p in $env:OneDriveCommercial, $env:OneDrive, $env:OneDriveConsumer) { if ($p -and (Test-Path -LiteralPath $p)) { $od = $p.TrimEnd('\'); break } }
$folder = $newName
foreach ($f in 'harness.json', 'harness.local.json') {
    $cf = Join-Path $root "config\$f"
    if (Test-Path -LiteralPath $cf) { try { $j = [IO.File]::ReadAllText($cf) | ConvertFrom-Json; if ($j.projectsFolder) { $folder = "$($j.projectsFolder)" } } catch { } }
}
Add-Line '[Projects folder]'
if ($od) {
    Add-Line "  setting:        projectsFolder = $folder$(if ($folder -ne $newName) { ' (a name of your own: it is not moved)' })"
    Add-Line "  state:          $(Get-FolderState (Join-Path $od $newName) (Join-Path $od $oldName))"
    Add-Line "  in use:         $(Resolve-ProjectsDir -OneDriveRoot $od -FolderName $folder)"
} else { Add-Line '  no OneDrive folder on this PC (the MCP server works without one)' }
Add-Line ''

# 4. Who keeps an old folder from moving (only while one still has the old name).
$pending = @(@($dataOld, $(if ($od) { Join-Path $od $oldName } else { '' })) | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
if ($pending.Count) {
    Add-Line '[In use]'
    $users = @(Get-FolderUsers -Paths $pending)
    if ($users.Count) { foreach ($u in $users | Select-Object -First 10) { Add-Line "  $u" } }
    else { Add-Line '  nothing uses the old folders now: the next start of StreamHub moves them' }
    Add-Line ''
}

# 5. What the starts logged about the move.
Add-Line '[Move, from the log]'
$logDir = Join-Path $dataDir 'logs'
$logs = @(foreach ($pattern in 'streamhub-*.log', 'ccbridge-*.log') { Get-ChildItem -LiteralPath $logDir -Filter $pattern -File -ErrorAction SilentlyContinue })
$found = @(foreach ($l in @($logs | Sort-Object LastWriteTime)) {
    try { @([IO.File]::ReadAllLines($l.FullName) | Where-Object { $_ -match '\]\s+INFO\s+migrate\s' }) } catch { }
})
if ($found.Count) { foreach ($m in $found | Select-Object -Last 20) { Add-Line "  $m" } }
else { Add-Line '  no move lines yet (nothing to move, or no start of the new release yet)' }
Add-Line ''

# 6. Shortcuts.
Add-Line '[Shortcuts]'
$shell = New-Object -ComObject WScript.Shell
foreach ($place in @(@('Start menu', [Environment]::GetFolderPath('Programs')), @('Desktop', [Environment]::GetFolderPath('Desktop')))) {
    foreach ($n in $newName, $oldName) {
        $lnk = Join-Path $place[1] "$n.lnk"
        if (-not (Test-Path -LiteralPath $lnk)) { Add-Line "  $($place[0]): $n.lnk not there"; continue }
        $target = "$($shell.CreateShortcut($lnk).TargetPath)"
        Add-Line "  $($place[0]): $n.lnk -> $target$(if (-not (Test-Path -LiteralPath $target)) { ' (TARGET MISSING)' })"
    }
}
Add-Line ''

# 7. The MCP server under its new id (printed, never run).
$mcp = Join-Path $root 'mcp\streamhub-mcp.ps1'
$remove = 'mcp remove ccbridge'
$add = "mcp add streamhub -- powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$mcp`""
Add-Line '[MCP server]'
Add-Line '  Register it again under the new id with your MCP client''s command-line tool (the one that'
Add-Line '  added ccbridge; put its name in front of each line), then restart the client:'
Add-Line "    <client> $remove"
Add-Line "    <client> $add"
Add-Line '  Or in the client''s JSON config: rename the "ccbridge" entry to "streamhub" and set its last'
Add-Line "  argument to $mcp"

$text = Protect-LogText ($lines -join "`r`n")
if (-not $OutDir) { $OutDir = [Environment]::GetFolderPath('Desktop') }
$null = New-Item -ItemType Directory -Force -Path $OutDir
$file = Join-Path $OutDir ("StreamHub-rebrand-check-$(Get-Date -Format 'yyyyMMdd-HHmm').txt")
[IO.File]::WriteAllText($file, $text + "`r`n", (New-Object Text.UTF8Encoding($false)))

# The console shows the report too, and the two MCP lines unmasked, ready to copy.
Write-Host $text
Write-Host ''
Write-Host 'MCP, to copy (put your client''s command in front, run, then restart the client):' -ForegroundColor Cyan
Write-Host "  $remove"
Write-Host "  $add"
Write-Host ''
Write-Host "Log (masked, safe to send): $file" -ForegroundColor Green
if (-not $NoOpen) { try { Start-Process explorer.exe "/select,`"$file`"" } catch { } }
