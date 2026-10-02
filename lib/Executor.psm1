# Carries out action blocks inside one project folder: read, search, write/edit files
# (with backups for undo) and run commands.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workspace.psm1')
Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

$script:Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Read-TextFile([string]$Path) {
    <# Returns text with LF line endings plus how to write it back (BOM, CRLF). #>
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = (New-Object Text.UTF8Encoding($false)).GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    [pscustomobject]@{ Text = $text.Replace("`r`n", "`n"); Bom = $bom; Crlf = $text.Contains("`r`n") }
}

function Write-TextFile([string]$Path, [string]$Text, [bool]$Bom = $false, [bool]$Crlf = $false) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $t = $Text.Replace("`r`n", "`n")
    if ($Crlf) { $t = $t.Replace("`n", "`r`n") }
    [IO.File]::WriteAllText($Path, $t, $(if ($Bom) { New-Object Text.UTF8Encoding($true) } else { $script:Utf8NoBom }))
}

function Test-BinaryFile([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 4096
        $n = $fs.Read($buf, 0, $buf.Length)
        for ($k = 0; $k -lt $n; $k++) { if ($buf[$k] -eq 0) { return $true } }
        $false
    } finally { $fs.Dispose() }
}

# Copilot's web page sends < and > in our prompts as &lt; and &gt;, so Copilot sometimes copies
# those entities into code. Markup files may contain entities on purpose and are left alone.
$script:MarkupExtensions = @('.html', '.htm', '.xhtml', '.xml', '.svg', '.xaml', '.vue', '.jsx', '.tsx', '.md', '.markdown', '.resx', '.config', '.csproj', '.props', '.targets')

function Test-MarkupFile([string]$Path) { $script:MarkupExtensions -contains [IO.Path]::GetExtension($Path).ToLowerInvariant() }

function ConvertFrom-AngleEntities([string]$Text) { $Text.Replace('&lt;', '<').Replace('&gt;', '>') }

function Repair-CodeText([string]$Path, [string]$Text) {
    if (Test-MarkupFile $Path) { return $Text }
    ConvertFrom-AngleEntities $Text
}
# --- Checkpoints (undo) --------------------------------------------------------------

function New-Checkpoint {
    <# Starts a checkpoint: before the first change to a file, its old content is copied here. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$Label = '')
    $id = (Get-Date).ToString('yyyyMMdd-HHmmss-fff')
    $dir = Join-Path (Get-ProjectStateDir $ProjectRoot) "backups\$id"
    $null = New-Item -ItemType Directory -Path $dir -Force
    [pscustomobject]@{ Id = $id; Dir = $dir; Label = $Label; Files = @{} }   # Files: rel -> 'existed' | 'new'
}

function Save-CheckpointFile($Checkpoint, [string]$ProjectRoot, [string]$FullPath) {
    $rel = ConvertTo-RelativePath $ProjectRoot $FullPath
    if ($Checkpoint.Files.ContainsKey($rel)) { return }
    if (Test-Path $FullPath) {
        $dest = Join-Path $Checkpoint.Dir ($rel.Replace('/', '\'))
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
        Copy-Item -LiteralPath $FullPath -Destination $dest
        $Checkpoint.Files[$rel] = 'existed'
    } else {
        $Checkpoint.Files[$rel] = 'new'
    }
    $Checkpoint.Files | ConvertTo-Json | Set-Content (Join-Path $Checkpoint.Dir 'manifest.json') -Encoding UTF8
}

function Undo-LastCheckpoint {
    <# Restores the files of the newest checkpoint that has changes, then removes it. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $base = Join-Path (Get-ProjectStateDir $ProjectRoot) 'backups'
    if (-not (Test-Path $base)) { return @() }
    foreach ($cp in Get-ChildItem -Directory $base | Sort-Object Name -Descending) {
        $manifest = Join-Path $cp.FullName 'manifest.json'
        if (-not (Test-Path $manifest)) { Remove-Item $cp.FullName -Recurse -Force; continue }
        $files = Get-Content $manifest -Raw | ConvertFrom-Json
        $restored = @()
        foreach ($p in $files.PSObject.Properties) {
            $full = Resolve-ProjectPath $ProjectRoot $p.Name
            if ($p.Value -eq 'new') { if (Test-Path $full) { Remove-Item -LiteralPath $full -Force } }
            else { Copy-Item -LiteralPath (Join-Path $cp.FullName ($p.Name.Replace('/', '\'))) -Destination $full -Force }
            $restored += $p.Name
        }
        Remove-Item $cp.FullName -Recurse -Force
        return $restored
    }
    @()
}

function Measure-LineChanges([string]$Old, [string]$New) {
    <# Lines added and removed between two texts (line multiset comparison; moved lines count as unchanged). #>
    $counts = New-Object Collections.Hashtable ([StringComparer]::Ordinal)   # exact: case changes count
    foreach ($l in $(if ($Old) { $Old.Replace("`r`n", "`n").TrimEnd("`n").Split("`n") } else { @() })) { $counts[$l] = 1 + [int]$counts[$l] }
    $added = 0
    foreach ($l in $(if ($New) { $New.Replace("`r`n", "`n").TrimEnd("`n").Split("`n") } else { @() })) {
        if ([int]$counts[$l] -gt 0) { $counts[$l] = $counts[$l] - 1 } else { $added++ }
    }
    $removed = 0
    foreach ($v in $counts.Values) { $removed += $v }
    @{ added = $added; removed = $removed }
}

function Get-CheckpointChanges {
    <# Per file changed since $Checkpoint started: lines added/removed, created, deleted. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$Checkpoint)
    foreach ($rel in @($Checkpoint.Files.Keys)) {
        $full = Join-Path $ProjectRoot ($rel.Replace('/', '\'))
        $old = if ($Checkpoint.Files[$rel] -eq 'new') { '' } else {
            $b = Join-Path $Checkpoint.Dir ($rel.Replace('/', '\'))
            if (Test-Path -LiteralPath $b) { (Read-TextFile $b).Text } else { '' }
        }
        $exists = Test-Path -LiteralPath $full -PathType Leaf
        $new = if ($exists) { (Read-TextFile $full).Text } else { '' }
        $d = Measure-LineChanges $old $new
        [pscustomobject]@{ path = $rel; created = ($Checkpoint.Files[$rel] -eq 'new'); deleted = (-not $exists); added = $d.added; removed = $d.removed }
    }
}

function Test-ProjectConsistency {
    <# Fixed checks on the given project files (no judgement of the code): JSON parses, PowerShell has
       no syntax errors, and local files referenced from HTML, JavaScript and CSS (href, src, fetch,
       import, url()) exist. Returns one line per problem. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Paths)
    foreach ($rel in @($Paths)) {
        try { $full = Resolve-ProjectPath $ProjectRoot $rel } catch { continue }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Test-BinaryFile $full)) { continue }
        $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
        $text = (Read-TextFile $full).Text
        if ($ext -eq '.json') {
            try { $null = $text | ConvertFrom-Json } catch { "${rel}: not valid JSON ($($_.Exception.Message.Split("`n")[0]))" }
        }
        if ($ext -in '.ps1', '.psm1', '.psd1') {
            $tok = $null; $errs = $null
            $null = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tok, [ref]$errs)
            foreach ($x in @($errs) | Select-Object -First 3) { "${rel}:$($x.Extent.StartLineNumber): $($x.Message)" }
        }
        if ($ext -in '.html', '.htm', '.js', '.mjs', '.jsx', '.ts', '.tsx', '.css') {
            $refs = New-Object System.Collections.Generic.List[string]
            foreach ($re in @('(?i)\b(?:href|src)\s*=\s*["'']([^"''#?]+)', '(?i)\bfetch\(\s*["''`]([^"''`?#]+)', '(?i)\bimport\s[^;]*?from\s*["'']([^"'']+)', '(?i)\burl\(\s*["'']?([^"'')?#]+)')) {
                foreach ($m in [regex]::Matches($text, $re)) { $refs.Add($m.Groups[1].Value.Trim()) }
            }
            foreach ($ref in ($refs | Select-Object -Unique)) {
                if (-not $ref -or $ref -match '^(?i)([a-z][a-z0-9+.-]*:|//|#|\$|\{)' -or $ref.Contains('${')) { continue }
                $target = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $full) ($ref.TrimStart('/').Replace('/', '\'))))
                if ($ref.StartsWith('/')) { $target = [IO.Path]::GetFullPath((Join-Path $ProjectRoot ($ref.TrimStart('/').Replace('/', '\')))) }
                if (-not $target.StartsWith([IO.Path]::GetFullPath($ProjectRoot), [StringComparison]::OrdinalIgnoreCase)) { continue }
                if (-not (Test-Path -LiteralPath $target)) { "${rel}: refers to $ref, which does not exist" }
            }
        }
    }
}

function Get-SessionChangeStats {
    <# Per changed file: lines added/removed since $SinceId (a checkpoint id, yyyyMMdd-HHmmss-fff),
       measured against the version before the first change in that period (from the undo backups). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$SinceId = '')
    $base = Join-Path (Get-ProjectStateDir $ProjectRoot) 'backups'
    $result = @{}
    if (-not (Test-Path $base)) { return $result }
    $baseline = @{}   # rel -> backup file, or $null for files the period created
    foreach ($cp in Get-ChildItem -Directory $base | Where-Object { $_.Name -ge $SinceId } | Sort-Object Name) {
        $manifest = Join-Path $cp.FullName 'manifest.json'
        if (-not (Test-Path $manifest)) { continue }
        foreach ($p in (Get-Content $manifest -Raw | ConvertFrom-Json).PSObject.Properties) {
            if ($baseline.ContainsKey($p.Name)) { continue }
            $baseline[$p.Name] = if ($p.Value -eq 'new') { $null } else { Join-Path $cp.FullName ($p.Name.Replace('/', '\')) }
        }
    }
    foreach ($rel in $baseline.Keys) {
        try {
            $full = Resolve-ProjectPath $ProjectRoot $rel
            if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Get-Item -LiteralPath $full).Length -gt 2MB -or (Test-BinaryFile $full)) { continue }
            $old = if ($baseline[$rel]) { (Read-TextFile $baseline[$rel]).Text } else { '' }
            $stats = Measure-LineChanges $old (Read-TextFile $full).Text
            if ($stats.added -or $stats.removed) { $result[$rel] = $stats }
        } catch { }
    }
    $result
}

# --- Actions -------------------------------------------------------------------------

function Get-FileOutline {
    <# The structure of a file with line numbers, so Copilot can read just the part it needs:
       HTML (head/body, style and script blocks, elements with an id, headings), JavaScript /
       TypeScript (functions, classes, arrow functions), CSS (@media blocks, section comments,
       selectors), PowerShell (functions), Markdown (headings). At most $Max entries. #>
    param([string]$Text, [string]$Path, [int]$Max = 80)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $lines = $Text.Replace("`r`n", "`n").Split("`n")
    $out = New-Object System.Collections.Generic.List[string]
    $open = @{}   # block name -> start line
    for ($i = 0; $i -lt $lines.Length -and $out.Count -lt $Max; $i++) {
        $l = $lines[$i]; $n = $i + 1; $t = $l.Trim()
        switch -Regex ($ext) {
            '^\.html?$' {
                if ($t -match '(?i)^<(head|body)\b') { $out.Add("$n  <$($Matches[1].ToLowerInvariant())>") }
                if ($t -match '(?i)<(style|script)\b([^>]*)>') {
                    $tag = $Matches[1].ToLowerInvariant(); $attrs = $Matches[2].Trim()
                    if ($t -match "(?i)</$tag>") { $out.Add("$n  <$tag$(if ($attrs) { " $attrs" })> (one line)") } else { $open[$tag] = @{ start = $n; attrs = $attrs } }
                } elseif ($t -match '(?i)</(style|script)>') {
                    $tag = $Matches[1].ToLowerInvariant()
                    if ($open[$tag]) { $out.Add("$($open[$tag].start)-$n  <$tag$(if ($open[$tag].attrs) { " $($open[$tag].attrs)" })> block"); $open.Remove($tag) }
                }
                if (-not $open['style'] -and -not $open['script']) {
                    if ($t -match '(?i)<(h[1-3])[^>]*>([^<]{1,60})') { $out.Add("$n  <$($Matches[1])> $($Matches[2].Trim())") }
                    elseif ($t -match '(?i)<(\w+)[^>]*\bid\s*=\s*["'']([^"'']+)') { $out.Add("$n  <$($Matches[1].ToLowerInvariant()) id=""$($Matches[2])"">") }
                } elseif ($open['script'] -and $t -match '^(async\s+)?function\s+([\w$]+)|^(const|let|var)\s+([\w$]+)\s*=\s*(async\s*)?(\([^)]*\)|[\w$]+)\s*=>|^class\s+([\w$]+)') {
                    $name = @($Matches[2], $Matches[4], $Matches[7]) | Where-Object { $_ } | Select-Object -First 1
                    $out.Add("$n    function $name (in script)")
                }
            }
            '^\.(js|mjs|cjs|jsx|ts|tsx)$' {
                if ($t -match '^(export\s+)?(default\s+)?(async\s+)?function\s*\*?\s*([\w$]+)') { $out.Add("$n  function $($Matches[4])") }
                elseif ($t -match '^(export\s+)?(const|let|var)\s+([\w$]+)\s*=\s*(async\s*)?(\([^)]*\)|[\w$]+)\s*=>') { $out.Add("$n  function $($Matches[3])") }
                elseif ($t -match '^(export\s+)?(default\s+)?class\s+([\w$]+)') { $out.Add("$n  class $($Matches[3])") }
            }
            '^\.(css|scss|less)$' {
                if ($t -match '^@media|^@supports|^@keyframes') { $out.Add("$n  $($t.TrimEnd('{').Trim())") }
                elseif ($t -match '^/\*\s*(.{3,60}?)\s*\*/$' -and $t -notmatch '^/\*\s*\*/') { $out.Add("$n  /* $($Matches[1]) */") }
                elseif ($l -match '^[^\s@/}][^{]*\{\s*$|^[^\s@/}][^{]*\{') { $out.Add("$n  $(($l -replace '\{.*$', '').Trim())") }
            }
            '^\.(ps1|psm1)$' {
                if ($t -match '^function\s+([\w-]+)') { $out.Add("$n  function $($Matches[1])") }
            }
            '^\.(md|markdown)$' {
                if ($t -match '^(#{1,4})\s+(.+)$') { $out.Add("$n  $($Matches[1]) $($Matches[2])") }
            }
        }
    }
    if ($out.Count -ge $Max) { $out.Add('(outline shortened)') }
    $out.ToArray()
}

function Split-ReadPath([string]$Spec) {
    <# "index.html", "index.html:181-420" or "index.html:181-" -> path and line range. #>
    $m = [regex]::Match($Spec.Trim(), '^(?<p>.+?):(?<a>\d+)(?:-(?<b>\d*))?$')
    if ($m.Success) {
        $b = if ($m.Groups['b'].Success -and $m.Groups['b'].Value) { [int]$m.Groups['b'].Value } elseif ($m.Groups['b'].Success) { [int]::MaxValue } else { [int]$m.Groups['a'].Value }
        return [pscustomobject]@{ Path = $m.Groups['p'].Value; From = [Math]::Max(1, [int]$m.Groups['a'].Value); To = $b }
    }
    [pscustomobject]@{ Path = $Spec.Trim(); From = 1; To = [int]::MaxValue }
}

function Invoke-ReadAction {
    <# File contents for Copilot. A path may carry a line range (PATH:START-END). Long content is
       cut at a whole line, with a note that says which lines are shown and how to read the rest. #>
    param([string]$ProjectRoot, [string[]]$Paths, [int]$MaxCharsPerFile = 40000)
    foreach ($spec in $Paths) {
        if ($spec -match '^(.+?):outline$') {
            $op = $Matches[1]
            try {
                $full = Resolve-ProjectPath $ProjectRoot $op
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { "### $op`n(file not found)"; continue }
                $text = (Read-TextFile $full).Text
                $total = $text.Replace("`r`n", "`n").Split("`n").Length
                $ol = @(Get-FileOutline $text $full)
                "### $op (outline, $total lines)`n````n$(if ($ol.Count) { $ol -join "`n" } else { '(no structure found; read the file or a line range)' })`n````"
            } catch { "### $op`n(error: $($_.Exception.Message))" }
            continue
        }
        $r = Split-ReadPath $spec
        $p = $r.Path
        try {
            $full = Resolve-ProjectPath $ProjectRoot $p
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { "### $p`n(file not found)"; continue }
            if (Test-BinaryFile $full) { "### $p`n(binary file, $((Get-Item -LiteralPath $full).Length) bytes - not shown)"; continue }
            $lines = (Read-TextFile $full).Text.Replace("`r`n", "`n").Split("`n")
            $total = $lines.Length
            $from = [Math]::Min($r.From, [Math]::Max(1, $total)); $to = [Math]::Min($r.To, $total)
            $sb = New-Object Text.StringBuilder
            $last = $from - 1
            for ($i = $from; $i -le $to; $i++) {
                $line = $lines[$i - 1]
                if ($sb.Length -gt 0 -and $sb.Length + $line.Length + 1 -gt $MaxCharsPerFile) { break }
                if ($sb.Length -gt 0) { [void]$sb.Append("`n") }
                [void]$sb.Append($line)
                $last = $i
            }
            $whole = ($from -eq 1 -and $last -eq $total)
            $head = if ($whole) { "### $p" } else { "### $p (lines $from-$last of $total)" }
            $note = if ($last -lt $to) {
                $ol = @(Get-FileOutline ($lines -join "`n") $full)
                "`n(cut to fit: showing lines $from-$last of $total. Read $($p):$($last + 1)-$to for the rest, or only the part you need using this outline.)" +
                $(if ($ol.Count) { "`nOutline of ${p}:`n" + ($ol -join "`n") } else { '' })
            } else { '' }
            $fence = '````'
            "$head`n$fence`n$($sb.ToString())`n$fence$note"
        } catch { "### $p`n(error: $($_.Exception.Message))" }
    }
}

function ConvertTo-GlobRegex([string]$Glob) {
    $g = $Glob.Trim().Replace('\', '/').TrimStart('/')
    $re = [regex]::Escape($g).Replace('\*\*/', '(.*/)?').Replace('\*\*', '.*').Replace('\*', '[^/]*').Replace('\?', '[^/]')
    if (-not $g.Contains('/')) { $re = '(.*/)?' + $re }
    "^$re$"
}

function Invoke-GlobAction {
    param([string]$ProjectRoot, [string]$Pattern)
    $re = ConvertTo-GlobRegex $Pattern
    $hits = @(Get-ProjectFiles $ProjectRoot | Where-Object { $_.path -match $re })
    if (-not $hits.Count) { return "(no files match $Pattern)" }
    ($hits | Select-Object -First 300 | ForEach-Object { "$($_.path) ($($_.size) B)" }) -join "`n"
}

function Invoke-GrepAction {
    param([string]$ProjectRoot, [string]$Pattern, [string]$FileGlob, [int]$MaxHits = 100)
    # Copilot often searches for plain text such as "fetch(": when the pattern is not a valid
    # regular expression, search for it literally instead of failing.
    $note = ''
    try { $null = [regex]::new($Pattern) }
    catch {
        $note = "(searched for the text literally: '$Pattern' is not a valid regular expression)`n"
        $Pattern = [regex]::Escape($Pattern)
    }
    $files = Get-ProjectFiles $ProjectRoot
    if ($FileGlob) { $re = ConvertTo-GlobRegex $FileGlob; $files = $files | Where-Object { $_.path -match $re } }
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($f in $files) {
        if ($f.size -gt 2MB) { continue }
        $full = Resolve-ProjectPath $ProjectRoot $f.path
        if (Test-BinaryFile $full) { continue }
        $n = 0
        foreach ($line in (Read-TextFile $full).Text.Split("`n")) {
            $n++
            if ($line -match $Pattern) {
                $hits.Add("$($f.path):$n`: $($line.Trim())")
                if ($hits.Count -ge $MaxHits) { return $note + ($hits -join "`n") + "`n(stopped at $MaxHits matches)" }
            }
        }
    }
    if (-not $hits.Count) { return "$note(no matches for $Pattern)" }
    $note + ($hits -join "`n")
}

function Assert-Writable([string]$ProjectRoot, [string]$Path) {
    <# Returns the full path, or throws when the path is user source data (read-only). #>
    $full = Resolve-ProjectPath $ProjectRoot $Path
    if (Test-InSource $ProjectRoot $full) {
        throw "$Path is in source/, which holds the user's source data and is read-only. Leave it unchanged and write your own working file elsewhere in the project (for example work/$([IO.Path]::GetFileName($full)))."
    }
    $full
}

function Get-WritePreview {
    <# Old and new content for the approval diff of a write action. #>
    param([string]$ProjectRoot, [string]$Path, [string]$Content)
    $full = Resolve-ProjectPath $ProjectRoot $Path
    $old = if (Test-Path -LiteralPath $full -PathType Leaf) { (Read-TextFile $full).Text } else { $null }
    [pscustomobject]@{ path = (ConvertTo-RelativePath $ProjectRoot $full); exists = ($null -ne $old); old = $old; new = (Repair-CodeText $full $Content) }
}

function Invoke-WriteAction {
    param([string]$ProjectRoot, [string]$Path, [string]$Content, $Checkpoint)
    $full = Assert-Writable $ProjectRoot $Path
    $bom = $false; $crlf = $false
    if (Test-Path -LiteralPath $full -PathType Leaf) { $info = Read-TextFile $full; $bom = $info.Bom; $crlf = $info.Crlf }
    $Content = Repair-CodeText $full $Content
    if ($Checkpoint) { Save-CheckpointFile $Checkpoint $ProjectRoot $full }
    if (-not $Content.EndsWith("`n")) { $Content += "`n" }
    Write-TextFile $full $Content $bom $crlf
    $lines = $Content.Split("`n").Length - 1
    "wrote $(ConvertTo-RelativePath $ProjectRoot $full) ($lines lines)"
}

function Get-LineNumber([string]$Text, [int]$Index) {
    if ($Index -le 0) { return 1 }
    ([regex]::Matches($Text.Substring(0, $Index), "`n")).Count + 1
}

function Get-LocalReferences([string]$Text) {
    <# Local files a text refers to: href/src attributes, fetch(), import ... from, CSS url(). #>
    $refs = New-Object System.Collections.Generic.List[string]
    foreach ($re in @('(?i)\b(?:href|src)\s*=\s*["'']([^"''#?]+)', '(?i)\bfetch\(\s*["''`]([^"''`?#]+)', '(?i)\bimport\s[^;]*?from\s*["'']([^"'']+)', '(?i)\burl\(\s*["'']?([^"'')?#]+)')) {
        foreach ($m in [regex]::Matches($Text, $re)) {
            $r = $m.Groups[1].Value.Trim()
            if ($r -and $r -notmatch '^(?i)([a-z][a-z0-9+.-]*:|//|#|\$|\{)' -and -not $r.Contains('${')) { $refs.Add($r) }
        }
    }
    @($refs | Select-Object -Unique)
}

function Test-MoveOrder {
    <# Guards against losing code that is being moved to another file: when an edit removes a sizeable
       block (15+ distinctive lines) and adds a reference to a local file, the removed lines must
       already be in that file. Returns $null when fine, else the reason (nothing is changed). #>
    param([string]$ProjectRoot, [string]$FullPath, [string]$Old, [string]$New)
    $newLines = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($l in $New.Replace("`r`n", "`n").Split("`n")) { [void]$newLines.Add($l.Trim()) }
    $removed = @($Old.Replace("`r`n", "`n").Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -ge 4 -and -not $newLines.Contains($_) } | Select-Object -Unique)
    if ($removed.Count -lt 15) { return $null }
    $before = @(Get-LocalReferences $Old)
    $added = @(Get-LocalReferences $New | Where-Object { $before -notcontains $_ })
    if (-not $added.Count) { return $null }
    $have = New-Object 'System.Collections.Generic.HashSet[string]'
    $names = @()
    foreach ($ref in $added) {
        $target = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $FullPath) ($ref.TrimStart('/').Replace('/', '\'))))
        if ($ref.StartsWith('/')) { $target = [IO.Path]::GetFullPath((Join-Path $ProjectRoot ($ref.TrimStart('/').Replace('/', '\')))) }
        $names += $ref
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            foreach ($l in (Read-TextFile $target).Text.Replace("`r`n", "`n").Split("`n")) { [void]$have.Add($l.Trim()) }
        }
    }
    $found = @($removed | Where-Object { $have.Contains($_) }).Count
    if ($found -ge [Math]::Ceiling($removed.Count * 0.8)) { return $null }
    $list = $names -join ', '
    "this edit removes $($removed.Count) lines from the file and links $list, but $list does not contain them yet (only $found of $($removed.Count) found). Nothing was changed, so no code is lost. First write $list with the complete moved code, then send this edit again."
}

function Test-AlreadyApplied([string]$Text, [string]$Search, [string]$Replace) {
    <# Whether a change whose SEARCH text is not in the file was already made: the new text is in the
       file (exactly or apart from indentation) and none of the distinctive old lines (8+ characters,
       not also in the new text) is left. For a removal (empty replacement) only the second applies.
       Returns @{ applied; evidence } - the evidence is reported, so Copilot can review the verdict. #>
    $fileLines = @($Text.Replace("`r`n", "`n").Split("`n") | ForEach-Object { $_.Trim() })
    $newLines = @($Replace.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $oldLines = @($Search.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -ge 8 -and $newLines -notcontains $_ })
    if (-not $oldLines.Count -and -not $newLines.Count) { return @{ applied = $false } }
    $left = @($oldLines | Where-Object { $fileLines -contains $_ })
    if ($left.Count) { return @{ applied = $false } }
    if (-not $newLines.Count) {
        return @{ applied = $true; evidence = "it removes text that is no longer in the file (none of its $($oldLines.Count) distinctive line(s) are there)" }
    }
    $pattern = '(?m)^' + (($Replace.Split("`n") | Where-Object { $_.Trim() } | ForEach-Object { '[ \t]*' + [regex]::Escape($_.Trim()) + '[ \t]*' }) -join '\n(?:[ \t]*\n)*')
    $m = [regex]::Match($Text, $pattern)
    if (-not $m.Success) { return @{ applied = $false } }
    $from = Get-LineNumber $Text $m.Index
    $to = Get-LineNumber $Text ($m.Index + [Math]::Max(0, $m.Length - 1))
    @{ applied = $true; evidence = "the new text is already at lines $from-$to and none of the old lines are in the file" }
}

function Get-ClosestLines([string]$Text, [string]$Search) {
    <# The file's current lines where $Search most likely belongs (most SEARCH lines found nearby),
       for Copilot to copy exactly in its next try. #>
    $fileLines = $Text.Replace("`r`n", "`n").Split("`n")
    $want = @($Search.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -ge 3 })
    if (-not $want.Count) { return 'Read the file again and copy the lines exactly.' }
    $span = [Math]::Max(1, $Search.Split("`n").Count)
    $best = -1; $bestScore = 0
    for ($i = 0; $i -lt $fileLines.Length; $i++) {
        $t = $fileLines[$i].Trim()
        if (-not $t) { continue }
        # A line counts when it equals, or contains, one of the SEARCH lines (or the other way round).
        $hit = $false
        foreach ($w in $want) { if ($t -eq $w -or ($w.Length -ge 8 -and ($t.Contains($w) -or $w.Contains($t) -and $t.Length -ge 8))) { $hit = $true; break } }
        if (-not $hit) { continue }
        $score = 0
        for ($k = $i; $k -lt [Math]::Min($fileLines.Length, $i + $span + 2); $k++) {
            $tk = $fileLines[$k].Trim()
            if ($tk -and ($want -contains $tk)) { $score++ }
        }
        if ($score -gt $bestScore -or ($score -eq $bestScore -and $best -lt 0)) { $best = $i; $bestScore = [Math]::Max($score, 1) }
    }
    if ($best -lt 0) { return 'None of its lines are in the file as written: read the file again (or grep for a distinctive part) and copy the lines exactly.' }
    $from = [Math]::Max(0, $best - 2); $to = [Math]::Min($fileLines.Length - 1, $best + $span + 2)
    $snippet = ($fileLines[$from..$to] -join "`n")
    if ($snippet.Length -gt 3000) { $snippet = $snippet.Substring(0, 3000) }
    "The closest place is lines $($from + 1)-$($to + 1); their exact current text is:`n````n$snippet`n````"
}

$script:EllipsisLine = '^\s*(\.\.\.|\u2026|/\*\s*(\.\.\.|\u2026)\s*\*/|<!--\s*(\.\.\.|\u2026)\s*-->|//\s*(\.\.\.|\u2026)|#\s*(\.\.\.|\u2026))\s*$'

function Find-ElidedTarget([string]$Text, [string]$Search) {
    <# A SEARCH shortened with a line of only "..." (first lines, ..., last lines): the block from the
       first lines through the first following occurrence of the last lines. Must match one place. #>
    $segments = New-Object System.Collections.Generic.List[string]
    $cur = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Search.Split("`n")) {
        if ($l -match $script:EllipsisLine) { if ($cur.Count) { $segments.Add(($cur -join "`n")); $cur = New-Object System.Collections.Generic.List[string] } }
        else { $cur.Add($l) }
    }
    if ($cur.Count) { $segments.Add(($cur -join "`n")) }
    if ($segments.Count -lt 2) { return $null }
    $parts = foreach ($s in $segments) { ($s.Trim("`n").Split("`n") | ForEach-Object { '[ \t]*' + [regex]::Escape($_.Trim()) + '[ \t]*' }) -join '\n' }
    $pattern = '(?m)^' + ($parts -join '\n[\s\S]*?\n') + '$'
    $ms = [regex]::Matches($Text, $pattern)
    if ($ms.Count -eq 1) { return @{ start = $ms[0].Index; length = $ms[0].Length; note = "replaced lines $(Get-LineNumber $Text $ms[0].Index)-$(Get-LineNumber $Text ($ms[0].Index + $ms[0].Length - 1)) (SEARCH shortened with ...)" } }
    if ($ms.Count -gt 1) { return @{ error = "the shortened SEARCH (with ...) matches $($ms.Count) places; include more of its first lines" } }
    @{ error = 'SEARCH text not found in the file (shortened with ...): its first lines or its last lines are not in the file as written. Read the file again and copy them exactly.' }
}

function Get-BlockBalance([string]$Text) {
    <# Net open minus close counts of braces and of style/script tags, to spot half blocks. #>
    $t = [regex]::Replace($Text, '("([^"\\\n]|\\.)*"|''([^''\\\n]|\\.)*'')', '""')   # ignore braces in strings
    @{
        braces = ([regex]::Matches($t, '\{')).Count - ([regex]::Matches($t, '\}')).Count
        style  = ([regex]::Matches($Text, '(?i)<style\b')).Count - ([regex]::Matches($Text, '(?i)</style>')).Count
        script = ([regex]::Matches($Text, '(?i)<script\b')).Count - ([regex]::Matches($Text, '(?i)</script>')).Count
    }
}

function Test-HalfBlock([string]$Old, [string]$New) {
    <# Whether an edit leaves the file more unbalanced than it was: more unclosed (or unopened)
       { } blocks or <style>/<script> blocks after the edit than before. A file that is already
       broken may be repaired, or edited without making it worse. Returns the reason, or $null. #>
    $o = Get-BlockBalance $Old; $n = Get-BlockBalance $New
    foreach ($k in 'style', 'script') {
        if ([Math]::Abs($n[$k]) -gt [Math]::Abs($o[$k])) { return "this edit would leave a <$k> block half open or half closed in the file, so part of that block would be left behind. Include the whole block through its closing </$k> line (you may shorten its middle with a line containing only ...)" }
    }
    if ([Math]::Abs($n.braces) -gt [Math]::Abs($o.braces)) { return "this edit would leave a { } block half open or half closed in the file, so part of that block would be left behind. Include the whole block through its closing brace (you may shorten its middle with a line containing only ...)" }
    $null
}

function Find-EditTarget([string]$Text, [string]$Search, [int]$After = -1) {
    <# Where $Search is in $Text: one exact match (or, failing that, one match ignoring trailing
       whitespace per line). When it matches several places and $After is the end of the previous
       change in the same edit block, the first match after it is taken (changes come in file
       order) and a note says so; otherwise the error lists the line of every match. #>
    if (($Search.Split("`n") | Where-Object { $_ -match $script:EllipsisLine }) -and $Text.IndexOf($Search, [StringComparison]::Ordinal) -lt 0) {
        $el = Find-ElidedTarget $Text $Search
        if ($el) { return $el }
    }
    $hits = New-Object System.Collections.Generic.List[object]
    $i = $Text.IndexOf($Search, [StringComparison]::Ordinal)
    while ($i -ge 0 -and $Search.Length) {
        $hits.Add(@{ start = $i; length = $Search.Length })
        $i = $Text.IndexOf($Search, $i + 1, [StringComparison]::Ordinal)
    }
    if (-not $hits.Count) {
        $pattern = '(?m)' + (($Search.Split("`n") | ForEach-Object { [regex]::Escape($_.TrimEnd()) + '[ \t]*' }) -join '\n')
        foreach ($m in [regex]::Matches($Text, $pattern)) { $hits.Add(@{ start = $m.Index; length = $m.Length }) }
    }
    $note = $null
    if (-not $hits.Count -and $Search.Trim()) {
        # Same lines with different indentation (spaces vs tabs, another depth).
        $pattern = '(?m)^' + (($Search.Split("`n") | ForEach-Object { '[ \t]*' + [regex]::Escape($_.Trim()) + '[ \t]*' }) -join '\n')
        foreach ($m in [regex]::Matches($Text, $pattern)) { $hits.Add(@{ start = $m.Index; length = $m.Length }) }
        if ($hits.Count) { $note = 'matched ignoring indentation' }
    }
    if ($hits.Count -eq 1) { if ($note) { $hits[0].note = $note }; return $hits[0] }
    if (-not $hits.Count) { return @{ error = "SEARCH text not found in the file. $(Get-ClosestLines $Text $Search)" } }
    $lines = @($hits | ForEach-Object { Get-LineNumber $Text $_.start })
    if ($After -ge 0) {
        $next = $hits | Where-Object { $_.start -ge $After } | Select-Object -First 1
        if ($next) {
            $line = Get-LineNumber $Text $next.start
            return @{ start = $next.start; length = $next.length; note = "matched $($hits.Count) places (lines $(($lines | Select-Object -First 6) -join ', ')); changed the one at line $line, the first after the previous change" }
        }
    }
    @{ error = "SEARCH text matches $($hits.Count) places (lines $(($lines | Select-Object -First 6) -join ', ')); include more surrounding lines so it matches only one" }
}

function Get-EditResult {
    <# Applies SEARCH/REPLACE pairs in memory. All pairs must apply, or nothing is written. #>
    param([string]$ProjectRoot, [string]$Path, $Edits)
    try { $full = Assert-Writable $ProjectRoot $Path } catch { return [pscustomobject]@{ ok = $false; error = $_.Exception.Message } }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return [pscustomobject]@{ ok = $false; error = "file not found: $Path (use write to create it)" } }
    if (-not $Edits -or -not @($Edits).Count) {
        return [pscustomobject]@{ ok = $false; error = 'edit block has no SEARCH/REPLACE pairs. Each change needs a line <<<<<<< SEARCH, the exact current lines, a line =======, the new lines, and a line >>>>>>> REPLACE, with real < and > characters at the start of the line. To replace the whole file, use a write block instead.' }
    }
    $info = Read-TextFile $full
    $text = $info.Text
    $n = 0
    $after = -1   # end of the previous change: a SEARCH that matches several places takes the next one
    $notes = New-Object System.Collections.Generic.List[string]
    $applied = New-Object System.Collections.Generic.List[string]   # pairs found already made
    foreach ($e in $Edits) {
        $n++
        $search = $e.search.Replace("`r`n", "`n")
        $replace = Repair-CodeText $full $e.replace.Replace("`r`n", "`n")
        $hit = Find-EditTarget $text $search $after
        if ($hit.error -and $search -match '&lt;|&gt;') { $hit = Find-EditTarget $text (ConvertFrom-AngleEntities $search) $after }
        if ($hit.error -and $hit.error -like 'SEARCH text not found*') {
            # Not an error when the change is already in the file (Copilot sent an edit again).
            $done = Test-AlreadyApplied $text $search $replace
            if ($done.applied) { $applied.Add("pair ${n}: already applied - $($done.evidence)"); continue }
        }
        if ($hit.error) { return [pscustomobject]@{ ok = $false; error = "pair $n`: $($hit.error). Nothing was changed; send the whole edit block again." } }

        if ($hit.note) { $notes.Add("pair ${n}: $($hit.note)") }
        $text = $text.Substring(0, $hit.start) + $replace + $text.Substring($hit.start + $hit.length)
        $after = $hit.start + $replace.Length
    }
    $half = Test-HalfBlock $info.Text $text
    if ($half) { return [pscustomobject]@{ ok = $false; error = "$half. Nothing was changed; send the whole edit block again." } }
    $moveProblem = Test-MoveOrder $ProjectRoot $full $info.Text $text
    if ($moveProblem) { return [pscustomobject]@{ ok = $false; error = $moveProblem } }
    [pscustomobject]@{ ok = $true; full = $full; old = $info.Text; new = $text; bom = $info.Bom; crlf = $info.Crlf; pairs = $n; notes = @($notes)
        alreadyApplied = @($applied); unchanged = ($text -ceq $info.Text) }
}

function Format-AlreadyApplied([string]$Rel, $R) {
    <# The result of an edit whose changes were all already made: no error, but the verdict and its
       evidence go back to Copilot to review. #>
    "no change needed: $Rel already contains these changes. " + (@($R.alreadyApplied) -join '; ') + '. Check that this is what you meant; if not, read the file and send a corrected edit.'
}

function Invoke-EditAction {
    param([string]$ProjectRoot, [string]$Path, $Edits, $Checkpoint)
    $r = Get-EditResult $ProjectRoot $Path $Edits
    if (-not $r.ok) { throw $r.error }
    $rel = ConvertTo-RelativePath $ProjectRoot $r.full
    if ($r.unchanged) { return Format-AlreadyApplied $rel $r }
    if ($Checkpoint) { Save-CheckpointFile $Checkpoint $ProjectRoot $r.full }
    Write-TextFile $r.full $r.new $r.bom $r.crlf
    if (@($r.alreadyApplied).Count) { return "edited $rel ($($r.pairs - @($r.alreadyApplied).Count) change(s)); " + (@($r.alreadyApplied) -join '; ') + '. If that is not what you meant, send a corrected edit.' }
    "edited $(ConvertTo-RelativePath $ProjectRoot $r.full) ($($r.pairs) change(s))" + $(if (@($r.notes).Count) { "; " + (@($r.notes) -join "; ") + ". Check that this is the right place." } else { '' })
}

# --- Human in the loop -----------------------------------------------------------------
# Commands that could act on Microsoft 365 data (mail, Teams, calendar, files, Graph) or delete
# data never run without a person approving them; headless callers (MCP) cannot run them at all.

$script:M365CommandPatterns = @(
    @{ re = 'Send-MailMessage|System\.Net\.Mail|SmtpClient|\bsmtp\b|mailto:'; why = 'sends email' },
    @{ re = 'Outlook\.Application|Microsoft\.Office\.Interop\.Outlook|\boutlook(\.exe)?\s+/'; why = 'controls Outlook' },
    @{ re = 'graph\.microsoft\.com|Connect-MgGraph|Microsoft\.Graph|\b[A-Za-z]+-Mg[A-Za-z]+'; why = 'uses Microsoft Graph' },
    @{ re = 'MicrosoftTeams|Connect-MicrosoftTeams|\bteams\.microsoft\.com|\bTeams\.exe'; why = 'uses Microsoft Teams' },
    @{ re = 'ExchangeOnline|Connect-ExchangeOnline|outlook\.office(365)?\.com'; why = 'uses Exchange / Outlook online' },
    @{ re = 'Connect-PnPOnline|\bPnP\.PowerShell|\.sharepoint\.com|Connect-SPOService'; why = 'uses SharePoint / OneDrive online' },
    @{ re = 'login\.microsoftonline\.com|Get-AzAccessToken|az\s+account\s+get-access-token'; why = 'obtains Microsoft 365 access tokens' }
)
$script:DestructiveCommandPatterns = @(
    @{ re = '(^|[\s;&|(])(del|erase|rd|rmdir)(\s|$)'; why = 'deletes files' },
    @{ re = 'Remove-Item|\b(rm|rmdir)\s+-|\bri\s|Clear-Content|Clear-RecycleBin'; why = 'deletes files' },
    @{ re = '\bRemove-[A-Za-z]+'; why = 'removes data' },
    @{ re = 'robocopy\b.*\s/(MIR|PURGE)\b'; why = 'mirrors with deletion' },
    @{ re = 'Format-Volume|\bformat\s+[a-z]:|diskpart|cipher\s+/w'; why = 'wipes a disk' },
    @{ re = '\bgit\s+(clean\s+-[a-z]*f|reset\s+--hard|push\s+.*--force)'; why = 'discards data in git' }
)

function Get-CommandRisk {
    <# Returns @{ m365 = bool; destructive = bool; reasons = string[] } for a shell command. #>
    param([string]$Command)
    $reasons = New-Object System.Collections.Generic.List[string]
    $m365 = $false; $destructive = $false
    foreach ($p in $script:M365CommandPatterns) { if ($Command -match $p.re) { $m365 = $true; if (-not $reasons.Contains($p.why)) { $reasons.Add($p.why) } } }
    foreach ($p in $script:DestructiveCommandPatterns) { if ($Command -match $p.re) { $destructive = $true; if (-not $reasons.Contains($p.why)) { $reasons.Add($p.why) } } }
    if ($m365 -or $destructive) { Write-CCBLog info exec 'Risky command detected' @{ command = $Command; reasons = @($reasons) } }
    @{ m365 = $m365; destructive = $destructive; reasons = @($reasons) }
}

function Invoke-RunAction {
    <# Runs a command with cmd.exe in the project folder. Output is trimmed to head + tail. #>
    param([string]$ProjectRoot, [string]$Command, [int]$TimeoutSec = 120, [int]$MaxChars = 8000, [scriptblock]$CancelCheck)
    # Several lines (Copilot often sends a sequence): a cmd /c command line only runs the first, so
    # they go into a temporary batch file that echoes each command and stops at the first failure.
    $lines = @($Command.Replace("`r`n", "`n").Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $batch = $null
    if ($lines.Count -gt 1) {
        $batch = Join-Path $env:TEMP ('run-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.cmd')
        $body = New-Object Text.StringBuilder
        [void]$body.AppendLine('@echo off')
        foreach ($l in $lines) {
            [void]$body.AppendLine('echo ^> ' + ($l -replace '([&|<>^%])', '^$1'))
            [void]$body.AppendLine('call ' + $l)
            [void]$body.AppendLine('if errorlevel 1 exit /b %errorlevel%')
        }
        [IO.File]::WriteAllText($batch, $body.ToString(), (New-Object Text.UTF8Encoding($false)))
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = "$env:ComSpec"
    $psi.Arguments = if ($batch) { '/d /s /c ""' + $batch + '" 2>&1"' } else { '/d /s /c "' + $Command + ' 2>&1"' }
    $psi.WorkingDirectory = $ProjectRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    # Wait in short steps so a Stop from the user ends the command (and its children) at once.
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $timedOut = $false; $cancelled = $false
    while (-not $p.WaitForExit(250)) {
        if ($CancelCheck -and (& $CancelCheck)) { $cancelled = $true; break }
        if ((Get-Date) -gt $deadline) { $timedOut = $true; break }
    }
    if ($timedOut -or $cancelled) { cmd.exe /c "taskkill /PID $($p.Id) /T /F >nul 2>&1"; $p.WaitForExit(5000) | Out-Null }
    $text = ($out.Result + $err.Result).Replace("`r`n", "`n").TrimEnd()
    Write-CCBLog verbose exec "run finished" @{ command = $Command; exitCode = $(if ($timedOut -or $cancelled) { $null } else { $p.ExitCode }); timedOut = $timedOut; cancelled = $cancelled; outputChars = $text.Length }
    if ($text.Length -gt $MaxChars) {
        $head = [int]($MaxChars * 0.25)
        $text = $text.Substring(0, $head) + "`n... ($($text.Length - $MaxChars) characters omitted) ...`n" + $text.Substring($text.Length - ($MaxChars - $head))
    }
    if ($batch) { try { [IO.File]::Delete($batch) } catch { } }
    [pscustomobject]@{ exitCode = $(if ($timedOut -or $cancelled) { $null } else { $p.ExitCode }); timedOut = $timedOut; cancelled = $cancelled; output = $text }
}

Export-ModuleMember -Function Get-FileOutline, Get-CheckpointChanges, Test-ProjectConsistency, Format-AlreadyApplied, Get-SessionChangeStats, Get-CommandRisk, Assert-Writable, Read-TextFile, New-Checkpoint, Undo-LastCheckpoint, Invoke-ReadAction, Invoke-GlobAction, Invoke-GrepAction,
    Get-WritePreview, Invoke-WriteAction, Get-EditResult, Invoke-EditAction, Invoke-RunAction
