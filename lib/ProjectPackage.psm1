# The project as one zip for a colleague who may not have StreamHub, on the person's request only
# (command menu > Package for sharing): Runbooks/Exports/PROJECT-yyyyMMdd-HHmm.zip with the project's
# files and README-SHARING.md at its root (how to open the app, what was left out and why, how to
# refresh the data without StreamHub). Left out, each with its reason:
#   - .streamhub/ (the helper program's own records), .git/;
#   - packages and caches made again by their tools: node_modules/, .venv/, venv/, __pycache__/,
#     .pytest_cache/, .next/, .vs/, .idea/;
#   - build output of compiled languages (bin/, obj/, target/). dist/, build/ and out/ stay: they
#     hold the built app (the entry page the colleague opens, or dist/app.js from the built-in
#     builder), and the colleague may have no Node.js to build it again;
#   - other zips in Runbooks/Exports/ (earlier packages);
#   - secret files (SecretFiles Get-SecretFileKind: .env, keys, credentials);
#   - files over $MaxFileBytes (50 MB by default), Office lock files (~$*);
#   - junctions and symbolic links (Workspace Test-LinkPath): never followed;
#   - Source/ unless -IncludeSource: the person's source data may not be theirs to pass on.
# Files are read with shared read, so a file OneDrive or another program holds open is still packed.
# ASCII only (Windows PowerShell 5.1).

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Workspace', 'SecretFiles', 'ProjectOverview') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:SkipDirs = @{
    '.streamhub' = 'streamhub'; '.git' = 'git'
    'node_modules' = 'packages'; '.venv' = 'packages'; 'venv' = 'packages'
    '__pycache__' = 'cache'; '.pytest_cache' = 'cache'; '.next' = 'cache'; '.vs' = 'cache'; '.idea' = 'cache'
    'bin' = 'build'; 'obj' = 'build'; 'target' = 'build'
}
# Why something was left out, as the summary and the sharing notes say it.
$script:Reasons = [ordered]@{
    streamhub = "StreamHub's own records (.streamhub/), not needed to use the project"
    git = 'version history (.git/)'
    packages = 'installed packages, which their tools install again (npm install, pip install)'
    cache = 'caches and editor settings, made again when needed'
    build = 'build output of compiled code, made again by its build'
    source = 'the source data in Source/ (packed only when asked for)'
    export = 'earlier packages in Runbooks/Exports/'
    secret = 'files with passwords, keys or tokens'
    large = 'files over the size limit'
    temp = 'Office lock files and temporary files'
    link = 'links to other folders (junctions and symbolic links), never followed'
    unreadable = 'files that could not be read'
}
$script:ReadmeName = 'README-SHARING.md'

function Get-PackageReason([string]$Rel, [bool]$IsDir, [bool]$IncludeSource) {
    # Why a path (relative, '/') is left out, or '' when it goes in. Folders by their name anywhere,
    # Source/ only at the top.
    $name = $Rel.Split('/')[-1]
    if ($IsDir) {
        $k = $name.ToLowerInvariant()
        if ($script:SkipDirs.ContainsKey($k)) { return $script:SkipDirs[$k] }
        if (-not $IncludeSource -and $Rel -notmatch '/' -and $k -eq 'source') { return 'source' }
        return ''
    }
    if ($Rel -match '(?i)^Runbooks/Exports/[^/]+\.zip$') { return 'export' }
    if ($name -like '~$*' -or $name -match '(?i)\.(tmp|partial)$') { return 'temp' }
    if (Get-SecretFileKind $name) { return 'secret' }
    ''
}

function Get-PackageFiles {
    <# The files that go into the package and the ones left out: @{ files = @(@{ rel; full; size });
       left = @(@{ path; reason; folder }) } (a folder left out is one entry, folder = $true). Never
       follows a junction or symbolic link. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [switch]$IncludeSource, [int64]$MaxFileBytes = 50MB)
    $root = $ProjectRoot.TrimEnd('\')
    $files = New-Object System.Collections.Generic.List[object]
    $left = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($root)
    while ($stack.Count) {
        $dir = $stack.Pop()
        foreach ($d in [IO.Directory]::GetDirectories($dir)) {
            $rel = $d.Substring($root.Length + 1).Replace('\', '/')
            if (Test-LinkPath $d) { $left.Add(@{ path = "$rel/"; reason = 'link'; folder = $true }); continue }
            $why = Get-PackageReason $rel $true ([bool]$IncludeSource)
            if ($why) { $left.Add(@{ path = "$rel/"; reason = $why; folder = $true }); continue }
            $stack.Push($d)
        }
        foreach ($p in [IO.Directory]::GetFiles($dir)) {
            $rel = $p.Substring($root.Length + 1).Replace('\', '/')
            if (Test-LinkPath $p) { $left.Add(@{ path = $rel; reason = 'link'; folder = $false }); continue }
            $why = Get-PackageReason $rel $false ([bool]$IncludeSource)
            if (-not $why -and $rel -eq $script:ReadmeName) { continue }   # the sharing notes take its place
            $size = (New-Object IO.FileInfo $p).Length
            if (-not $why -and $size -gt $MaxFileBytes) { $why = 'large' }
            if ($why) { $left.Add(@{ path = $rel; reason = $why; folder = $false }); continue }
            $files.Add(@{ rel = $rel; full = $p; size = [int64]$size })
        }
    }
    @{ files = @($files.ToArray() | Sort-Object { $_.rel }); left = @($left.ToArray() | Sort-Object { $_.path }) }
}

function Get-LeftOutLines($Left) {
    # One line per reason: what it is and which paths (the first few).
    @(foreach ($r in $script:Reasons.Keys) {
        $paths = @(@($Left) | Where-Object { $_.reason -eq $r } | ForEach-Object { $_.path })
        if (-not $paths.Count) { continue }
        $shown = @($paths | Select-Object -First 6) -join ', '
        "- $($script:Reasons[$r]): $shown$(if ($paths.Count -gt 6) { " and $($paths.Count - 6) more" })"
    })
}

function New-SharingReadme {
    <# README-SHARING.md for the zip: how to open the app, what is left out and why, how to refresh the
       data without StreamHub. Relative paths only. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$Package, [switch]$IncludeSource, [int64]$MaxFileBytes = 50MB, [datetime]$Now = (Get-Date))
    $root = $ProjectRoot.TrimEnd('\')
    $name = Split-Path -Leaf $root
    $rels = @(@($Package.files) | ForEach-Object { $_.rel })
    $entry = Select-AppEntryPage $rels
    $l = New-Object System.Collections.Generic.List[string]
    $l.Add("# $name")
    $l.Add('')
    $l.Add("Shared on $($Now.ToString('yyyy-MM-dd')). Unzip the whole folder first; the files refer to each other.")
    $l.Add('')
    $l.Add('## Opening it')
    $l.Add('')
    if ($entry) {
        $l.Add("Open $entry in Edge or another browser (double-click it).")
        if (Test-ModulePage (Join-Path $root $entry.Replace('/', '\'))) {
            $l.Add('')
            $l.Add('This page loads its scripts as modules, which a browser does not allow for a page opened from disk. Serve the folder with a small local web server and open the address it shows, for example with Python: python -m http.server, then http://localhost:8000/' + $entry + '.')
        }
    } else {
        $l.Add('There is no index.html page to open: look at the files themselves, starting with README.md or AGENTS.md when there is one.')
    }
    $l.Add('')
    $l.Add('## What is left out')
    $l.Add('')
    $lines = @(Get-LeftOutLines $Package.left)
    if ($lines.Count) { foreach ($x in $lines) { $l.Add($x) } } else { $l.Add('Nothing: every file of the project is in this package.') }
    if (@($Package.left | Where-Object { $_.reason -eq 'large' }).Count) { $l.Add(''); $l.Add("The size limit is $([Math]::Round($MaxFileBytes / 1MB)) MB per file.") }
    if (@($Package.left | Where-Object { $_.reason -eq 'source' }).Count) { $l.Add(''); $l.Add('Pages that read the source data need it: ask for it, and put it in a folder named Source next to the other files.') }
    $l.Add('')
    $l.Add('## Refreshing the data')
    $l.Add('')
    $scripts = @($rels | Where-Object { $_ -match '^Scripts/Refresh-[^/]+\.ps1$' })
    if ($scripts.Count) {
        $l.Add('These scripts refresh the data without StreamHub. Run one in a PowerShell window, from the unzipped folder:')
        $l.Add('')
        foreach ($s in $scripts) { $l.Add("    powershell -NoProfile -ExecutionPolicy Bypass -File $($s.Replace('/', '\'))") }
        $l.Add('')
        $l.Add('They read the data from where it was on the computer it was made on (a synced folder, a web address, a database). If that place is different or not available on yours, change it at the top of the script, or ask for a new copy of the data.')
    } else {
        $l.Add('The project has no refresh scripts: its data is in the files as they are.')
    }
    ($l -join "`n") + "`n"
}

function Get-PackageName([string]$ProjectRoot, [datetime]$Now = (Get-Date)) {
    # Runbooks/Exports/PROJECT-yyyyMMdd-HHmm.zip (a numbered name when that exists).
    $base = ((Split-Path -Leaf $ProjectRoot.TrimEnd('\')) -replace '[^\w.-]+', '-').Trim('-')
    if (-not $base) { $base = 'project' }
    $rel = "Runbooks/Exports/$base-$($Now.ToString('yyyyMMdd-HHmm')).zip"
    $n = 2
    while (Test-Path -LiteralPath (Join-Path $ProjectRoot $rel.Replace('/', '\'))) { $rel = "Runbooks/Exports/$base-$($Now.ToString('yyyyMMdd-HHmm'))-$n.zip"; $n++ }
    $rel
}

function Add-ZipText($Zip, [string]$Name, [string]$Text) {
    $e = $Zip.CreateEntry($Name, [IO.Compression.CompressionLevel]::Optimal)
    $s = $e.Open()
    try { $b = (New-Object Text.UTF8Encoding($false)).GetBytes($Text); $s.Write($b, 0, $b.Length) } finally { $s.Dispose() }
}

function New-ProjectPackage {
    <# Zips the project (Get-PackageFiles) with README-SHARING.md into Runbooks/Exports/. Returns
       @{ rel; full; files; bytes (the files as they are); zipBytes; left = @(@{ path; reason; folder });
       leftByReason = @{ reason = count } }. A file that cannot be read is left out with reason
       unreadable; a zip that fails half way is removed. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [switch]$IncludeSource, [int64]$MaxFileBytes = 50MB, [datetime]$Now = (Get-Date))
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $root = $ProjectRoot.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "The project folder $(Split-Path -Leaf $root) does not exist." }
    $pkg = Get-PackageFiles $root -IncludeSource:$IncludeSource -MaxFileBytes $MaxFileBytes
    $rel = Get-PackageName $root $Now
    $full = Join-Path $root $rel.Replace('/', '\')
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full)
    $left = New-Object System.Collections.Generic.List[object]
    foreach ($x in @($pkg.left)) { $left.Add($x) }
    $packed = New-Object System.Collections.Generic.List[object]
    $bytes = [int64]0
    $fs = New-Object IO.FileStream($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $ok = $false
    try {
        $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            foreach ($f in @($pkg.files)) {
                $in = $null
                try { $in = New-Object IO.FileStream($f.full, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)) }
                catch { $left.Add(@{ path = $f.rel; reason = 'unreadable'; folder = $false }); continue }
                try {
                    $e = $zip.CreateEntry($f.rel, [IO.Compression.CompressionLevel]::Optimal)
                    try { $e.LastWriteTime = [DateTimeOffset](New-Object IO.FileInfo $f.full).LastWriteTime } catch { }
                    $out = $e.Open()
                    try { $in.CopyTo($out) } finally { $out.Dispose() }
                } finally { $in.Dispose() }
                $packed.Add($f); $bytes += [int64]$f.size
            }
            $done = @{ files = $packed.ToArray(); left = $left.ToArray() }
            Add-ZipText $zip $script:ReadmeName (New-SharingReadme $root $done -IncludeSource:$IncludeSource -MaxFileBytes $MaxFileBytes -Now $Now)
        } finally { $zip.Dispose() }
        $ok = $true
    } finally {
        $fs.Dispose()
        if (-not $ok) { try { [IO.File]::Delete($full) } catch { } }
    }
    $by = [ordered]@{}
    foreach ($x in $left) { $by[$x.reason] = 1 + [int]$by[$x.reason] }
    Write-CCBLog info package 'Project packaged' @{ files = $packed.Count; bytes = $bytes; left = $left.Count }
    @{ rel = $rel; full = $full; files = $packed.Count; bytes = $bytes; zipBytes = (New-Object IO.FileInfo $full).Length; left = $left.ToArray(); leftByReason = $by }
}

function Format-PackageSummary($Result) {
    # The status line: what went in and what was left out, by reason.
    $mb = if ($Result.zipBytes -ge 1MB) { ('{0:0.0} MB' -f ($Result.zipBytes / 1MB)).Replace(',', '.') } else { "$([Math]::Max(1, [Math]::Round($Result.zipBytes / 1KB))) KB" }
    $s = "Packed $($Result.files) file(s) into $($Result.rel) ($mb), with $($script:ReadmeName) on how to open it."
    $parts = @(foreach ($k in $Result.leftByReason.Keys) {
        $paths = @(@($Result.left) | Where-Object { $_.reason -eq $k } | ForEach-Object { $_.path })
        "$($script:Reasons[$k]) ($(@($paths | Select-Object -First 3) -join ', ')$(if ($paths.Count -gt 3) { ', ...' }))"
    })
    if ($parts.Count) { $s += " Left out: $($parts -join '; ')." }
    $s
}

Export-ModuleMember -Function Get-PackageReason, Get-PackageFiles, New-SharingReadme, Get-PackageName, New-ProjectPackage, Format-PackageSummary
