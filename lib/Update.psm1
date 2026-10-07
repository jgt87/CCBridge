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

function Get-RobocopyFailures([string[]]$Lines) {
    <# The file names in robocopy's ERROR lines (e.g. "ERROR 32 (0x00000020) Copying File C:\...\x.cmd"). #>
    @($Lines | ForEach-Object { $m = [regex]::Match("$_", 'ERROR \d+ \(0x[0-9A-Fa-f]+\) \w+(?: \w+)* (?:File|Directory) (.+)$'); if ($m.Success) { $m.Groups[1].Value.Trim() } } | Select-Object -Unique)
}

Export-ModuleMember -Function Test-FileLocked, Get-FileHashShared, Get-UpdateTouchedFiles, Get-LockedUpdateFiles, Format-LockedUpdateFiles, Get-RobocopyFailures
