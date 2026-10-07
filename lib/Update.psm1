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
    <# SHA-256 of a file read with full sharing (works while another program has it open for reading); $null when unreadable. #>
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
        $files[$rel] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
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
        if ((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ne "$($p.Value)") { $changed.Add($p.Name) }
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

Export-ModuleMember -Function New-InstallManifest, Test-InstallIntegrity, Format-InstallProblem, Get-UpdateNewFiles, Save-UpdateBackup, Restore-UpdateBackup, Test-FileLocked, Get-FileHashShared, Get-UpdateTouchedFiles, Get-LockedUpdateFiles, Format-LockedUpdateFiles, Get-RobocopyFailures
