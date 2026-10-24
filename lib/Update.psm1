# Release updates (tools/update.ps1): before the new release is mirrored over the app folder, find the
# files the copy would replace or delete that another program has open (a test tool's window still
# at its pause, an editor, a virus scan). Robocopy would fail on those halfway and leave a mix of two
# versions, so the update waits and names them instead. Open files with the same content as the
# release, and open files the release no longer has, are left alone and do not hold the update up.

$ErrorActionPreference = 'Stop'

function Test-FileLocked([string]$Path) {
    <# True when the file cannot be opened for writing without sharing (another program has it open). #>
    try { $fs = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None'); $fs.Close(); $false }
    catch [IO.FileNotFoundException] { $false }
    catch [IO.DirectoryNotFoundException] { $false }
    catch { $true }
}

function Get-UpdateTouchedFiles {
    <# Project-relative paths (backslashes) of files in $Target that a robocopy /MIR from $Source would
       overwrite (size or time differs) or delete, leaving out the excluded file patterns and folders. #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target,
        [string[]]$ExcludeFiles = @(), [string[]]$ExcludeDirs = @())
    $skip = {
        param([string]$rel)
        $parts = $rel.Split('\')
        foreach ($d in $ExcludeDirs) { if ($parts.Count -gt 1 -and @($parts[0..($parts.Count - 2)]) -contains $d) { return $true } }
        foreach ($f in $ExcludeFiles) { if ($parts[-1] -like $f) { return $true } }
        $false
    }
    $src = (Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\')
    $dst = (Resolve-Path -LiteralPath $Target).ProviderPath.TrimEnd('\')
    $out = New-Object Collections.Generic.List[string]
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($src.Length + 1)
        [void]$seen.Add($rel)
        if (& $skip $rel) { continue }
        $t = Join-Path $dst $rel
        if (-not (Test-Path -LiteralPath $t -PathType Leaf)) { continue }
        $ti = Get-Item -LiteralPath $t -Force
        if ($ti.Length -ne $f.Length -or $ti.LastWriteTimeUtc -ne $f.LastWriteTimeUtc) { $out.Add($rel) }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $dst -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($dst.Length + 1)
        if ($seen.Contains($rel) -or (& $skip $rel)) { continue }
        $out.Add($rel)
    }
    $out.ToArray()
}

function Get-FileHashShared([string]$Path) {
    <# SHA-256 of a file read with full sharing (works while another program has it open for reading); $null when unreadable.
       .NET directly, not the hash cmdlet: Windows PowerShell 5.1 started from PowerShell 7 loads 7's modules, which lack it. #>
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
        try { $sha = [Security.Cryptography.SHA256]::Create(); [BitConverter]::ToString($sha.ComputeHash($fs)) } finally { $fs.Close() }
    } catch { $null }
}

function Get-LockedUpdateFiles {
    <# The files an update would replace or delete that are open in another program, in three groups:
       same    - same content as the release (only the time differs): skipped, nothing to update;
       removed - not in the release any more: left in place, removed by a later update;
       blocking - different content: the update waits for these. #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target,
        [string[]]$ExcludeFiles = @(), [string[]]$ExcludeDirs = @())
    $r = @{ same = @(); removed = @(); blocking = @() }
    foreach ($rel in @(Get-UpdateTouchedFiles -Source $Source -Target $Target -ExcludeFiles $ExcludeFiles -ExcludeDirs $ExcludeDirs)) {
        $t = Join-Path $Target $rel
        if (-not (Test-FileLocked $t)) { continue }
        $s = Join-Path $Source $rel
        if (-not (Test-Path -LiteralPath $s -PathType Leaf)) { $r.removed += $rel; continue }
        $h = Get-FileHashShared $t
        if ($h -and $h -eq (Get-FileHashShared $s)) { $r.same += $rel } else { $r.blocking += $rel }
    }
    $r
}

function Format-LockedUpdateFiles([string[]]$Files, [string]$Version) {
    <# The message when an update has to wait for files in use. #>
    $names = @($Files | Select-Object -First 5)
    $more = if (@($Files).Count -gt 5) { " and $(@($Files).Count - 5) more" } else { '' }
    $hint = if (@($names | Where-Object { $_ -match '^(test-tools\\|tools\\)|-test\.|\.cmd$' }).Count) { 'Close the test tool or command window that still runs it (press a key at its pause), then start StreamHub again.' }
            else { 'Close the program or window that has it open, then start StreamHub again.' }
    "update to $Version waits: in use by another program: $($names -join ', ')$more. Nothing was changed. $hint"
}

function Get-UpdateNewFiles {
    <# Project-relative paths of files the release adds (in $Source, not yet in $Target), leaving out
       the excluded file patterns and folders: what a rollback removes again. #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Target, [string[]]$ExcludeFiles = @(), [string[]]$ExcludeDirs = @())
    $src = (Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\')
    @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($src.Length + 1)
        $parts = $rel.Split('\')
        $skip = @($ExcludeDirs | Where-Object { $parts.Count -gt 1 -and @($parts[0..($parts.Count - 2)]) -contains $_ }).Count -or @($ExcludeFiles | Where-Object { $parts[-1] -like $_ }).Count
        if (-not $skip -and -not (Test-Path -LiteralPath (Join-Path $Target $rel) -PathType Leaf)) { $rel }
    })
}

function Save-UpdateBackup {
    <# Copies the files an update replaces or removes ($Files, relative) to $BackupDir, keeping their
       folders, so a failed copy can put the old version back whole (Restore-UpdateBackup). #>
    param([Parameter(Mandatory)][string]$Target, [string[]]$Files, [Parameter(Mandatory)][string]$BackupDir)
    if (Test-Path -LiteralPath $BackupDir) { Remove-Item -LiteralPath $BackupDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $BackupDir
    foreach ($rel in @($Files | Where-Object { $_ })) {
        $from = Join-Path $Target $rel
        if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { continue }
        $to = Join-Path $BackupDir $rel
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to)
        Copy-Item -LiteralPath $from -Destination $to -Force
    }
}

function Restore-UpdateBackup {
    <# After a failed copy: the backed-up files back in place and the files the release added removed
       (folders it added too, when empty). Returns the files that could not be put back. #>
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][string]$BackupDir, [string[]]$NewFiles = @())
    $failed = New-Object Collections.Generic.List[string]
    $bk = (Resolve-Path -LiteralPath $BackupDir).ProviderPath.TrimEnd('\')
    foreach ($f in @(Get-ChildItem -LiteralPath $bk -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($bk.Length + 1)
        $to = Join-Path $Target $rel
        try { $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to); Copy-Item -LiteralPath $f.FullName -Destination $to -Force } catch { $failed.Add($rel) }
    }
    foreach ($rel in @($NewFiles | Where-Object { $_ })) {
        $p = Join-Path $Target $rel
        try {
            if (Test-Path -LiteralPath $p -PathType Leaf) { Remove-Item -LiteralPath $p -Force }
            $d = Split-Path -Parent $p
            while ($d -and $d.Length -gt $Target.TrimEnd('\').Length -and (Test-Path -LiteralPath $d) -and -not @(Get-ChildItem -LiteralPath $d -Force).Count) { Remove-Item -LiteralPath $d -Force; $d = Split-Path -Parent $d }
        } catch { $failed.Add($rel) }
    }
    $failed.ToArray()
}

$script:ManifestSkip = '^(manifest\.json|version\.txt|.*\.local\.json|capture-report\.json|probe-report\.txt)$'

function New-InstallManifest {
    <# manifest.json in a release folder (tools/build-release.ps1): its version and every file with its
       SHA-256, so a start can tell whether the app folder is the release as shipped. #>
    param([Parameter(Mandatory)][string]$AppFolder, [Parameter(Mandatory)][string]$Version)
    $base = (Resolve-Path -LiteralPath $AppFolder).ProviderPath.TrimEnd('\')
    $files = [ordered]@{}
    foreach ($f in @(Get-ChildItem -LiteralPath $base -Recurse -File -Force | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($base.Length + 1).Replace('\', '/')
        if ($rel -match $script:ManifestSkip) { continue }
        $files[$rel] = "$(Get-FileHashShared $f.FullName)".Replace('-', '')
    }
    $json = ConvertTo-Json -InputObject ([ordered]@{ version = $Version; files = $files }) -Depth 4
    [IO.File]::WriteAllText((Join-Path $base 'manifest.json'), $json, (New-Object Text.UTF8Encoding($false)))
    $files.Count
}

function Test-InstallIntegrity {
    <# Compares the app folder with its manifest.json: @{ version; missing; changed } (paths with /),
       or $null without a manifest (a git clone or a development copy). Files the release does not
       list (projects' local settings, logs) are not looked at. #>
    param([Parameter(Mandatory)][string]$AppRoot)
    $mf = Join-Path $AppRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $mf)) { return $null }
    $m = ConvertFrom-Json ([IO.File]::ReadAllText($mf))
    $missing = New-Object Collections.Generic.List[string]; $changed = New-Object Collections.Generic.List[string]
    foreach ($p in @($m.files.PSObject.Properties)) {
        $full = Join-Path $AppRoot ($p.Name.Replace('/', '\'))
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $missing.Add($p.Name); continue }
        if ("$(Get-FileHashShared $full)".Replace('-', '') -ne "$($p.Value)") { $changed.Add($p.Name) }
    }
    @{ version = "$($m.version)"; missing = $missing.ToArray(); changed = $changed.ToArray() }
}

function Format-InstallProblem($Result) {
    <# One sentence about an incomplete install, or '' when it is complete. #>
    if (-not $Result) { return '' }
    $n = @($Result.missing).Count + @($Result.changed).Count
    if (-not $n) { return '' }
    $names = @(@($Result.missing) + @($Result.changed) | Select-Object -First 4)
    $more = if ($n -gt 4) { " and $($n - 4) more" } else { '' }
    "StreamHub $($Result.version) is not complete: $(@($Result.missing).Count) file(s) missing and $(@($Result.changed).Count) different from the release ($($names -join ', ')$more). An update probably stopped halfway."
}

function Get-RobocopyFailures([string[]]$Lines) {
    <# The file names in robocopy's ERROR lines (e.g. "ERROR 32 (0x00000020) Copying File C:\...\x.cmd"). #>
    @($Lines | ForEach-Object { $m = [regex]::Match("$_", 'ERROR \d+ \(0x[0-9A-Fa-f]+\) \w+(?: \w+)* (?:File|Directory) (.+)$'); if ($m.Success) { $m.Groups[1].Value.Trim() } } | Select-Object -Unique)
}

# --- Going back to an earlier release (update.cmd -To vX.Y.Z) ------------------------------------
# The release gone back from (and every one up to it) is skipped by automatic updates, which take the
# next newer release again; the skip list is the setting skipUpdates in config\harness.local.json.

function ConvertTo-ReleaseVersion([string]$Tag) {
    <# 'v0.1.150' or '0.1.150' as a [version]; $null for anything else. #>
    $m = [regex]::Match("$Tag".Trim(), '^v?(\d+)\.(\d+)\.(\d+)$')
    if (-not $m.Success) { return $null }
    New-Object Version ([int]$m.Groups[1].Value), ([int]$m.Groups[2].Value), ([int]$m.Groups[3].Value)
}

function Test-ReleaseSkipped([string]$Release, [string[]]$Skip) {
    <# True when automatic updates leave $Release alone: it is not newer than every release in $Skip
       (entries that are not a version are ignored). #>
    $v = ConvertTo-ReleaseVersion $Release
    if (-not $v) { return $false }
    foreach ($s in @($Skip)) { $sv = ConvertTo-ReleaseVersion $s; if ($sv -and $v -le $sv) { return $true } }
    $false
}

function Get-RollbackSkip([string]$Target, [string]$Current, [string]$Latest) {
    <# The release to skip through after going back to $Target: the newest of the installed and the
       latest release, when it is newer than $Target; '' when there is nothing to skip. #>
    $t = ConvertTo-ReleaseVersion $Target
    if (-not $t) { return '' }
    $best = ''; $bestV = $t
    foreach ($r in $Current, $Latest) { $v = ConvertTo-ReleaseVersion $r; if ($v -and $v -gt $bestV) { $best = 'v' + $v; $bestV = $v } }
    $best
}

function Test-UpdaterSkipsReleases([string]$UpdaterPath) {
    <# Whether an updater script (tools\update.ps1 of a release) honours skipUpdates. A release from
       before it would update straight back at its next start. #>
    (Test-Path -LiteralPath $UpdaterPath -PathType Leaf) -and ([IO.File]::ReadAllText($UpdaterPath) -match 'Test-ReleaseSkipped')
}

function Get-LocalHarnessValue([string]$AppRoot, [string]$Key) {
    <# One value from config\harness.local.json; $null when the file or the key is not there. #>
    $file = Join-Path $AppRoot 'config\harness.local.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $obj = [IO.File]::ReadAllText($file) | ConvertFrom-Json
    if ($obj -and $obj.PSObject.Properties[$Key]) { return $obj.$Key }
    $null
}

function Set-LocalHarnessValue([string]$AppRoot, [string]$Key, $Value) {
    <# Sets (or with $null removes) one top-level value in config\harness.local.json. Self-contained:
       the updater uses it while the app folder may hold another release's Config.psm1. #>
    $file = Join-Path $AppRoot 'config\harness.local.json'
    $obj = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file) | ConvertFrom-Json } else { $null }
    if (-not $obj) { $obj = [pscustomobject]@{} }
    if ($null -eq $Value) { $obj.PSObject.Properties.Remove($Key) }
    else { $obj | Add-Member -Force -NotePropertyName $Key -NotePropertyValue $Value }
    [IO.File]::WriteAllText($file, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
}

Export-ModuleMember -Function ConvertTo-ReleaseVersion, Test-ReleaseSkipped, Get-RollbackSkip, Test-UpdaterSkipsReleases, Get-LocalHarnessValue, Set-LocalHarnessValue, New-InstallManifest, Test-InstallIntegrity, Format-InstallProblem, Get-UpdateNewFiles, Save-UpdateBackup, Restore-UpdateBackup, Test-FileLocked, Get-FileHashShared, Get-UpdateTouchedFiles, Get-LockedUpdateFiles, Format-LockedUpdateFiles, Get-RobocopyFailures
