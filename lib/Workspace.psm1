# Project folders: they live under the user's OneDrive; CCBridge's own state does not.

$ErrorActionPreference = 'Stop'

$script:IgnoredDirs = @('.git', 'node_modules', 'bin', 'obj', 'dist', 'build', 'out', 'target', '.vs', '.vscode',
                        '.idea', '__pycache__', '.venv', 'venv', '.next', '.ccbridge', '.pytest_cache')

function Get-OneDriveRoot {
    foreach ($p in $env:OneDriveCommercial, $env:OneDrive, $env:OneDriveConsumer) {
        if ($p -and (Test-Path $p)) { return (Resolve-Path $p).Path.TrimEnd('\') }
    }
    throw 'No OneDrive folder found (OneDriveCommercial / OneDrive environment variables are empty).'
}

function Get-ProjectsRoot {
    param([string]$FolderName = 'CCBridge')
    $root = Join-Path (Get-OneDriveRoot) $FolderName
    if (-not (Test-Path $root)) { $null = New-Item -ItemType Directory -Path $root }
    $root
}

function Test-UnderOneDrive([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $od = Get-OneDriveRoot
    $full.StartsWith($od + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-CCBridgeProjects {
    param([string]$FolderName = 'CCBridge')
    $root = Get-ProjectsRoot $FolderName
    @(Get-ChildItem -Directory $root | Sort-Object LastWriteTime -Descending | ForEach-Object {
        [pscustomobject]@{ name = $_.Name; path = $_.FullName; modified = $_.LastWriteTime.ToString('s') }
    })
}

function New-CCBridgeProject {
    param([Parameter(Mandatory)][string]$Name, [string]$FolderName = 'CCBridge')
    if ($Name -notmatch '^[\w][\w .-]{0,63}$') { throw "Invalid project name '$Name' (letters, digits, space, . _ - only)" }
    $path = Join-Path (Get-ProjectsRoot $FolderName) $Name.Trim()
    if (Test-Path $path) { throw "A project named '$Name' already exists" }
    $null = New-Item -ItemType Directory -Path $path
    $memo = "# $Name`n`nInstructions for coding assistants. This file is sent to the assistant at the start of each chat.`nDescribe the goal, tech stack, build/run commands and conventions here.`n"
    [IO.File]::WriteAllText((Join-Path $path 'AGENTS.md'), $memo, (New-Object Text.UTF8Encoding($false)))
    $path
}

function Get-OneDriveLocation {
    <# Where a folder lives in the user's OneDrive: a display path ("OneDrive > CCBridge > name") and,
       for OneDrive for Business, the web address (from the OneDrive client's account settings).
       $null when the folder is not in a OneDrive folder. #>
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $accounts = @(Get-ChildItem HKCU:\Software\Microsoft\OneDrive\Accounts -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_.UserFolder })
    foreach ($a in $accounts) {
        $uf = ([string]$a.UserFolder).TrimEnd('\')
        if (-not $full.StartsWith($uf + '\', [StringComparison]::OrdinalIgnoreCase) -and $full -ne $uf) { continue }
        $rel = if ($full.Length -gt $uf.Length) { $full.Substring($uf.Length + 1) } else { '' }
        $url = $null
        if ($a.UserUrl) {
            $url = ([string]$a.UserUrl).TrimEnd('/') + '/Documents' + $(if ($rel) { '/' + (($rel.Split('\') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/') } else { '' })
        }
        return [pscustomobject]@{ Display = (@('OneDrive') + @($rel.Split('\') | Where-Object { $_ })) -join ' > '; Url = $url }
    }
    foreach ($od in $env:OneDriveCommercial, $env:OneDrive, $env:OneDriveConsumer) {
        if (-not $od) { continue }
        $root = $od.TrimEnd('\')
        if ($full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Display = (@('OneDrive') + @($full.Substring($root.Length + 1).Split('\'))) -join ' > '; Url = $null }
        }
    }
    $null
}

function Get-ProjectStateDir([string]$ProjectRoot) {
    <# Per-project state (backups, session) under %LOCALAPPDATA%, so OneDrive does not sync it. #>
    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProjectRoot.ToLowerInvariant())) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') })
    $dir = Join-Path $env:LOCALAPPDATA "CCBridge\projects\$((Split-Path $ProjectRoot -Leaf) -replace '[^\w.-]', '_')-$hash"
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir }
    $dir
}

function Resolve-ProjectPath {
    <# Resolves a project-relative path and refuses anything that escapes the project root. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$RelativePath)
    $rel = $RelativePath.Trim().Trim('"', "'", '`').Replace('/', '\').TrimStart('\')
    if (-not $rel -or [IO.Path]::IsPathRooted($rel)) { throw "Path must be relative to the project: '$RelativePath'" }
    $root = $ProjectRoot.TrimEnd('\')
    $full = [IO.Path]::GetFullPath((Join-Path $root $rel))
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Path is outside the project: '$RelativePath'" }
    $full
}

function ConvertTo-RelativePath([string]$ProjectRoot, [string]$FullPath) {
    $FullPath.Substring($ProjectRoot.TrimEnd('\').Length + 1).Replace('\', '/')
}

function Get-GitIgnoreMatchers([string]$ProjectRoot) {
    $gi = Join-Path $ProjectRoot '.gitignore'
    if (-not (Test-Path $gi)) { return @() }
    @(Get-Content $gi | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') -and -not $_.StartsWith('!') } |
        ForEach-Object { $_.TrimStart('/').TrimEnd('/') } | Where-Object { $_ })
}

function Test-Ignored([string]$Name, [string]$RelPath, [string[]]$Patterns) {
    foreach ($p in $Patterns) {
        if ($p.Contains('/')) { if ($RelPath -like $p -or $RelPath -like "$p/*") { return $true } }
        elseif ($Name -like $p) { return $true }
    }
    $false
}

function Get-ProjectFiles {
    <# Project files as relative '/' paths with sizes. Skips build/VCS folders and simple .gitignore entries. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [int]$MaxFiles = 5000)
    $patterns = Get-GitIgnoreMatchers $ProjectRoot
    $result = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($ProjectRoot)
    while ($stack.Count -and $result.Count -lt $MaxFiles) {
        $dir = $stack.Pop()
        foreach ($d in [IO.Directory]::GetDirectories($dir)) {
            $name = [IO.Path]::GetFileName($d)
            $rel = ConvertTo-RelativePath $ProjectRoot $d
            if ($script:IgnoredDirs -contains $name -or (Test-Ignored $name $rel $patterns)) { continue }
            $stack.Push($d)
        }
        foreach ($f in [IO.Directory]::GetFiles($dir)) {
            $name = [IO.Path]::GetFileName($f)
            $rel = ConvertTo-RelativePath $ProjectRoot $f
            if (Test-Ignored $name $rel $patterns) { continue }
            $result.Add([pscustomobject]@{ path = $rel; size = (New-Object IO.FileInfo $f).Length })
            if ($result.Count -ge $MaxFiles) { break }
        }
    }
    @($result | Sort-Object path)
}

function Format-ProjectTree {
    <# Compact file listing for prompts: one path per line with size. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [int]$MaxChars = 8000)
    $files = Get-ProjectFiles $ProjectRoot
    if (-not $files.Count) { return '(empty project)' }
    $sb = New-Object Text.StringBuilder
    foreach ($f in $files) {
        $line = "$($f.path) ($($f.size) B)"
        if ($sb.Length + $line.Length + 1 -gt $MaxChars) { [void]$sb.AppendLine("... ($($files.Count) files in total)"); break }
        [void]$sb.AppendLine($line)
    }
    $sb.ToString().TrimEnd()
}

# --- Source data (read-only) ---------------------------------------------------------
# User-provided data lives in <project>\source. Agents may read it but never change it:
# write/edit actions there are refused, and a copy in %LOCALAPPDATA% (the vault) is used
# to restore anything a command changed or deleted.

$script:SourceFolderName = 'source'
Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

function Get-SourceDir([string]$ProjectRoot) { Join-Path $ProjectRoot $script:SourceFolderName }

function Test-InSource([string]$ProjectRoot, [string]$FullPath) {
    $src = (Get-SourceDir $ProjectRoot).TrimEnd('\') + '\'
    $FullPath.StartsWith($src, [StringComparison]::OrdinalIgnoreCase)
}

function Get-SourceVaultDir([string]$ProjectRoot) { Join-Path (Get-ProjectStateDir $ProjectRoot) 'source-vault' }

function Get-FileFingerprint([string]$Path) {
    $fi = New-Object IO.FileInfo $Path
    if ($fi.Length -gt 50MB) { return "$($fi.Length)" }
    $sha = [Security.Cryptography.SHA256]::Create()
    $fs = [IO.File]::OpenRead($Path)
    try { [BitConverter]::ToString($sha.ComputeHash($fs)) } finally { $fs.Dispose() }
}

function Get-RelativeFiles([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $base = $Dir.TrimEnd('\').Length + 1
    @([IO.Directory]::GetFiles($Dir, '*', 'AllDirectories') | ForEach-Object { $_.Substring($base) })
}

function Set-ReadOnly([string]$Path, [bool]$On) {
    $fi = New-Object IO.FileInfo $Path
    if ($fi.Exists) { $fi.IsReadOnly = $On }
}

function Sync-SourceVault {
    <# Accepts the current source/ as the truth (called when the USER acts: turn start, upload). #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $src = Get-SourceDir $ProjectRoot
    $vault = Get-SourceVaultDir $ProjectRoot
    if (-not (Test-Path -LiteralPath $src)) { return }
    $null = New-Item -ItemType Directory -Force -Path $vault
    $srcFiles = Get-RelativeFiles $src
    foreach ($rel in $srcFiles) {
        $s = Join-Path $src $rel; $v = Join-Path $vault $rel
        if (-not (Test-Path -LiteralPath $v) -or (Get-FileFingerprint $s) -ne (Get-FileFingerprint $v)) {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $v)
            Set-ReadOnly $v $false
            [IO.File]::Copy($s, $v, $true)
        }
        Set-ReadOnly $s $true
    }
    foreach ($rel in Get-RelativeFiles $vault) {
        if ($srcFiles -notcontains $rel) { $v = Join-Path $vault $rel; Set-ReadOnly $v $false; [IO.File]::Delete($v) }
    }
}

function Restore-SourceData {
    <# Called after AGENT activity: puts back changed or deleted source files and moves files the
       agent added to source/ into work/. Returns a list of what was fixed. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $src = Get-SourceDir $ProjectRoot
    $vault = Get-SourceVaultDir $ProjectRoot
    $fixed = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $vault)) { return @() }
    $vaultFiles = Get-RelativeFiles $vault
    foreach ($rel in $vaultFiles) {
        $s = Join-Path $src $rel; $v = Join-Path $vault $rel
        $state = if (-not (Test-Path -LiteralPath $s)) { 'deleted' } elseif ((Get-FileFingerprint $s) -ne (Get-FileFingerprint $v)) { 'changed' } else { $null }
        if (-not $state) { continue }
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $s)
        Set-ReadOnly $s $false
        [IO.File]::Copy($v, $s, $true)
        Set-ReadOnly $s $true
        $fixed.Add("restored source/$($rel.Replace('\', '/')) ($state)")
    }
    foreach ($rel in Get-RelativeFiles $src) {
        if ($vaultFiles -contains $rel) { continue }
        $s = Join-Path $src $rel
        $dest = Join-Path (Join-Path $ProjectRoot 'work') $rel
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest)
        if (Test-Path -LiteralPath $dest) { [IO.File]::Delete($dest) }
        [IO.File]::Move($s, $dest)
        $fixed.Add("moved new file source/$($rel.Replace('\', '/')) to work/$($rel.Replace('\', '/'))")
    }
    if ($fixed.Count) { Write-CCBLog info source 'Source data restored after agent activity' @{ fixed = @($fixed) } }
    @($fixed)
}

function Save-SourceFile {
    <# Stores an uploaded file in source/ (never overwriting) and adds it to the vault. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][IO.Stream]$Content)
    $leaf = [IO.Path]::GetFileName($Name.Replace('/', '\'))
    if (-not $leaf -or $leaf.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "Invalid file name '$Name'" }
    $src = Get-SourceDir $ProjectRoot
    $null = New-Item -ItemType Directory -Force -Path $src
    $target = Join-Path $src $leaf
    $n = 2
    while (Test-Path -LiteralPath $target) {
        $target = Join-Path $src ('{0} ({1}){2}' -f [IO.Path]::GetFileNameWithoutExtension($leaf), $n, [IO.Path]::GetExtension($leaf)); $n++
    }
    $fs = [IO.File]::Create($target)
    try { $Content.CopyTo($fs) } finally { $fs.Dispose() }
    Sync-SourceVault $ProjectRoot
    ConvertTo-RelativePath $ProjectRoot $target
}

Export-ModuleMember -Function Get-OneDriveLocation, Get-OneDriveRoot, Get-ProjectsRoot, Test-UnderOneDrive, Get-CCBridgeProjects, New-CCBridgeProject,
    Get-ProjectStateDir, Resolve-ProjectPath, ConvertTo-RelativePath, Get-ProjectFiles, Format-ProjectTree,
    Get-SourceDir, Test-InSource, Sync-SourceVault, Restore-SourceData, Save-SourceFile
