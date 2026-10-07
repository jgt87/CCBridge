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
    [switch]$Force,    # check even when automatic updates are turned off
    [switch]$Report    # print the outcome (used by update.cmd)
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$repo = 'jgt87/CCBridge'
$branch = 'main'
Import-Module (Join-Path $root 'lib\Log.psm1')
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

try {
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
    $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -TimeoutSec 15 -Headers @{ 'User-Agent' = 'CCBridge-updater' }
    $latest = [string]$release.tag_name
    if (-not $latest -or $latest -eq $current) { Write-CCBLog verbose update "up to date ($current)"; if ($Report) { Say "Already up to date ($current)." }; return }
    $asset = @($release.assets | Where-Object { $_.name -like 'CCBridge-*.zip' }) | Select-Object -First 1
    if (-not $asset) { Say "release $latest has no StreamHub zip"; return }

    $tmp = Join-Path $env:TEMP ('ccbridge-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $tmp
    try {
        $zip = Join-Path $tmp 'ccbridge.zip'
        Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing -TimeoutSec 300
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $src = Get-ChildItem -Directory $tmp | Select-Object -First 1
        # Mirror the new version in; machine files and build tools stay.
        $xf = @('*.local.json', 'version.txt', 'capture-report.json', 'probe-report.txt'); $xd = @('.git', 'node_modules')
        # Files another program has open (a test tool's window at its pause) would fail halfway and
        # leave two versions mixed: wait for them instead, and name them.
        Import-Module (Join-Path $root 'lib\Update.psm1')
        $locked = Get-LockedUpdateFiles -Source $src.FullName -Target $root -ExcludeFiles $xf -ExcludeDirs $xd
        if (@($locked.blocking).Count) { Say (Format-LockedUpdateFiles @($locked.blocking) $latest); return }
        # Open but unchanged, or no longer in the release: robocopy leaves these (full paths in /XF).
        $keep = @(@($locked.same) + @($locked.removed) | Where-Object { $_ })
        if ($keep.Count) { $xf += @($keep | ForEach-Object { Join-Path $root $_ }); Write-CCBLog verbose update "in use, left as is: $($keep -join ', ')" }
        # A folder the release no longer has is purged whole, /XF or not: keep the topmost such folder.
        foreach ($rel in @($locked.removed)) {
            $top = $null; $d = Split-Path -Parent $rel
            while ($d) { if (-not (Test-Path -LiteralPath (Join-Path $src.FullName $d))) { $top = $d }; $d = Split-Path -Parent $d }
            if ($top) { $xd += (Join-Path $root $top) }
        }
        $rc = @(& robocopy.exe $src.FullName $root /MIR /R:3 /W:2 /NFL /NDL /NJH /NJS /NP /XF $xf /XD $xd)
        if ($LASTEXITCODE -ge 8) {
            $failed = @(Get-RobocopyFailures $rc | ForEach-Object { $_.Replace($root.TrimEnd('\') + '\', '') })
            throw "robocopy failed with code $LASTEXITCODE$(if ($failed.Count) { ' on ' + ($failed -join ', ') + ' (in use? the update runs again at the next start)' })"
        }
        [IO.File]::WriteAllText($verFile, $latest)
        Say "updated $(if ($current) { $current } else { '(unknown)' }) -> $latest"
    } finally {
        # A file still open (virus scan) must not turn a good update into "skipped"; the folder is
        # removed at a later start.
        try { [IO.Directory]::Delete($tmp, $true) } catch { Write-CCBLog verbose update "update folder left for a later start: $($_.Exception.Message)" }
    }
} catch {
    Say "update check skipped: $($_.Exception.Message)"
}
