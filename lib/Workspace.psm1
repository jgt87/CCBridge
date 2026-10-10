# Project folders: they live under the user's OneDrive; CCBridge's own state does not.

$ErrorActionPreference = 'Stop'

$script:IgnoredDirs = @('.git', 'node_modules', 'bin', 'obj', 'dist', 'build', 'out', 'target', '.vs', '.vscode',
                        '.idea', '__pycache__', '.venv', 'venv', '.next', '.ccbridge', '.streamhub', '.pytest_cache')

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

$script:SharedDirName = '.streamhub'

function Get-SharedRoot {
    <# The library every project in one folder shares: <parent of the project>\.streamhub (the UI kit
       catalogue, a shared AGENTS.md, Runbooks, Scripts, data tools), when that folder exists, or when
       -Create is given and the parent is a top-level OneDrive folder (the projects folder). Copilot
       reads it as shared/... (Resolve-ProjectPath) and never writes it. $null for a project without one. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [switch]$Create)
    $parent = Split-Path -Parent $ProjectRoot.TrimEnd('\')
    if (-not $parent) { return $null }
    $dir = Join-Path $parent $script:SharedDirName
    if (Test-Path -LiteralPath $dir -PathType Container) { return $dir }
    if (-not $Create) { return $null }
    $od = try { Get-OneDriveRoot } catch { $null }
    if (-not $od -or (Split-Path -Parent $parent.TrimEnd('\')) -ne $od) { return $null }
    $null = New-Item -ItemType Directory -Force -Path $dir
    Initialize-SharedRoot $dir
    $dir
}

function Get-SharedPrefix([string]$ProjectRoot) {
    <# The name Copilot reads the shared library under: shared/, or library/ when the project has a
       folder named shared of its own (shared-library/ when it has both), so a project's own folders
       always keep their names. The library itself is Get-SharedRoot. #>
    foreach ($name in 'shared', 'library', 'shared-library') {
        if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $name) -PathType Container)) { return $name }
    }
    'shared-library'
}

function Initialize-SharedRoot([string]$Dir) {
    # The shared instructions file, with a header that says what it is (dropped from what Copilot gets).
    $notes = Join-Path $Dir 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $notes)) {
        [IO.File]::WriteAllText($notes, "# Shared instructions`n`nInstructions for every project in this folder. The helper program sends them with each project's own AGENTS.md at the start of a chat.`nDescribe here what every project must follow: the organisation's conventions, naming, languages, the look, what to avoid.`n", (New-Object Text.UTF8Encoding($false)))
    }
}

function Get-SharedNotes([string]$ProjectRoot) {
    <# The shared AGENTS.md without its template lines; '' without one, or while nobody filled it in. #>
    $shared = Get-SharedRoot $ProjectRoot
    if (-not $shared) { return '' }
    $f = Join-Path $shared 'AGENTS.md'
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    $lines = @([IO.File]::ReadAllText($f).Replace("`r`n", "`n").Split("`n") | Where-Object { $_ -notmatch '^(Instructions for every project in this folder|Describe here what every project must follow)' })
    $meaningful = @($lines | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' })
    if (-not $meaningful.Count) { return '' }
    ($lines -join "`n").Trim()
}

function Test-UnderOneDrive([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $od = Get-OneDriveRoot
    $full.StartsWith($od + '\', [StringComparison]::OrdinalIgnoreCase)
}

$script:LanguageByExt = @{
    '.html' = 'HTML'; '.htm' = 'HTML'; '.css' = 'CSS'; '.scss' = 'CSS'; '.less' = 'CSS'
    '.js' = 'JavaScript'; '.mjs' = 'JavaScript'; '.cjs' = 'JavaScript'; '.jsx' = 'JavaScript'
    '.ts' = 'TypeScript'; '.tsx' = 'TypeScript'; '.vue' = 'Vue'; '.svelte' = 'Svelte'
    '.py' = 'Python'; '.pyw' = 'Python'; '.ps1' = 'PowerShell'; '.psm1' = 'PowerShell'; '.psd1' = 'PowerShell'
    '.cs' = 'C#'; '.java' = 'Java'; '.go' = 'Go'; '.rs' = 'Rust'; '.php' = 'PHP'; '.rb' = 'Ruby'
    '.sql' = 'SQL'; '.sh' = 'Shell'; '.cmd' = 'Batch'; '.bat' = 'Batch'
}

function Get-ProjectOverview {
    <# Size and type of a project for the project list: files, bytes, the main languages (most
       files first, at most 3) and whether it has source data. Reads file names and sizes only
       (nothing is opened, so OneDrive downloads nothing). #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $files = @(Get-ProjectFiles $ProjectRoot)
    $count = @{}
    $bytes = [int64]0; $source = 0
    foreach ($f in $files) {
        $bytes += [int64]$f.size
        if ($f.path -match '(?i)^source/') { $source++; continue }
        $lang = $script:LanguageByExt[[IO.Path]::GetExtension($f.path).ToLowerInvariant()]
        if ($lang) { $count[$lang] = 1 + [int]$count[$lang] }
    }
    $top = @($count.GetEnumerator() | Sort-Object @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key' } | Select-Object -First 3 | ForEach-Object { $_.Key })
    [pscustomobject]@{ files = $files.Count; bytes = $bytes; languages = $top; sourceFiles = $source; capped = ($files.Count -ge 5000) }
}

function Get-CCBridgeProjects {
    param([string]$FolderName = 'CCBridge')
    $root = Get-ProjectsRoot $FolderName
    @(Get-ChildItem -Directory $root | Where-Object { -not $_.Name.StartsWith('.') } | Sort-Object LastWriteTime -Descending | ForEach-Object {
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
    <# Per-project state (backups, session) under %LOCALAPPDATA%, so OneDrive does not sync it.
       CCBRIDGE_STATE_ROOT puts it elsewhere (the tests use a temporary folder they delete). #>
    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProjectRoot.ToLowerInvariant())) | Select-Object -First 6 | ForEach-Object { $_.ToString('x2') })
    $base = if ($env:CCBRIDGE_STATE_ROOT) { $env:CCBRIDGE_STATE_ROOT } else { Join-Path $env:LOCALAPPDATA 'CCBridge\projects' }
    $dir = Join-Path $base "$((Split-Path $ProjectRoot -Leaf) -replace '[^\w.-]', '_')-$hash"
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir }
    $dir
}

function Resolve-ProjectPath {
    <# Resolves a project-relative path and refuses anything that escapes the project root. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$RelativePath)
    $rel = $RelativePath.Trim().Trim('"', "'", '`').Replace('/', '\').TrimStart('\')
    if (-not $rel -or [IO.Path]::IsPathRooted($rel)) { throw "Path must be relative to the project: '$RelativePath'" }
    $root = $ProjectRoot.TrimEnd('\')
    # shared/... (library/ when the project has a shared folder of its own: Get-SharedPrefix) is the
    # library beside the projects (Get-SharedRoot).
    $prefix = Get-SharedPrefix $ProjectRoot
    if ($rel -match "^$([regex]::Escape($prefix))(\\|$)") {
        $shared = Get-SharedRoot $ProjectRoot
        if (-not $shared) { throw "There is no shared library beside this project ($prefix/ is the .streamhub folder next to the projects): '$RelativePath'" }
        $sroot = $shared.TrimEnd('\')
        $sfull = [IO.Path]::GetFullPath((Join-Path $sroot $rel.Substring($prefix.Length).TrimStart('\')))
        if ($sfull -ne $sroot -and -not $sfull.StartsWith($sroot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Path is outside the shared library: '$RelativePath'" }
        Assert-NoOutsideLink $sroot $sfull $RelativePath
        return $sfull
    }
    $full = [IO.Path]::GetFullPath((Join-Path $root $rel))
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Path is outside the project: '$RelativePath'" }
    Assert-NoOutsideLink $root $full $RelativePath
    $full
}

function Assert-NoOutsideLink {
    <# A junction or symbolic link inside the project can point outside it: a path through it looks
       inside but is not. Throws when the path, or a folder on the way to it, is such a link whose
       target is outside the project. Links that stay inside, and OneDrive's online-only
       placeholders (no link type), are fine. #>
    param([string]$Root, [string]$Full, [string]$Shown)
    $root = $Root.TrimEnd('\')
    $p = $Full.TrimEnd('\')
    while ($p.Length -gt $root.Length) {
        if (Test-Path -LiteralPath $p) {
            $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            if ($item -and $item.LinkType -in 'Junction', 'SymbolicLink') {
                foreach ($t in @($item.Target)) {
                    if (-not $t) { continue }
                    $tf = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($t)) { $t } else { Join-Path (Split-Path -Parent $p) $t })).TrimEnd('\')
                    if ($tf -ne $root -and -not $tf.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
                        throw "Path is outside the project: '$Shown' goes through a link to $tf"
                    }
                }
            }
        }
        $p = Split-Path -Parent $p
        if (-not $p) { break }
    }
}

function ConvertTo-RelativePath([string]$ProjectRoot, [string]$FullPath) {
    # A path in the project as PATH; one in the shared library beside the projects as shared/PATH.
    $root = $ProjectRoot.TrimEnd('\')
    if ($FullPath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return $FullPath.Substring($root.Length + 1).Replace('\', '/') }
    $shared = Get-SharedRoot $ProjectRoot
    if ($shared -and $FullPath.StartsWith($shared.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return "$(Get-SharedPrefix $ProjectRoot)/" + $FullPath.Substring($shared.TrimEnd('\').Length + 1).Replace('\', '/') }
    $FullPath.Substring($root.Length + 1).Replace('\', '/')
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
    # @(): with one file PowerShell 5.1 returns a single object, which has no Count.
    $files = @(Get-ProjectFiles $ProjectRoot)
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

$script:SourceFolderName = 'Source'
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
    <# The files under a folder as relative paths. Junctions and symbolic links are not followed: a link
       inside Source/ to a folder elsewhere must never make the vault or the restore touch files
       outside the project (such a link needs no rights to create). #>
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $base = $Dir.TrimEnd('\').Length + 1
    $out = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Dir.TrimEnd('\'))
    while ($stack.Count) {
        $d = $stack.Pop()
        foreach ($f in [IO.Directory]::GetFiles($d)) {
            if (([IO.File]::GetAttributes($f) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $out.Add($f.Substring($base))
        }
        foreach ($sub in [IO.Directory]::GetDirectories($d)) {
            if (([IO.File]::GetAttributes($sub) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            $stack.Push($sub)
        }
    }
    $out.ToArray()
}

function Set-ReadOnly([string]$Path, [bool]$On) {
    $fi = New-Object IO.FileInfo $Path
    if ($fi.Exists) { $fi.IsReadOnly = $On }
}

# --- Protected files (setting protectedPaths) ---------------------------------------------------
# Files the user marks as protected get the same treatment as Source/: Copilot's writes and edits are
# refused, and a command that changes or deletes one sees it put back afterwards.

function Get-ProtectedPatterns {
    <# The protected paths from the settings (one per line: a file, a folder ending in /, or a
       pattern with * and ?). Read from disk, so every runspace sees a change at once. #>
    param([string]$AppRoot)
    try {
        Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
        @(@((Get-CCBridgeConfig harness $AppRoot).protectedPaths) | Where-Object { "$_".Trim() } | ForEach-Object { "$_".Trim().Replace('\', '/').TrimStart('/') })
    } catch { @() }
}

function Test-ProtectedPath {
    <# The protected pattern a project path falls under, or $null. $Patterns defaults to the settings. #>
    param([string]$Path, $Patterns = $null)
    $list = if ($null -ne $Patterns) { @($Patterns) } else { @(Get-ProtectedPatterns) }
    $r = "$Path".Replace('\', '/').TrimStart('/')
    foreach ($q in $list) {
        if (-not $q) { continue }
        if ($q.EndsWith('/')) { if ($r.StartsWith($q, [StringComparison]::OrdinalIgnoreCase)) { return $q }; continue }
        if ($q -match '[*?]') {
            if ($r -like $q -or ($q -notmatch '/' -and ($r -split '/')[-1] -like $q)) { return $q }
            continue
        }
        if ($r -ieq $q -or $r.StartsWith("$q/", [StringComparison]::OrdinalIgnoreCase)) { return $q }
    }
    $null
}

function Get-ProtectedVaultDir([string]$ProjectRoot) { Join-Path (Get-ProjectStateDir $ProjectRoot) 'protected-vault' }

function Sync-ProtectedVault {
    <# Copies the protected files as they are now (the user's version) aside, to put them back after
       StreamHub's agent activity. Without protected paths the copy is removed. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, $Patterns = $null)
    $list = if ($null -ne $Patterns) { @($Patterns) } else { @(Get-ProtectedPatterns) }
    $vault = Get-ProtectedVaultDir $ProjectRoot
    if (-not $list.Count) { if (Test-Path -LiteralPath $vault) { [IO.Directory]::Delete($vault, $true) }; return }
    $keep = @{}
    foreach ($f in @(Get-ProjectFiles $ProjectRoot)) {
        if ([int64]$f.size -gt 50MB -or -not (Test-ProtectedPath $f.path $list)) { continue }
        $rel = $f.path.Replace('/', '\'); $keep[$rel.ToLowerInvariant()] = $true
        $s = Join-Path $ProjectRoot $rel; $v = Join-Path $vault $rel
        if (-not (Test-Path -LiteralPath $v) -or (Get-FileFingerprint $s) -ne (Get-FileFingerprint $v)) {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $v)
            [IO.File]::Copy($s, $v, $true)
        }
    }
    foreach ($rel in @(Get-RelativeFiles $vault)) { if (-not $keep.ContainsKey($rel.ToLowerInvariant())) { [IO.File]::Delete((Join-Path $vault $rel)) } }
}

function Restore-ProtectedFiles {
    <# Puts back protected files that agent activity changed or deleted. Returns what was fixed. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $vault = Get-ProtectedVaultDir $ProjectRoot
    if (-not (Test-Path -LiteralPath $vault)) { return @() }
    $fixed = New-Object System.Collections.Generic.List[string]
    foreach ($rel in @(Get-RelativeFiles $vault)) {
        $s = Join-Path $ProjectRoot $rel; $v = Join-Path $vault $rel
        $state = if (-not (Test-Path -LiteralPath $s)) { 'deleted' } elseif ((Get-FileFingerprint $s) -ne (Get-FileFingerprint $v)) { 'changed' } else { $null }
        if (-not $state) { continue }
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $s)
        Set-ReadOnly $s $false
        [IO.File]::Copy($v, $s, $true)
        $fixed.Add("restored protected file $($rel.Replace('\', '/')) ($state)")
    }
    if ($fixed.Count) { Write-CCBLog info source 'Protected files restored after agent activity' @{ fixed = @($fixed) } }
    @($fixed)
}

function Sync-SourceVault {
    <# Accepts the current Source/ as the truth (called when the USER acts: turn start, upload). #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    try { Sync-ProtectedVault $ProjectRoot } catch { Write-CCBLog info source "Protected files not copied aside: $($_.Exception.Message)" }
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
       agent added to Source/ into Work/. Returns a list of what was fixed. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $src = Get-SourceDir $ProjectRoot
    $vault = Get-SourceVaultDir $ProjectRoot
    $fixed = New-Object System.Collections.Generic.List[string]
    try { foreach ($x in @(Restore-ProtectedFiles $ProjectRoot)) { $fixed.Add($x) } } catch { Write-CCBLog info source "Protected files not checked: $($_.Exception.Message)" }
    if (-not (Test-Path -LiteralPath $vault)) { return @($fixed) }
    $vaultFiles = Get-RelativeFiles $vault
    foreach ($rel in $vaultFiles) {
        $s = Join-Path $src $rel; $v = Join-Path $vault $rel
        $state = if (-not (Test-Path -LiteralPath $s)) { 'deleted' } elseif ((Get-FileFingerprint $s) -ne (Get-FileFingerprint $v)) { 'changed' } else { $null }
        if (-not $state) { continue }
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $s)
        Set-ReadOnly $s $false
        [IO.File]::Copy($v, $s, $true)
        Set-ReadOnly $s $true
        $fixed.Add("restored Source/$($rel.Replace('\', '/')) ($state)")
    }
    foreach ($rel in Get-RelativeFiles $src) {
        if ($vaultFiles -contains $rel) { continue }
        $s = Join-Path $src $rel
        $dest = Join-Path (Join-Path $ProjectRoot 'Work') $rel
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest)
        # A file already in Work/ with that name is the person's; the new one gets a numbered name.
        $n = 1
        while (Test-Path -LiteralPath $dest) { $n++; $dest = Join-Path (Split-Path -Parent $dest) ([IO.Path]::GetFileNameWithoutExtension($rel) + " ($n)" + [IO.Path]::GetExtension($rel)) }
        [IO.File]::Move($s, $dest)
        $fixed.Add("moved new file Source/$($rel.Replace('\', '/')) to Work/$($dest.Substring((Join-Path $ProjectRoot 'Work').Length + 1).Replace('\', '/'))")
    }
    if ($fixed.Count) { Write-CCBLog info source 'Source data restored after agent activity' @{ fixed = @($fixed) } }
    @($fixed)
}

function Save-SourceFile {
    <# Stores an uploaded file in Source/ (never overwriting) and adds it to the vault. #>
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

Export-ModuleMember -Function Get-ProtectedPatterns, Test-ProtectedPath, Sync-ProtectedVault, Restore-ProtectedFiles, Get-ProjectOverview, Assert-NoOutsideLink, Get-OneDriveLocation, Get-OneDriveRoot, Get-ProjectsRoot, Test-UnderOneDrive, Get-CCBridgeProjects, New-CCBridgeProject,
    Get-ProjectStateDir, Resolve-ProjectPath, ConvertTo-RelativePath, Get-ProjectFiles, Format-ProjectTree,
    Get-SourceDir, Test-InSource, Sync-SourceVault, Restore-SourceData, Save-SourceFile, Get-SharedRoot, Get-SharedPrefix, Initialize-SharedRoot, Get-SharedNotes
