<#
.SYNOPSIS
  Brings this CCBridge folder up to date with github.com/jgt87/CCBridge (branch main).
.DESCRIPTION
  - Git clone: git pull --ff-only (skipped when the folder has local changes or is not on main).
  - Installed from a release (no .git): compares version.txt with the latest GitHub Release and
    mirrors the new release in, keeping config\*.local.json and other machine files.
  Never fails the caller: any problem is reported and the current version keeps running.
  Writes only to stderr, so it is safe before the MCP server starts (stdout is its protocol).
  Set "autoUpdate": false in config\harness.local.json to turn automatic updates off.
#>
param(
    [switch]$Force,        # check even when automatic updates are turned off
    [switch]$Report,       # print the outcome (used by update.cmd)
    [switch]$Repair,       # install the installed version again (the start found files missing or different)
    # Handing over (the updater of the installed version starts the new release's updater, so a fix
    # to the updater applies at once): the app folder, the unpacked release and its version.
    [string]$AppRoot = '',
    [string]$FromFolder = '',
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'
# This updater's own folder (its modules: the new release's when handed over) and the app folder.
$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$root = if ($AppRoot) { $AppRoot } else { $here }
$repo = 'jgt87/CCBridge'
$branch = 'main'
Import-Module (Join-Path $here 'lib\Log.psm1')
function Say([string]$Message) { [Console]::Error.WriteLine("[StreamHub update] $Message"); Write-CCBLog info update $Message }

function Invoke-Git([string[]]$GitArgs, [int]$TimeoutSec = 30) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = (@('-C', "`"$root`"") + $GitArgs) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { try { $p.Kill() } catch { }; throw "git $($GitArgs[0]) timed out" }
    if ($p.ExitCode -ne 0) { throw "git $($GitArgs[0]) failed: $($err.Result.Trim())" }
    $out.Result.Trim()
}

function Install-Release([string]$From, [string]$NewVersion) {
    <# Mirrors the unpacked release $From into the app folder. Files another program has open hold it
       up (nothing is copied); before copying, every file it replaces or removes is backed up, and a
       copy that fails halfway is undone from that backup, so the app is never a mix of two versions.
       version.txt is written last. #>
    $verFile = Join-Path $root 'version.txt'
    $current = if (Test-Path $verFile) { ([IO.File]::ReadAllText($verFile)).Trim() } else { '' }
    Import-Module (Join-Path $here 'lib\Update.psm1') -Force
    # Machine files and build tools stay.
    $xf = @('*.local.json', 'version.txt', 'capture-report.json', 'probe-report.txt'); $xd = @('.git', 'node_modules')
    $locked = Get-LockedUpdateFiles -Source $From -Target $root -ExcludeFiles $xf -ExcludeDirs $xd
    if (@($locked.blocking).Count) { Say (Format-LockedUpdateFiles @($locked.blocking) $NewVersion); return }
    # Open but unchanged, or no longer in the release: robocopy leaves these (full paths in /XF).
    $keep = @(@($locked.same) + @($locked.removed) | Where-Object { $_ })
    $touched = @(Get-UpdateTouchedFiles -Source $From -Target $root -ExcludeFiles $xf -ExcludeDirs $xd | Where-Object { $keep -notcontains $_ })
    $added = @(Get-UpdateNewFiles -Source $From -Target $root -ExcludeFiles $xf -ExcludeDirs $xd)
    $xfAll = @($xf) + @($keep | ForEach-Object { Join-Path $root $_ })
    $xdAll = @($xd)
    if ($keep.Count) { Write-CCBLog verbose update "in use, left as is: $($keep -join ', ')" }
    # A folder the release no longer has is purged whole, /XF or not: keep the topmost such folder.
    foreach ($rel in @($locked.removed)) {
        $top = $null; $d = Split-Path -Parent $rel
        while ($d) { if (-not (Test-Path -LiteralPath (Join-Path $From $d))) { $top = $d }; $d = Split-Path -Parent $d }
        if ($top) { $xdAll += (Join-Path $root $top) }
    }
    $backup = Join-Path $env:LOCALAPPDATA 'CCBridge\update-backup'
    Save-UpdateBackup -Target $root -Files $touched -BackupDir $backup
    $rc = @(& robocopy.exe $From $root /MIR /R:3 /W:2 /NFL /NDL /NJH /NJS /NP /XF $xfAll /XD $xdAll)
    if ($LASTEXITCODE -ge 8) {
        $code = $LASTEXITCODE
        $failed = @(Get-RobocopyFailures $rc | ForEach-Object { $_.Replace($root.TrimEnd('\') + '\', '') })
        $notBack = @(Restore-UpdateBackup -Target $root -BackupDir $backup -NewFiles $added)
        $back = if ($notBack.Count) { "; putting the previous version back failed for $($notBack -join ', ')" } else { "; the previous version ($(if ($current) { $current } else { 'unknown' })) was put back whole" }
        throw "robocopy failed with code $code$(if ($failed.Count) { ' on ' + ($failed -join ', ') + ' (in use?)' })$back. The update runs again at the next start."
    }
    [IO.File]::WriteAllText($verFile, $NewVersion)
    try { Remove-Item -LiteralPath $backup -Recurse -Force } catch { }
    Say "updated $(if ($current) { $current } else { '(unknown)' }) -> $NewVersion"
}

try {
    # Handed over by the installed version's updater: install the release it unpacked, nothing else.
    if ($FromFolder) { Install-Release $FromFolder $Version; return }
    if (-not $Force) {
        Import-Module (Join-Path $root 'lib\Config.psm1') -Force
        $cfg = Get-CCBridgeConfig harness $root
        Initialize-CCBLog -Config $cfg
        Remove-Module Config -ErrorAction SilentlyContinue
        if ($cfg.PSObject.Properties['autoUpdate'] -and -not $cfg.autoUpdate) { return }
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ([Net.WebRequest]::DefaultWebProxy) { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials }

    $git = Get-Command git -ErrorAction SilentlyContinue
    if (Test-Path (Join-Path $root '.git')) {
        if (-not $git) { Say 'git is not available; cannot update this clone.'; return }
        if ((Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')) -ne $branch) { Write-CCBLog verbose update 'git clone not on main: no update'; if ($Report) { Say 'This is a git clone on another branch than main; not updated.' }; return }
        if (Invoke-Git @('status', '--porcelain', '--untracked-files=no')) { Write-CCBLog verbose update 'git clone has local changes: no update'; if ($Report) { Say 'This git clone has local changes; not updated.' }; return }
        $before = Invoke-Git @('rev-parse', 'HEAD')
        $null = Invoke-Git @('pull', '--ff-only', '--quiet') 60
        $after = Invoke-Git @('rev-parse', 'HEAD')
        if ($after -ne $before) { Say "updated $($before.Substring(0, 7)) -> $($after.Substring(0, 7))" }
        elseif ($Report) { Say "Already up to date ($($after.Substring(0, 7)))." }
        return
    }

    # Release install: first remove download folders that earlier updates could not delete (a
    # virus scanner still had the zip open, or the window closed mid-update); only ones older than
    # an hour, so an update running in another window is left alone.
    foreach ($old in @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'ccbridge-update-*' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) })) {
        try {
            Get-ChildItem -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
            [IO.Directory]::Delete($old.FullName, $true)
            Write-CCBLog verbose update "removed an old update folder: $($old.Name)"
        } catch { Write-CCBLog verbose update "could not remove $($old.Name) yet: $($_.Exception.Message)" }
    }

    # Release install: compare with the latest GitHub Release.
    $verFile = Join-Path $root 'version.txt'
    $current = if (Test-Path $verFile) { ([IO.File]::ReadAllText($verFile)).Trim() } else { '' }
    # -Repair: the release of the installed version (an incomplete install of the latest version
    # would otherwise count as up to date).
    $which = if ($Repair -and $current) { "tags/$current" } else { 'latest' }
    $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/$which" -TimeoutSec 15 -Headers @{ 'User-Agent' = 'CCBridge-updater' }
    $latest = [string]$release.tag_name
    if (-not $Repair -and $latest -and $latest -eq $current) {
        # Up to date by version: is the folder complete too (manifest.json)? If not, install it again.
        $problem = try { Import-Module (Join-Path $here 'lib\Update.psm1') -Force; Format-InstallProblem (Test-InstallIntegrity $root) } catch { '' }
        if ($problem) { Say $problem; $Repair = $true }
    }
    if ($Repair -and $latest) { Say "repairing ${latest}: installing its files again" }
    elseif (-not $latest -or $latest -eq $current) { Write-CCBLog verbose update "up to date ($current)"; if ($Report) { Say "Already up to date ($current)." }; return }
    $asset = @($release.assets | Where-Object { $_.name -like 'CCBridge-*.zip' }) | Select-Object -First 1
    if (-not $asset) { Say "release $latest has no StreamHub zip"; return }

    $tmp = Join-Path $env:TEMP ('ccbridge-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $tmp
    try {
        $zip = Join-Path $tmp 'ccbridge.zip'
        Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing -TimeoutSec 300
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $src = Get-ChildItem -Directory $tmp | Select-Object -First 1
        # The new release's updater does the install when it differs from this one, so a fix to the
        # updater itself applies with this update (not one later).
        $newUpdater = Join-Path $src.FullName 'tools\update.ps1'
        $handOver = (Test-Path -LiteralPath $newUpdater) -and ((Get-FileHash -LiteralPath $newUpdater).Hash -ne (Get-FileHash -LiteralPath $MyInvocation.MyCommand.Path).Hash)
        if ($handOver) {
            Write-CCBLog info update "handing over to the updater of $latest"
            $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $newUpdater, '-AppRoot', $root, '-FromFolder', $src.FullName, '-Version', $latest)
            if ($Report) { $childArgs += '-Report' }
            # Its messages go to stderr: with Stop, a redirected stderr line would end this script.
            $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { & powershell.exe @childArgs } finally { $ErrorActionPreference = $eap }
            if ($LASTEXITCODE -ne 0) { Say "the updater of $latest stopped (exit $LASTEXITCODE); installing with this one"; Install-Release $src.FullName $latest }
        } else {
            Install-Release $src.FullName $latest
        }
    } finally {
        # A file still open (virus scan) must not turn a good update into "skipped"; the folder is
        # removed at a later start.
        try { [IO.Directory]::Delete($tmp, $true) } catch { Write-CCBLog verbose update "update folder left for a later start: $($_.Exception.Message)" }
    }
} catch {
    Say "update check skipped: $($_.Exception.Message)"
}
