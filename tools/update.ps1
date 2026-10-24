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
  -To vX.Y.Z goes back to an earlier release (update.cmd -To v0.1.149): the release gone back from
  is added to "skipUpdates", so automatic updates leave it alone and take the next newer release.
#>
param(
    [switch]$Force,        # check even when automatic updates are turned off
    [switch]$Report,       # print the outcome (used by update.cmd)
    [switch]$Repair,       # install the installed version again (the start found files missing or different)
    [string]$To = '',      # go back (or forward) to this release, e.g. v0.1.149, and skip the newer ones
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
    $older = (ConvertTo-ReleaseVersion $current) -and (ConvertTo-ReleaseVersion $NewVersion) -and (ConvertTo-ReleaseVersion $NewVersion) -lt (ConvertTo-ReleaseVersion $current)
    Say "$(if ($older) { 'went back' } else { 'updated' }) $(if ($current) { $current } else { '(unknown)' }) -> $NewVersion"
}

function Complete-Rollback([string]$Target, [string]$From, [string]$Latest, [string]$Updater) {
    <# After going back to $Target: skip the release gone back from (and every one up to the latest),
       so automatic updates wait for a newer one. An updater from before the skip list would update
       straight back at its next start: then automatic updates are switched off, and said so. #>
    $skip = Get-RollbackSkip $Target $From $Latest
    if (-not $skip) { return }
    $list = @(@(Get-LocalHarnessValue $root 'skipUpdates') | Where-Object { $_ } | ForEach-Object { "$_" })
    if ($list -notcontains $skip) { $list += $skip }
    Set-LocalHarnessValue $root 'skipUpdates' $list
    if (Test-UpdaterSkipsReleases $Updater) {
        Say "automatic updates skip releases up to $skip and update again at the next newer release (Settings > App > Skip releases up to)."
    } else {
        Set-LocalHarnessValue $root 'autoUpdate' $false
        Say "$Target does not know how to skip a release, so automatic updates are now OFF (it would update straight back to $skip). Turn them on again in Settings > App once a release newer than $skip is out."
    }
}

try {
    # Handed over by the installed version's updater: install the release it unpacked, nothing else.
    if ($FromFolder) { Install-Release $FromFolder $Version; return }
    Import-Module (Join-Path $here 'lib\Update.psm1') -Force
    if ($To) {
        if (-not (ConvertTo-ReleaseVersion $To)) { Say "'$To' is not a release; give one like v0.1.149 (see the Releases page on GitHub)."; return }
        $To = 'v' + (ConvertTo-ReleaseVersion $To)
        if (Test-Path (Join-Path $root '.git')) { Say "This is a git clone: go back with git itself (git checkout $To); -To is for installed releases."; return }
    }
    $skipList = @()
    if (-not $Force -and -not $To) {
        Import-Module (Join-Path $root 'lib\Config.psm1') -Force
        $cfg = Get-CCBridgeConfig harness $root
        Initialize-CCBLog -Config $cfg
        Remove-Module Config -ErrorAction SilentlyContinue
        if ($cfg.PSObject.Properties['autoUpdate'] -and -not $cfg.autoUpdate) { return }
        if ($cfg.PSObject.Properties['skipUpdates']) { $skipList = @(@($cfg.skipUpdates) | Where-Object { $_ } | ForEach-Object { "$_" }) }
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
    # would otherwise count as up to date). -To: the release asked for.
    $which = if ($To) { "tags/$To" } elseif ($Repair -and $current) { "tags/$current" } else { 'latest' }
    $headers = @{ 'User-Agent' = 'CCBridge-updater' }
    if ($To) {
        $newest = try { [string](Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -TimeoutSec 15 -Headers $headers).tag_name } catch { '' }
        if ($To -eq $current) {
            # Already on it (unpacked by hand from GitHub, say): only keep the newer releases away.
            Say "$To is installed already."
            Complete-Rollback $To $current $newest (Join-Path $root 'tools\update.ps1')
            return
        }
        try { $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/$which" -TimeoutSec 15 -Headers $headers }
        catch { Say "release $To was not found on GitHub ($($_.Exception.Message))."; return }
    } else {
        $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/$which" -TimeoutSec 15 -Headers $headers
    }
    $latest = [string]$release.tag_name
    # Automatic updates leave a release the person went back from alone (and every one before it).
    if (-not $To -and -not $Repair -and $latest -ne $current -and (Test-ReleaseSkipped $latest $skipList)) {
        Say "$latest is skipped (you went back from it); staying on $current until a newer release is out. Settings > App > Skip releases up to clears this."
        return
    }
    if (-not $To -and -not $Repair -and $latest -and $latest -eq $current) {
        # Up to date by version: is the folder complete too (manifest.json)? If not, install it again.
        $problem = try { Import-Module (Join-Path $here 'lib\Update.psm1') -Force; Format-InstallProblem (Test-InstallIntegrity $root) } catch { '' }
        if ($problem) { Say $problem; $Repair = $true }
    }
    if ($Repair -and $latest) { Say "repairing ${latest}: installing its files again" }
    elseif ($To) { Say "going from $(if ($current) { $current } else { '(unknown)' }) to $latest" }
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
        # Going back is done by this updater: an older one may lack what this one knows.
        $handOver = -not $To -and (Test-Path -LiteralPath $newUpdater) -and ((Get-FileHashShared $newUpdater) -ne (Get-FileHashShared $MyInvocation.MyCommand.Path))
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
        $installed = if (Test-Path $verFile) { ([IO.File]::ReadAllText($verFile)).Trim() } else { '' }
        if ($installed -eq $latest) {
            if ($To) { Complete-Rollback $To $current $newest $newUpdater }
            elseif (-not $Repair -and $null -ne (Get-LocalHarnessValue $root 'skipUpdates')) {
                # A newer release is in: the skip list has done its job.
                Set-LocalHarnessValue $root 'skipUpdates' $null
                Write-CCBLog info update 'skip list cleared: a newer release is installed'
            }
        }
    } finally {
        # A file still open (virus scan) must not turn a good update into "skipped"; the folder is
        # removed at a later start.
        try { [IO.Directory]::Delete($tmp, $true) } catch { Write-CCBLog verbose update "update folder left for a later start: $($_.Exception.Message)" }
    }
} catch {
    Say "update check skipped: $($_.Exception.Message)"
}
