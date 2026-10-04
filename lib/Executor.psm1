# Carries out action blocks inside one project folder: read, search, write/edit files
# (with backups for undo) and run commands.

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workspace.psm1')
Import-Module (Join-Path $PSScriptRoot 'Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'Guardrails.psm1')

$script:Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Get-TextEncodingName([byte[]]$Bytes) {
    <# utf8bom, utf16le, utf16be (by their BOM), utf8 (valid UTF-8) or ansi (anything else: the
       Windows code page, e.g. a file saved by older Notepad or Excel). #>
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return 'utf8bom' }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return 'utf16le' }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return 'utf16be' }
    try { $null = (New-Object Text.UTF8Encoding($false, $true)).GetString($Bytes); 'utf8' } catch { 'ansi' }
}

function Get-TextEncoding([string]$Name) {
    switch ($Name) {
        'utf8bom' { New-Object Text.UTF8Encoding($true) }
        'utf16le' { New-Object Text.UnicodeEncoding($false, $true) }
        'utf16be' { New-Object Text.UnicodeEncoding($true, $true) }
        'ansi' { [Text.Encoding]::Default }
        default { New-Object Text.UTF8Encoding($false) }
    }
}

function Read-TextFile([string]$Path) {
    <# Text with LF line endings, plus how to write it back: its encoding (utf8, utf8bom, ansi,
       utf16le, utf16be), BOM, and CRLF when most of its lines end that way. #>
    $bytes = [IO.File]::ReadAllBytes($Path)
    $enc = Get-TextEncodingName $bytes
    $skip = switch ($enc) { 'utf8bom' { 3 } 'utf16le' { 2 } 'utf16be' { 2 } default { 0 } }
    $text = (Get-TextEncoding $enc).GetString($bytes, $skip, $bytes.Length - $skip)
    $crlf = ([regex]::Matches($text, "`r`n")).Count
    $lf = ([regex]::Matches($text, "(?<!`r)`n")).Count
    [pscustomobject]@{ Text = $text.Replace("`r`n", "`n"); Bom = ($enc -in 'utf8bom', 'utf16le', 'utf16be'); Crlf = ($crlf -gt $lf); Encoding = $enc }
}

function Write-TextFile([string]$Path, [string]$Text, [bool]$Bom = $false, [bool]$Crlf = $false, [string]$Encoding = '') {
    <# Writes in the given encoding (as read, or the default for a new file); without one, UTF-8
       with or without BOM. A PowerShell file in UTF-8 without BOM that now holds non-ASCII text
       gets a BOM: Windows PowerShell 5.1 reads BOM-less files as ANSI and would garble it. #>
    if ($Path -match '(?i)\.ps[md]?1$' -and $Encoding -in '', 'utf8' -and $Text -match '[^\x00-\x7F]') {
        if ($Encoding -eq 'utf8' -or -not $Bom) { Write-CCBLog verbose executor "Saved with a BOM so Windows PowerShell 5.1 reads its non-ASCII text: $Path" }
        $Bom = $true; $Encoding = 'utf8bom'
    }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $t = $Text.Replace("`r`n", "`n")
    if ($Crlf) { $t = $t.Replace("`n", "`r`n") }
    $enc = if ($Encoding) { $Encoding } elseif ($Bom) { 'utf8bom' } else { 'utf8' }
    [IO.File]::WriteAllText($Path, $t, (Get-TextEncoding $enc))
}

function Get-NewFileFormat {
    <# How a new file is written, by type: .ps1/.psm1/.psd1 with a BOM when they contain non-ASCII
       (Windows PowerShell 5.1 reads BOM-less files as ANSI); .cmd/.bat with CRLF and no BOM;
       .csv/.tsv with a BOM (Excel); everything else UTF-8 without BOM. Line endings: CRLF for
       .cmd/.bat, else what most of the project's text files use (LF when there are none). #>
    param([string]$Path, [string]$Text, [string]$ProjectRoot)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $nonAscii = $Text -match '[^\x00-\x7F]'
    $bom = ($ext -in '.ps1', '.psm1', '.psd1' -and $nonAscii) -or ($ext -in '.csv', '.tsv')
    $crlf = if ($ext -in '.cmd', '.bat') { $true } else { Get-ProjectLineEnding $ProjectRoot }
    @{ Bom = $bom; Crlf = $crlf; Encoding = $(if ($bom) { 'utf8bom' } else { 'utf8' }) }
}

function Get-ProjectLineEnding([string]$ProjectRoot) {
    <# Whether most of the project's text files (up to 40 looked at) use CRLF. #>
    if (-not $ProjectRoot -or -not (Test-Path -LiteralPath $ProjectRoot)) { return $false }
    $crlf = 0; $lf = 0; $n = 0
    foreach ($f in @(Get-ProjectFiles $ProjectRoot)) {
        if ($n -ge 40) { break }
        if ($f.path -notmatch '(?i)\.(ps1|psm1|psd1|js|mjs|cjs|jsx|ts|tsx|css|scss|html?|json|md|txt|py|cs|java|xml|ya?ml|sql|sh|cmd|bat)$' -or [int64]$f.size -gt 512KB -or $f.path -match '(?i)^source/') { continue }
        try {
            $t = [IO.File]::ReadAllText((Resolve-ProjectPath $ProjectRoot $f.path))
            if ($t.Contains("`n")) { $n++; if ($t.Contains("`r`n")) { $crlf++ } else { $lf++ } }
        } catch { }
    }
    $crlf -gt $lf
}
function Test-BinaryFile([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] 4096
        $n = $fs.Read($buf, 0, $buf.Length)
        # UTF-16 text has zero bytes too: its BOM tells it apart.
        if ($n -ge 2 -and (($buf[0] -eq 0xFF -and $buf[1] -eq 0xFE) -or ($buf[0] -eq 0xFE -and $buf[1] -eq 0xFF))) { return $false }
        for ($k = 0; $k -lt $n; $k++) { if ($buf[$k] -eq 0) { return $true } }
        $false
    } finally { $fs.Dispose() }
}

# Copilot's web page sends < and > in our prompts as &lt; and &gt;, so Copilot sometimes copies
# those entities into code. Markup files may contain entities on purpose and are left alone.
$script:MarkupExtensions = @('.html', '.htm', '.xhtml', '.xml', '.svg', '.xaml', '.vue', '.jsx', '.tsx', '.md', '.markdown', '.resx', '.config', '.csproj', '.props', '.targets')

function Test-MarkupFile([string]$Path) { $script:MarkupExtensions -contains [IO.Path]::GetExtension($Path).ToLowerInvariant() }

function ConvertFrom-AngleEntities([string]$Text) { $Text.Replace('&lt;', '<').Replace('&gt;', '>') }

# Code files (not prose, markup or data) where invisible characters from a web chat are never meant.
$script:CodeTextExt = '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|svelte|ps1|psm1|psd1|py|pyw|css|scss|less|json|ya?ml|toml|ini|sh|bash|cmd|bat|cs|java|kt|go|rs|php|sql|c|cc|cpp|h|hpp|swift|dart|lua|r)$'
$script:Invisible = '[' + [char]0x200B + [char]0x200C + [char]0x200D + [char]0x2060 + [char]0xFEFF + ']'
$script:OddSpace = '[' + [char]0x00A0 + [char]0x202F + [char]0x2007 + ']'

function Repair-CodeText([string]$Path, [string]$Text) {
    <# Text from Copilot made fit for the file: &lt; / &gt; back to < and > (not in markup), and in
       code files the invisible characters a web chat brings along removed (zero-width spaces,
       a BOM in the middle) and non-breaking spaces made normal spaces. #>
    if ($Path -match $script:CodeTextExt) {
        $Text = [regex]::Replace($Text, $script:Invisible, '')
        $Text = [regex]::Replace($Text, $script:OddSpace, ' ')
    }
    if (Test-MarkupFile $Path) { return $Text }
    ConvertFrom-AngleEntities $Text
}

function Find-CodeArtifacts {
    <# What Copilot's text brings along that does not belong in a code file: invisible characters
       and odd spaces (removed by Repair-CodeText), curly quotes and long dashes (reported, they
       may be meant in text), and the replacement character (a sign of broken text). #>
    param([string]$Path, [string]$Text)
    $r = @{ removed = 0; curlyLines = @(); replacement = 0 }
    if ($Path -notmatch $script:CodeTextExt) { return $r }
    $r.removed = ([regex]::Matches($Text, $script:Invisible)).Count + ([regex]::Matches($Text, $script:OddSpace)).Count
    $r.replacement = ([regex]::Matches($Text, [string][char]0xFFFD)).Count
    $curly = '[' + [char]0x201C + [char]0x201D + [char]0x2018 + [char]0x2019 + [char]0x2013 + [char]0x2014 + ']'
    $lines = $Text.Replace("`r`n", "`n").Split("`n")
    $r.curlyLines = @(for ($i = 0; $i -lt $lines.Length; $i++) { if ($lines[$i] -match $curly) { $i + 1 } })
    $r
}

function Test-EncodingFit {
    <# Why new text cannot be saved in a file's encoding, or $null: .cmd/.bat must be ASCII; an
       ANSI file only holds characters of the Windows code page; a new replacement character
       means the text was garbled. #>
    param([string]$Path, [string]$Old, [string]$New, [string]$Encoding)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $repl = [string][char]0xFFFD
    if (([regex]::Matches("$New", $repl)).Count -gt ([regex]::Matches("$Old", $repl)).Count) { return 'the new text contains the replacement character (a sign of garbled text); send the real characters' }
    if ($ext -in '.cmd', '.bat') {
        $m = [regex]::Match("$New", '[^\x00-\x7F]')
        if ($m.Success) { $line = ([regex]::Matches($New.Substring(0, $m.Index), "`n")).Count + 1; return "batch files (.cmd, .bat) must be plain ASCII; line $line has '$($m.Value)'. Use plain characters, or put the text in another file" }
    }
    if ($Encoding -eq 'ansi') {
        $enc = [Text.Encoding]::Default
        $back = $enc.GetString($enc.GetBytes("$New"))
        if ($back -cne "$New") {
            for ($i = 0; $i -lt $New.Length; $i++) { if ($back[$i] -ne $New[$i]) { break } }
            $line = ([regex]::Matches($New.Substring(0, [Math]::Min($i, $New.Length)), "`n")).Count + 1
            return "the file is saved in the Windows code page ($($enc.WebName)), which cannot hold '$($New[$i])' (line $line). Use characters of that code page, or ask the user to save the file as UTF-8 first"
        }
    }
    $null
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
    Save-CheckpointManifest $Checkpoint
}

# --- Commands in the change set: what a run command changes is backed up too --------------
# Before a run command, the project's files are listed (size and time) and the ones not yet in
# the change set are copied aside (prerun\, once per step). After the command, every file it
# changed or deleted gets its old copy in the change set, and every file it created is marked new,
# so Undo restores them like a write or an edit. source/ is left out (its own restore covers it).

$script:SnapshotMaxFileBytes = 20MB
$script:SnapshotMaxTotalBytes = 300MB

function Get-FileState([string]$ProjectRoot) {
    # rel path -> "size|time" of the project's files (ignored folders such as node_modules left out).
    $h = @{}
    foreach ($f in @(Get-ProjectFiles $ProjectRoot -MaxFiles 20000)) {
        if ($f.path -like 'source/*') { continue }
        $fi = New-Object IO.FileInfo (Join-Path $ProjectRoot ($f.path.Replace('/', '\')))
        if ($fi.Exists) { $h[$f.path] = "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)" }
    }
    $h
}

function Save-CheckpointManifest($Checkpoint) {
    $Checkpoint.Files | ConvertTo-Json | Set-Content (Join-Path $Checkpoint.Dir 'manifest.json') -Encoding UTF8
}

function Start-RunSnapshot {
    <# Before a run command: copies aside the files not yet in the change set (skipping very large
       ones). Returns the snapshot to hand to Complete-RunSnapshot, with what could not be copied. #>
    param([Parameter(Mandatory)]$Checkpoint, [Parameter(Mandatory)][string]$ProjectRoot)
    if (-not $Checkpoint.PSObject.Properties['Staged']) { $Checkpoint | Add-Member -NotePropertyName Staged -NotePropertyValue @{} }
    $stage = Join-Path $Checkpoint.Dir 'prerun'
    $before = Get-FileState $ProjectRoot
    $skipped = New-Object System.Collections.Generic.List[string]
    $total = 0L
    foreach ($rel in $before.Keys) {
        if ($Checkpoint.Files.ContainsKey($rel)) { continue }                       # already backed up in this step
        if ($Checkpoint.Staged[$rel] -eq $before[$rel]) { continue }                # copied before, unchanged since
        $size = [int64]($before[$rel] -split '\|')[0]
        if ($size -gt $script:SnapshotMaxFileBytes -or $total + $size -gt $script:SnapshotMaxTotalBytes) { $skipped.Add($rel); continue }
        $dest = Join-Path $stage ($rel.Replace('/', '\'))
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest)
        [IO.File]::Copy((Join-Path $ProjectRoot ($rel.Replace('/', '\'))), $dest, $true)
        $Checkpoint.Staged[$rel] = $before[$rel]
        $total += $size
    }
    @{ before = $before; stage = $stage; skipped = $skipped.ToArray() }
}

function Complete-RunSnapshot {
    <# After a run command: puts every file it changed, deleted or created into the change set.
       Returns @{ changed = rel paths; notBackedUp = changed files that were too large to copy }. #>
    param([Parameter(Mandatory)]$Checkpoint, [Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$Snapshot)
    $after = Get-FileState $ProjectRoot
    $changed = New-Object System.Collections.Generic.List[string]
    $lost = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $Snapshot.before.Keys) {
        if ($after[$rel] -eq $Snapshot.before[$rel] -or $Checkpoint.Files.ContainsKey($rel)) { continue }
        $copy = Join-Path $Snapshot.stage ($rel.Replace('/', '\'))
        if (Test-Path -LiteralPath $copy) {
            $dest = Join-Path $Checkpoint.Dir ($rel.Replace('/', '\'))
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest)
            [IO.File]::Copy($copy, $dest, $true)
            $Checkpoint.Files[$rel] = 'existed'
        } else { $lost.Add($rel) }
        $changed.Add($rel)
    }
    foreach ($rel in $after.Keys) {
        if ($Snapshot.before.ContainsKey($rel) -or $Checkpoint.Files.ContainsKey($rel)) { continue }
        $Checkpoint.Files[$rel] = 'new'
        $changed.Add($rel)
    }
    if ($changed.Count) { Save-CheckpointManifest $Checkpoint }
    @{ changed = $changed.ToArray(); notBackedUp = $lost.ToArray() }
}

function Clear-RunSnapshot($Checkpoint) {
    # At the end of a step: the copies set aside are no longer needed (the change set has its own).
    $stage = Join-Path $Checkpoint.Dir 'prerun'
    if (Test-Path -LiteralPath $stage) { [IO.Directory]::Delete($stage, $true) }
}

function Remove-EmptyFolders([string]$ProjectRoot, [string]$Dir) {
    # Folders a step created and its undo left empty go too, up to (not including) the project
    # folder. OneDrive can mark folders read-only, which blocks deleting them: the mark is cleared.
    $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
    $d = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
    while ($d.Length -gt $root.Length -and $d.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -and [IO.Directory]::Exists($d)) {
        if (@([IO.Directory]::GetFileSystemEntries($d)).Count) { break }
        try { (New-Object IO.DirectoryInfo $d).Attributes = 'Directory'; [IO.Directory]::Delete($d) } catch { break }
        $d = Split-Path -Parent $d
    }
}

function Get-UndoFileChange([string]$Full, [string]$Backup, [string]$Rel, [bool]$WasNew) {
    <# What undoing does to one file, measured before it happens: the lines that come back (added)
       and the lines that go (removed), and a preview (old = now, new = after the undo). Binary
       files get no line counts. #>
    $now = if (Test-Path -LiteralPath $Full -PathType Leaf) { $Full } else { $null }
    $after = if ($WasNew) { $null } else { $Backup }
    $text = { param($p) if ($p -and -not (Test-BinaryFile $p)) { (Read-TextFile $p).Text } else { $null } }
    $binary = ($now -and (Test-BinaryFile $now)) -or ($after -and (Test-Path -LiteralPath $after) -and (Test-BinaryFile $after))
    $o = [ordered]@{ path = $Rel; deleted = $WasNew; added = 0; removed = 0; binary = [bool]$binary; preview = $null }
    if (-not $binary) {
        $old = "$(& $text $now)"; $new = "$(& $text $after)"
        $m = Measure-LineChanges $old $new
        $o.added = $m.added; $o.removed = $m.removed
        $cap = 200000
        $o.preview = @{ path = $Rel; exists = [bool]$now; old = $(if ($old.Length -le $cap) { $old } else { $null }); new = $(if ($new.Length -le $cap) { $new } else { '(too large to show)' }) }
    }
    [pscustomobject]$o
}

function Undo-LastCheckpoint {
    <# Restores the files of the newest checkpoint that has changes, then removes it. Returns the
       restored paths; with -Detailed, per file what the undo changed (Get-UndoFileChange). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [switch]$Detailed)
    $base = Join-Path (Get-ProjectStateDir $ProjectRoot) 'backups'
    if (-not (Test-Path $base)) { return @() }
    foreach ($cp in Get-ChildItem -Directory $base | Sort-Object Name -Descending) {
        $manifest = Join-Path $cp.FullName 'manifest.json'
        if (-not (Test-Path $manifest)) { Remove-Item $cp.FullName -Recurse -Force; continue }
        $files = Get-Content $manifest -Raw | ConvertFrom-Json
        $restored = @()
        foreach ($p in $files.PSObject.Properties) {
            # Resolve-ProjectPath refuses paths outside the project, also through links.
            $full = try { Resolve-ProjectPath $ProjectRoot $p.Name } catch { Write-CCBLog info exec "Undo skipped $($p.Name): $($_.Exception.Message)"; continue }
            $backup = Join-Path $cp.FullName ($p.Name.Replace('/', '\'))
            $detail = if ($Detailed) { try { Get-UndoFileChange $full $backup $p.Name ($p.Value -eq 'new') } catch { [pscustomobject]@{ path = $p.Name; deleted = ($p.Value -eq 'new'); added = 0; removed = 0; binary = $true; preview = $null } } }
            if ($p.Value -eq 'new') { if (Test-Path -LiteralPath $full -PathType Leaf) { Remove-Item -LiteralPath $full -Force } }
            else {
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full)   # a folder a command removed
                Copy-Item -LiteralPath $backup -Destination $full -Force
            }
            $restored += $(if ($Detailed) { $detail } else { $p.Name })
            if ($p.Value -eq 'new') { Remove-EmptyFolders $ProjectRoot (Split-Path -Parent $full) }
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

function Get-ChangeSetContents {
    <# Per changed file: the contents before and after the change set, so the calling program can
       check them (MCP tasks). Each text is cut at 200,000 characters. #>
    param([string]$ProjectRoot, $Checkpoint)
    foreach ($rel in @($Checkpoint.Files.Keys)) {
        $full = Join-Path $ProjectRoot ($rel.Replace('/', '\'))
        $old = ''
        if ($Checkpoint.Files[$rel] -ne 'new') {
            $b = Join-Path $Checkpoint.Dir ($rel.Replace('/', '\'))
            if ((Test-Path -LiteralPath $b) -and -not (Test-BinaryFile $b)) { $old = (Read-TextFile $b).Text }
        }
        $exists = Test-Path -LiteralPath $full -PathType Leaf
        $new = if ($exists -and -not (Test-BinaryFile $full)) { (Read-TextFile $full).Text } else { '' }
        if ($old -ceq $new) { continue }
        @{ path = $rel; created = ($Checkpoint.Files[$rel] -eq 'new'); deleted = (-not $exists); old = $(if ($old.Length -gt 200000) { $old.Substring(0, 200000) } else { $old }); new = $(if ($new.Length -gt 200000) { $new.Substring(0, 200000) } else { $new }) }
    }
}

function Resolve-ModuleImport([string]$Target) {
    <# Whether an import path exists the way bundlers and TypeScript resolve it: as written, with an
       extension added, as a folder with an index file, or a .js name that is a .ts/.tsx source. #>
    $exts = '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.mts', '.cts', '.json', '.vue', '.svelte', '.d.ts', '.css', '.scss'
    if (Test-Path -LiteralPath $Target -PathType Leaf) { return $true }
    foreach ($e in $exts) { if (Test-Path -LiteralPath ($Target + $e) -PathType Leaf) { return $true } }
    if (Test-Path -LiteralPath $Target -PathType Container) {
        foreach ($e in $exts) { if (Test-Path -LiteralPath (Join-Path $Target "index$e") -PathType Leaf) { return $true } }
    }
    if ($Target -match '(?i)\.(m|c)?jsx?$') {
        $stem = $Target -replace '(?i)\.(m|c)?jsx?$', ''
        foreach ($e in '.ts', '.tsx', '.mts', '.cts') { if (Test-Path -LiteralPath ($stem + $e) -PathType Leaf) { return $true } }
    }
    $false
}

function ConvertTo-CheckableScript([string]$Text) {
    <# JavaScript module code as classic script for a syntax-only check, with the same line numbers:
       static imports and re-exports become blank lines, export keywords are dropped, import.meta
       becomes an object, and the whole is wrapped in an async function so top-level await parses. #>
    $blank = [Text.RegularExpressions.MatchEvaluator] { param($m) "`n" * ([regex]::Matches($m.Value, "`n")).Count }
    $t = $Text.Replace("`r`n", "`n")
    $t = [regex]::Replace($t, '(?m)^[ \t]*import\s+(?:type\s+)?(?:[\w$*{}\s,]+?\s+from\s+)?["''][^"''\n]+["''][ \t]*;?', $blank)
    $t = [regex]::Replace($t, '(?m)^[ \t]*export\s+(?:type\s+)?(?:\*(?:\s+as\s+[\w$]+)?|\{[^}]*\})\s*(?:from\s*["''][^"''\n]+["''])?[ \t]*;?', $blank)
    $t = [regex]::Replace($t, '(?m)^([ \t]*)export\s+default\s+', '$1void ')
    $t = [regex]::Replace($t, '(?m)^([ \t]*)export\s+(?=(?:async\s+)?function|class\b|const\b|let\b|var\b)', '$1')
    $t = $t.Replace('import.meta', '({})')
    '(async function(){' + $t + "`n})"
}

function Test-ServedProject([string]$ProjectRoot) {
    <# Whether the project's pages run from a build tool or web server (package.json, a bundler config,
       a server script) rather than being opened straight from disk. #>
    foreach ($n in 'package.json', 'vite.config.js', 'vite.config.ts', 'vite.config.mjs', 'webpack.config.js', 'server.js', 'server.ts', 'server.py', 'server.ps1', 'app.py', 'manage.py', 'web.config', 'staticwebapp.config.json') {
        if (Test-Path -LiteralPath (Join-Path $ProjectRoot $n) -PathType Leaf) { return $true }
    }
    $false
}

function Get-PagesLoading([string]$ProjectRoot, [string]$Rel) {
    # The project's HTML pages that load $Rel with a script tag (the page itself for an HTML file).
    if ($Rel -match '(?i)\.html?$') { return @($Rel) }
    if (-not $ProjectRoot) { return @() }
    $leaf = [IO.Path]::GetFileName($Rel)
    $pages = New-Object System.Collections.Generic.List[string]
    foreach ($f in Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -Include '*.html', '*.htm' -ErrorAction SilentlyContinue) {
        $pr = ConvertTo-RelativePath $ProjectRoot $f.FullName
        if ($pr -match '(?i)(^|/)(node_modules|dist|build|source|\.streamhub|History)/') { continue }
        $t = [IO.File]::ReadAllText($f.FullName)
        foreach ($m in [regex]::Matches($t, '(?i)<script\b[^>]*\bsrc\s*=\s*["'']([^"''?#]+)')) {
            if ([IO.Path]::GetFileName($m.Groups[1].Value) -ne $leaf) { continue }
            if ((Resolve-RelRef $ProjectRoot (Split-Path -Parent $pr) $m.Groups[1].Value) -eq $Rel) { $pages.Add($pr); break }
        }
    }
    $pages.ToArray()
}

function Resolve-RelRef([string]$ProjectRoot, [string]$BaseDir, [string]$Ref) {
    # A reference written in a file in $BaseDir (project-relative), as a project-relative path.
    $root = if ($ProjectRoot) { $ProjectRoot } else { 'C:\p' }
    $dir = if ($Ref.StartsWith('/') -or -not $BaseDir) { $root } else { Join-Path $root ("$BaseDir".Replace('/', '\')) }
    $full = [IO.Path]::GetFullPath((Join-Path $dir ($Ref.TrimStart('/').Replace('/', '\'))))
    $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\')
    if (-not $full.StartsWith("$rootFull\", [StringComparison]::OrdinalIgnoreCase)) { return $null }
    $full.Substring($rootFull.Length + 1).Replace('\', '/')
}

function Get-RelativeRef([string]$FromDir, [string]$To) {
    # How a file in $FromDir refers to $To (both project-relative, / separated).
    $fromParts = @("$FromDir".Split('/') | Where-Object { $_ })
    $toParts = @($To.Split('/'))
    $i = 0
    while ($i -lt $fromParts.Count -and $i -lt ($toParts.Count - 1) -and $fromParts[$i] -eq $toParts[$i]) { $i++ }
    $up = @(for ($k = $i; $k -lt $fromParts.Count; $k++) { '..' })
    (@($up) + @($toParts[$i..($toParts.Count - 1)])) -join '/'
}

function Get-DataScriptFix([string]$ProjectRoot, [string]$DataRel, [string[]]$Pages, [string]$UsedBy) {
    # The replacement for a blocked data file: a .js file next to it that sets a global, loaded by
    # each page with a script tag before the script that uses it.
    $stem = [IO.Path]::GetFileNameWithoutExtension($DataRel)
    $words = @($stem -split '[^A-Za-z0-9]+' | Where-Object { $_ })
    if (-not $words.Count) { $words = @('page') }
    $name = $words[0].Substring(0, 1).ToLowerInvariant() + $words[0].Substring(1)
    for ($k = 1; $k -lt $words.Count; $k++) { $name += $words[$k].Substring(0, 1).ToUpperInvariant() + $words[$k].Substring(1) }
    if ($name -match '^\d') { $name = "data$name" }
    $name += 'Data'
    $dir = [IO.Path]::GetDirectoryName($DataRel.Replace('/', '\')).Replace('\', '/')
    $prefix = if ($dir) { "$dir/" } else { '' }
    $jsRel = "$prefix$stem.js"
    if ($ProjectRoot -and (Test-Path -LiteralPath (Join-Path $ProjectRoot $jsRel.Replace('/', '\')) -PathType Leaf)) {
        $existing = [IO.File]::ReadAllText((Join-Path $ProjectRoot $jsRel.Replace('/', '\')))
        if ($existing -notmatch "window\.$name\s*=") { $jsRel = "$prefix$stem.data.js" }
    }
    $value = if ($DataRel -match '(?i)\.json$') { "the contents of $DataRel" } else { "the contents of $DataRel as a text string" }
    $tags = @(foreach ($pg in @($Pages)) {
        $src = Get-RelativeRef (Split-Path -Parent $pg).Replace('\', '/') $jsRel
        $where = if ($UsedBy -and $UsedBy -ne $pg) { "before the script tag that loads $UsedBy" } else { 'before the script that uses it' }
        "add <script src=""$src""></script> to $pg $where"
    })
    if (-not $tags.Count) { $tags = @("load it with <script src=""...""></script> in the page, before the script that uses it") }
    "Replace it: write $jsRel containing window.$name = $value;, $($tags -join ' and '), and use window.$name directly instead (no fetch, await or .then)"
}

function Find-FileUrlBlocks {
    <# A page opened straight from disk (file://, no web server) may not fetch local files, import
       JSON or load module scripts: Edge and Chrome block them ("blocked by CORS policy", origin
       'null'). Finds those in an HTML or JavaScript file of a project without a server
       (Test-ServedProject). Each finding names the line and the exact replacement: the .js data
       file to write, the global it sets, and the script tag to add to which page
       (Get-DataScriptFix). #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Text, [string]$ProjectRoot = '')
    $ext = [IO.Path]::GetExtension($Rel).ToLowerInvariant()
    if ($ext -notin '.html', '.htm', '.js', '.mjs') { return }
    $line = { param($i) ([regex]::Matches($Text.Substring(0, $i), "`n")).Count + 1 }
    $isLocal = { param($u) $u -and $u -notmatch '(?i)^([a-z][a-z0-9+.-]*:|//)' -and $u -notmatch '\$\{' }
    $blocked = 'is blocked when the page is opened from disk (file://).'
    $fileDir = (Split-Path -Parent $Rel).Replace('\', '/')
    $pages = $null
    if ($ext -in '.html', '.htm') {
        foreach ($m in [regex]::Matches($Text, '(?i)<script\b[^>]*\btype\s*=\s*["'']?module\b')) {
            "${Rel}:$(& $line $m.Index): <script type=""module""> $blocked Use plain <script src> tags in the right order, without import/export."
        }
        foreach ($m in [regex]::Matches($Text, '(?i)<script\b[^>]*\bsrc\s*=\s*["'']([^"''?#]+\.json)["'']')) {
            $u = $m.Groups[1].Value
            if (-not (& $isLocal $u)) { continue }
            $data = Resolve-RelRef $ProjectRoot $fileDir $u
            "${Rel}:$(& $line $m.Index): <script src=""$u""> cannot load JSON. $(Get-DataScriptFix $ProjectRoot $data @($Rel) $Rel)"
        }
    }
    # fetch and XMLHttpRequest resolve against the page; import against the file itself.
    $calls = @(
        @{ re = '(?i)\bfetch\(\s*["''`]([^"''`]+)'; what = 'fetch(''{0}'')'; page = $true },
        @{ re = '(?i)\.open\(\s*["'']GET["'']\s*,\s*["'']([^"'']+)'; what = 'loading {0} with XMLHttpRequest'; page = $true },
        @{ re = '(?i)\bimport\b[^;\n]*?["'']([^"'']+\.json)["'']'; what = 'importing {0}'; page = $false }
    )
    foreach ($call in $calls) {
        foreach ($m in [regex]::Matches($Text, $call.re)) {
            $u = $m.Groups[1].Value
            if (-not (& $isLocal $u)) { continue }
            if ($null -eq $pages) { $pages = @(Get-PagesLoading $ProjectRoot $Rel) }
            $base = if ($call.page -and $pages.Count) { (Split-Path -Parent $pages[0]).Replace('\', '/') } else { $fileDir }
            $data = Resolve-RelRef $ProjectRoot $base $u
            if (-not $data) { $data = $u }
            "${Rel}:$(& $line $m.Index): $($call.what -f $u) $blocked $(Get-DataScriptFix $ProjectRoot $data $pages $Rel)"
        }
    }
}
function Test-ProjectConsistency {
    <# Fixed checks on the given project files (no judgement of the code): JSON parses, PowerShell has
       no syntax errors, and local files referenced from HTML, JavaScript and CSS (href, src, fetch,
       import, url()) exist; in a project opened from disk, nothing the browser blocks on file://
       (Find-FileUrlBlocks). Returns one line per problem. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Paths, [switch]$SyntaxOnly)
    $fromDisk = -not $SyntaxOnly -and -not (Test-ServedProject $ProjectRoot)
    foreach ($rel in @($Paths)) {
        try { $full = Resolve-ProjectPath $ProjectRoot $rel } catch { continue }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf) -or (Test-BinaryFile $full)) { continue }
        $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
        $text = (Read-TextFile $full).Text
        if ($ext -eq '.json') {
            try { $null = $text | ConvertFrom-Json } catch { "${rel}: not valid JSON ($($_.Exception.Message.Split("`n")[0]))" }
        }
        if ($ext -in '.py', '.pyw') {
            $mixed = [regex]::Match($text, '(?m)^( +\t|\t+ )[ \t]*\S')
            if ($mixed.Success) { "${rel}:$(([regex]::Matches($text.Substring(0, $mixed.Index), "`n")).Count + 1): indentation mixes tabs and spaces (Python stops with a TabError)" }
            elseif ([regex]::IsMatch($text, '(?m)^\t+\S') -and [regex]::IsMatch($text, '(?m)^ +\S')) { "${rel}: some lines are indented with tabs and others with spaces (Python may stop with a TabError)" }
        }
        if ($ext -eq '.psd1') {
            try { $null = Import-PowerShellDataFile -LiteralPath $full -ErrorAction Stop }
            catch { "${rel}: not a valid data file ($(("$($_.Exception.Message)" -replace '\s+', ' ').Trim()))" }
        }
        if ($ext -in '.ps1', '.psm1', '.psd1') {
            $tok = $null; $errs = $null
            $null = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tok, [ref]$errs)
            foreach ($x in @($errs) | Select-Object -First 3) { "${rel}:$($x.Extent.StartLineNumber): $($x.Message)" }
        }
        if ($fromDisk) { Find-FileUrlBlocks $rel $text $ProjectRoot }
        if (-not $SyntaxOnly -and $ext -in '.html', '.htm', '.js', '.mjs', '.cjs', '.jsx', '.ts', '.mts', '.tsx', '.css', '.scss', '.vue', '.svelte') {
            $refs = New-Object System.Collections.Generic.List[object]
            $patterns = @(
                @{ kind = 'ref'; re = '(?i)\b(?:href|src)\s*=\s*["'']([^"''#?]+)' },
                @{ kind = 'fetch'; re = '(?i)\bfetch\(\s*["''`]([^"''`?#]+)' },
                @{ kind = 'import'; re = '(?i)\bimport\s[^;]*?from\s*["'']([^"''?#]+)' },
                @{ kind = 'import'; re = '(?im)^\s*import\s*["'']([^"''?#]+)' },
                @{ kind = 'import'; re = '(?i)\bimport\(\s*["'']([^"''?#]+)["'']\s*\)' },
                @{ kind = 'import'; re = '(?i)\bexport\s[^;]*?from\s*["'']([^"''?#]+)' },
                @{ kind = 'import'; re = '(?i)\brequire\(\s*["'']([^"''?#]+)["'']\s*\)' },
                @{ kind = 'ref'; re = '(?i)\burl\(\s*["'']?([^"'')?#]+)' }
            )
            foreach ($p in $patterns) {
                foreach ($m in [regex]::Matches($text, $p.re)) { $refs.Add(@{ kind = $p.kind; ref = $m.Groups[1].Value.Trim() }) }
            }
            $seen = @{}
            foreach ($r in $refs) {
                $ref = $r.ref
                if ($seen.ContainsKey($ref)) { continue }; $seen[$ref] = $true
                if (-not $ref -or $ref -match '^(?i)([a-z][a-z0-9+.-]*:|//|#|\$|\{)' -or $ref.Contains('${')) { continue }
                # Imports without ./ or / are packages or path aliases (react, @/lib/api): not files here.
                if ($r.kind -eq 'import' -and $ref -notmatch '^\.{1,2}/|^/') { continue }
                $target = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $full) ($ref.TrimStart('/').Replace('/', '\'))))
                if ($ref.StartsWith('/')) { $target = [IO.Path]::GetFullPath((Join-Path $ProjectRoot ($ref.TrimStart('/').Replace('/', '\')))) }
                if (-not $target.StartsWith([IO.Path]::GetFullPath($ProjectRoot), [StringComparison]::OrdinalIgnoreCase)) { continue }
                if (Test-Path -LiteralPath $target -PathType Leaf) { continue }
                if ($r.kind -eq 'import' -and (Resolve-ModuleImport $target)) { continue }
                if ($r.kind -ne 'import' -and (Test-Path -LiteralPath $target)) { continue }
                if ($r.kind -eq 'fetch' -and $ext -notin '.html', '.htm') {
                    # fetch() resolves against the page that runs the script, not the script file.
                    $onPage = @(Get-PagesLoading $ProjectRoot $rel | Where-Object {
                        $hit = Resolve-RelRef $ProjectRoot (Split-Path -Parent $_).Replace('\', '/') $ref
                        $hit -and (Test-Path -LiteralPath (Join-Path $ProjectRoot $hit.Replace('/', '\')))
                    })
                    if ($onPage.Count) { continue }
                }
                "${rel}: refers to $ref, which does not exist"
            }
        }
    }
}

function Get-LastChangeSetId {
    <# The id of the newest change set (checkpoint with a manifest) of a project, or '' when there
       is none. Line counts "per change" start there. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $base = Join-Path (Get-ProjectStateDir $ProjectRoot) 'backups'
    if (-not (Test-Path -LiteralPath $base)) { return '' }
    $last = @(Get-ChildItem -LiteralPath $base -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json') } | Sort-Object Name -Descending) | Select-Object -First 1
    if ($last) { $last.Name } else { '' }
}

function Get-SessionChangeStats {
    <# Per changed file: lines added/removed since $SinceId (a checkpoint id, yyyyMMdd-HHmmss-fff),
       measured against the version before the first change in that period (from the undo backups).
       A file created in that period has created = $true, also when it has no lines to count
       (empty, binary or very large). #>
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
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $created = -not $baseline[$rel]
            if ((Get-Item -LiteralPath $full).Length -gt 2MB -or (Test-BinaryFile $full)) {
                if ($created) { $result[$rel] = @{ added = 0; removed = 0; created = $true } }
                continue
            }
            $old = if ($baseline[$rel]) { (Read-TextFile $baseline[$rel]).Text } else { '' }
            $stats = Measure-LineChanges $old (Read-TextFile $full).Text
            $stats.created = $created
            if ($stats.added -or $stats.removed -or $created) { $result[$rel] = $stats }
        } catch { }
    }
    $result
}

# --- Actions -------------------------------------------------------------------------

function Get-FileOutline {
    <# The structure of a file with line numbers, so Copilot can read just the part it needs:
       HTML (head/body, style and script blocks, elements with an id, headings), JavaScript /
       TypeScript (functions, classes, arrow functions), CSS (@media blocks, section comments,
       selectors), PowerShell (functions), Markdown (headings), Python (classes, functions and
       methods, the main block). At most $Max entries. #>
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
            '^\.pyw?$' {
                if ($l -match '^([ \t]*)(async\s+)?def\s+(\w+)') { $out.Add("$n  $($Matches[1].Replace("`t", '    '))def $($Matches[3])") }
                elseif ($l -match '^([ \t]*)class\s+(\w+)') { $out.Add("$n  $($Matches[1].Replace("`t", '    '))class $($Matches[2])") }
                elseif ($l -match '^if\s+__name__\s*==') { $out.Add("$n  if __name__ == ""__main__""") }
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
            $raw = (Read-TextFile $full).Text.Replace("`r`n", "`n")
            $lines = $raw.Split("`n")
            $total = $lines.Length
            $from = [Math]::Min($r.From, [Math]::Max(1, $total)); $to = [Math]::Min($r.To, $total)
            # A range that cuts through a block is widened to the whole block, so Copilot sees the
            # code it would change from its first to its last line.
            $widened = ''
            if ($from -gt 1 -or $to -lt $total) {
                $w = Expand-ToWholeBlocks $raw $full $from $to
                if ($w.from -ne $from -or $w.to -ne $to) { $widened = " - lines $from-$to asked; widened to $($w.from)-$($w.to) so every block in it is complete"; $from = $w.from; $to = $w.to }
            }
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
            $head = if ($whole) { "### $p" } else { "### $p (lines $from-$last of $total$widened)" }
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
    $rel = (ConvertTo-RelativePath $ProjectRoot $full)
    if ($rel -match '(?i)^\.streamhub(/|$)') {
        throw "$Path is in .streamhub/, which holds the helper program's own records (issues, schedules). Do not write there; put your file elsewhere in the project."
    }
    $generated = Test-GeneratedPath $rel $ProjectRoot
    if ($generated) { throw "not written: $generated." }
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
    $Content = Repair-CodeText $full $Content
    if (Test-Path -LiteralPath $full -PathType Leaf) { $info = Read-TextFile $full; $bom = $info.Bom; $crlf = $info.Crlf; $encName = $info.Encoding }
    else { $fmt = Get-NewFileFormat $full $Content $ProjectRoot; $bom = $fmt.Bom; $crlf = $fmt.Crlf; $encName = $fmt.Encoding }
    if ($Checkpoint) { Save-CheckpointFile $Checkpoint $ProjectRoot $full }
    if (-not $Content.EndsWith("`n")) { $Content += "`n" }
    Write-TextFile $full $Content $bom $crlf $encName
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

# Braces are only counted in languages that use them for blocks; in HTML only inside <script> and
# <style>. Strings, template strings and comments are blanked first (line breaks kept, so line
# numbers stay right).
$script:BraceCode = '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|svelte|cs|java|kt|kts|c|cc|cpp|h|hpp|go|rs|php|swift|dart|scala)$'
$script:BraceStyle = '(?i)\.(css|scss|less)$'
$script:BracePs = '(?i)\.(ps1|psm1|psd1)$'
$script:BraceMarkup = '(?i)\.(html?|xhtml|vue|svelte|php)$'

function Hide-Matches([string]$Text, [string]$Pattern) {
    # Each match becomes spaces, keeping its line breaks.
    [regex]::Replace($Text, $Pattern, [Text.RegularExpressions.MatchEvaluator] { param($m) [regex]::Replace($m.Value, '[^\n]', ' ') })
}

function Get-BraceText([string]$Text, [string]$Path) {
    <# The part of a file whose braces are block braces: strings, template strings and comments
       blanked; for HTML only the <script> and <style> contents; empty for files without braces. #>
    $t = $Text.Replace("`r`n", "`n")
    $isMarkup = $Path -match '(?i)\.(html?|xhtml)$'
    if ($isMarkup) {
        # Keep only what is inside <script>...</script> and <style>...</style>.
        $sb = New-Object Text.StringBuilder ([regex]::Replace($t, '[^\n]', ' '))
        foreach ($m in [regex]::Matches($t, '(?is)(<(script|style)\b[^>]*>)(.*?)(</\2\s*>)')) {
            $g = $m.Groups[3]
            for ($i = 0; $i -lt $g.Length; $i++) { $sb[$g.Index + $i] = $t[$g.Index + $i] }
        }
        $t = $sb.ToString()
    }
    if ($isMarkup -or $Path -match $script:BraceCode) {
        return Hide-Matches $t '/\*[\s\S]*?\*/|<!--[\s\S]*?-->|`(?:[^`\\]|\\[\s\S])*`|"(?:[^"\\\n]|\\.)*"|''(?:[^''\\\n]|\\.)*''|(?<![:\\])//[^\n]*'
    }
    if ($Path -match $script:BraceStyle) {
        $p = '/\*[\s\S]*?\*/|"(?:[^"\\\n]|\\.)*"|''(?:[^''\\\n]|\\.)*'''
        if ($Path -notmatch '(?i)\.css$') { $p += '|(?<![:\\])//[^\n]*' }   # scss and less also have // comments
        return Hide-Matches $t $p
    }
    if ($Path -match $script:BracePs) { return Hide-Matches $t '<#[\s\S]*?#>|"(?:[^"`\n]|`.)*"|''(?:[^''\n]|'''')*''|#[^\n]*' }
    if ($Path -match '(?i)\.json$') { return Hide-Matches $t '"(?:[^"\\\n]|\\.)*"' }
    ''
}

function Get-BlockBalance([string]$Text, [string]$Path = 'file.js') {
    <# Net open minus close counts of block braces and (in markup) of style/script tags. #>
    $b = Get-BraceText $Text $Path
    $markup = $Path -match $script:BraceMarkup
    @{
        braces = ([regex]::Matches($b, '\{')).Count - ([regex]::Matches($b, '\}')).Count
        style  = $(if ($markup) { ([regex]::Matches($Text, '(?i)<style\b')).Count - ([regex]::Matches($Text, '(?i)</style>')).Count } else { 0 })
        script = $(if ($markup) { ([regex]::Matches($Text, '(?i)<script\b')).Count - ([regex]::Matches($Text, '(?i)</script>')).Count } else { 0 })
    }
}

function Find-UnbalancedBrace([string]$Text, [string]$Path) {
    <# Where the braces stop matching: the first } without an opening {, or else the last { that is
       never closed. Returns @{ line; text; kind } or $null. #>
    $b = Get-BraceText $Text $Path
    $lines = $Text.Replace("`r`n", "`n").Split("`n")
    $stack = New-Object System.Collections.Generic.Stack[int]
    $line = 1
    foreach ($ch in $b.ToCharArray()) {
        if ($ch -eq "`n") { $line++; continue }
        if ($ch -eq '{') { $stack.Push($line) }
        elseif ($ch -eq '}') {
            if (-not $stack.Count) { return @{ line = $line; text = $lines[$line - 1].Trim(); kind = 'a } that closes nothing' } }
            [void]$stack.Pop()
        }
    }
    if ($stack.Count) { $l = $stack.Peek(); return @{ line = $l; text = $lines[$l - 1].Trim(); kind = 'a { that is never closed' } }
    $null
}

function Get-BlockSpans([string]$Text, [string]$Path) {
    <# Every block as a line span @{ from; to }: { } blocks (by Get-BraceText) and, in markup,
       <style> and <script> blocks. Unmatched braces make no span. #>
    $spans = New-Object System.Collections.Generic.List[object]
    $b = Get-BraceText $Text $Path
    $stack = New-Object System.Collections.Generic.Stack[int]
    $line = 1
    foreach ($ch in $b.ToCharArray()) {
        if ($ch -eq "`n") { $line++; continue }
        if ($ch -eq '{') { $stack.Push($line) }
        elseif ($ch -eq '}' -and $stack.Count) { $o = $stack.Pop(); if ($o -ne $line) { $spans.Add(@{ from = $o; to = $line }) } }
    }
    if ($Path -match $script:BraceMarkup) {
        $t = $Text.Replace("`r`n", "`n")
        foreach ($m in [regex]::Matches($t, '(?is)<(script|style)\b[^>]*>.*?</\1\s*>')) {
            $f = ([regex]::Matches($t.Substring(0, $m.Index), "`n")).Count + 1
            $l = $f + ([regex]::Matches($m.Value, "`n")).Count
            if ($l -gt $f) { $spans.Add(@{ from = $f; to = $l }) }
        }
    }
    $spans.ToArray()
}

function Expand-ToWholeBlocks {
    <# Widens a line range so it does not cut through a block: a block that starts inside the range
       is shown to its end, a block that ends inside it from its start. A range that lies wholly
       inside one block stays as it is. At most $MaxExtra lines are added. Returns @{ from; to }. #>
    param([string]$Text, [string]$Path, [int]$From, [int]$To, [int]$MaxExtra = 600)
    $spans = @(Get-BlockSpans $Text $Path)
    $f = $From; $t = $To
    for ($pass = 0; $pass -lt 20; $pass++) {
        $changed = $false
        foreach ($s in $spans) {
            if ($s.from -lt $f -and $s.to -ge $f -and $s.to -le $t -and ($From - $s.from) + ($t - $To) -le $MaxExtra) { $f = $s.from; $changed = $true }
            if ($s.from -ge $f -and $s.from -le $t -and $s.to -gt $t -and ($From - $f) + ($s.to - $To) -le $MaxExtra) { $t = $s.to; $changed = $true }
        }
        if (-not $changed) { break }
    }
    @{ from = $f; to = $t }
}

# Lines that stand for code left out ("// ... rest of the code unchanged", "<!-- existing content -->",
# a line with only ...). In a write or a REPLACE they would replace real code with a comment.
$script:CommentStart = '^(//+|#+|/\*+|\*|<!--|--|;|\{/\*|rem\s|::)\s*'
$script:Ellipsis = '(\.{3,}|' + [char]0x2026 + ')'
$script:OmitPhrase = '(?i)\b(rest of (the )?(code|file|content|component|page|styles?|functions?|class|script|markup|html|css|logic)|(existing|previous|original|other|remaining) (code|content|functions?|methods?|styles?|rules|logic|markup|html|css|lines|imports|elements|implementation)\b.*\b(unchanged|here|as before|as is|remains?|stays?|omitted|not shown|same|goes here)|unchanged code|omitted for brevity|for brevity|truncated for|no changes (below|above|here)|same as before|keep (the )?(existing|rest)|code unchanged)\b'

function Find-PlaceholderLine([string]$Old, [string]$New) {
    <# The first new line that stands for left-out code (not already in the file), or $null.
       Returns @{ line; text }. #>
    $had = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($l in "$Old".Replace("`r`n", "`n").Split("`n")) { [void]$had.Add($l.Trim()) }
    $lines = "$New".Replace("`r`n", "`n").Split("`n")
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $t = $lines[$i].Trim()
        if (-not $t -or $had.Contains($t)) { continue }
        $bare = ($t -replace "(?i)$($script:CommentStart)", '') -replace '\s*(\*/|-->|\*/\})\s*$', ''
        $isComment = $t -match "(?i)$($script:CommentStart)"
        $hit = ($bare -match "^$($script:Ellipsis)$") -or
               ($isComment -and $bare -match $script:Ellipsis -and $bare -match '(?i)\b(existing|rest|remaining|unchanged|other|previous|same|omitted|code|content|here)\b') -or
               ($isComment -and $bare -match $script:OmitPhrase)
        if ($hit) { return @{ line = $i + 1; text = $t } }
    }
    $null
}

function Get-ChangedView {
    <# After an edit: the changed lines as they are now, widened to whole blocks, so Copilot's next
       edit starts from the current text. At most $MaxLines lines. Returns the text or ''. #>
    param([string]$Old, [string]$New, [string]$Path, [string]$Shown, [int]$MaxLines = 80)
    $o = "$Old".Replace("`r`n", "`n").Split("`n"); $n = "$New".Replace("`r`n", "`n").Split("`n")
    $top = 0
    while ($top -lt $o.Length -and $top -lt $n.Length -and $o[$top] -ceq $n[$top]) { $top++ }
    if ($top -ge $n.Length -and $top -ge $o.Length) { return '' }
    $bo = $o.Length - 1; $bn = $n.Length - 1
    while ($bo -ge $top -and $bn -ge $top -and $o[$bo] -ceq $n[$bn]) { $bo--; $bn-- }
    if ($bn -lt $top) { $bn = [Math]::Min($top, $n.Length - 1) }   # only lines removed: show where
    $w = Expand-ToWholeBlocks ($n -join "`n") $Path ($top + 1) ($bn + 1) 60
    $from = [Math]::Max(1, $w.from - 1); $to = [Math]::Min($n.Length, $w.to + 1)   # one line of context
    if ($to - $from + 1 -gt $MaxLines) { $to = $from + $MaxLines - 1; $cut = " (first $MaxLines lines; read more if you need them)" } else { $cut = '' }
    $fence = '````'
    "Lines $from-$to of $Shown now$cut (line numbers are not part of the file):`n$fence`n" + ($n[($from - 1)..($to - 1)] -join "`n") + "`n$fence"
}

function Find-SymbolDefinition {
    <# Where a function, class, method, CSS class/id or HTML id is defined in the project:
       "PATH:LINE  line" plus the block's lines to read. At most $Max hits. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Name, [int]$Max = 20)
    $n = $Name.Trim().TrimStart('.', '#').Trim('`', '"', "'")
    if ($n -notmatch '^[\w$-]{2,80}$') { return "find: give one name (letters, digits, _ - $), for example a function or class name" }
    $e = [regex]::Escape($n)
    $byExt = @(
        @{ ext = '(?i)\.(js|mjs|cjs|jsx|ts|mts|cts|tsx|vue|svelte)$'; re = "(?i)\bfunction\s*\*?\s*$e\b|\bclass\s+$e\b|\b(const|let|var)\s+$e\s*=|^\s*(export\s+)?(default\s+)?(interface|type|enum)\s+$e\b|^\s*(public\s+|private\s+|protected\s+|static\s+|async\s+)*$e\s*\([^)]*\)\s*\{|\b$e\s*:\s*(async\s*)?(function\b|\()" }
        @{ ext = '(?i)\.(ps1|psm1)$'; re = "(?i)^\s*(function|filter|class|enum)\s+$e\b" }
        @{ ext = '(?i)\.pyw?$'; re = "^\s*(async\s+)?def\s+$e\b|^\s*class\s+$e\b|^$e\s*=" }
        @{ ext = '(?i)\.(css|scss|less)$'; re = "[.#]$e\b[^{};]*\{|[.#]$e\b[^{};]*,\s*$" }
        @{ ext = '(?i)\.(html?|xhtml)$'; re = "(?i)\bid\s*=\s*[""']$e[""']|\bclass\s*=\s*[""'][^""']*\b$e\b" }
        @{ ext = '(?i)\.(cs|java|kt|go|rs|php|swift|dart|c|cpp|h|hpp)$'; re = "\b(class|interface|enum|struct|record|trait|fn|func|def)\s+$e\b|\b\w[\w<>\[\],]*\s+$e\s*\([^;]*\)\s*(\{|$)" }
    )
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ProjectFiles $ProjectRoot)) {
        if ($hits.Count -ge $Max) { break }
        $rule = $byExt | Where-Object { $f.path -match $_.ext } | Select-Object -First 1
        if (-not $rule -or [int64]$f.size -gt 1MB -or $f.path -match '(?i)^(source|node_modules|dist|build)/') { continue }
        $full = Resolve-ProjectPath $ProjectRoot $f.path
        $text = (Read-TextFile $full).Text.Replace("`r`n", "`n")
        $lines = $text.Split("`n")
        for ($i = 0; $i -lt $lines.Length -and $hits.Count -lt $Max; $i++) {
            if ($lines[$i] -notmatch $rule.re) { continue }
            $w = Expand-ToWholeBlocks $text $full ($i + 1) ($i + 1) 400
            $read = if ($w.to -gt $w.from) { "  (block: read $($f.path):$($w.from)-$($w.to))" } else { '' }
            $t = $lines[$i].Trim(); if ($t.Length -gt 140) { $t = $t.Substring(0, 137) + '...' }
            $hits.Add("$($f.path):$($i + 1)  $t$read")
        }
    }
    if (-not $hits.Count) { return "find ${n}: no definition found (try grep for uses)" }
    "find ${n}:`n" + ($hits -join "`n")
}

function Get-LearnedNotes {
    <# AGENTS.md with new lines added to its "## Learned" section (made when missing): each line
       of $Body becomes "- LINE (DATE)". Returns the new text. #>
    param([AllowEmptyString()][string]$Old, [string]$Body, [string]$Date = (Get-Date).ToString('yyyy-MM-dd'))
    $items = @("$Body".Replace("`r`n", "`n").Split("`n") | ForEach-Object { ($_ -replace '^\s*[-*]\s*', '').Trim() } | Where-Object { $_ } | ForEach-Object { "- $_ ($Date)" })
    if (-not $items.Count) { return $Old }
    $t = "$Old".Replace("`r`n", "`n").TrimEnd("`n")
    if (-not $t.Trim()) { return "# Project notes`n`n## Learned`n" + ($items -join "`n") + "`n" }
    $m = [regex]::Match($t, '(?m)^## Learned\s*$')
    if (-not $m.Success) { return "$t`n`n## Learned`n" + ($items -join "`n") + "`n" }
    $next = [regex]::Match($t.Substring($m.Index + $m.Length), '(?m)^## ')
    $end = if ($next.Success) { $m.Index + $m.Length + $next.Index } else { $t.Length }
    $before = $t.Substring(0, $end).TrimEnd("`n"); $after = $t.Substring($end)
    "$before`n" + ($items -join "`n") + "`n" + $(if ($after) { "`n$after`n" } else { '' })
}

function Test-HalfBlock([string]$Old, [string]$New, [string]$Path = 'file.js') {
    <# Whether an edit leaves the file more unbalanced than it was: more unclosed (or unopened)
       { } blocks or <style>/<script> blocks after the edit than before. A file that is already
       broken may be repaired, or edited without making it worse. Returns the reason (with the line
       where the braces stop matching), or $null. #>
    $o = Get-BlockBalance $Old $Path; $n = Get-BlockBalance $New $Path
    foreach ($k in 'style', 'script') {
        if ([Math]::Abs($n[$k]) -gt [Math]::Abs($o[$k])) { return "this edit would leave a <$k> block half open or half closed in the file, so part of that block would be left behind. Include the whole block through its closing </$k> line (you may shorten its middle with a line containing only ...)" }
    }
    if ([Math]::Abs($n.braces) -gt [Math]::Abs($o.braces)) {
        $where = Find-UnbalancedBrace $New $Path
        $at = if ($where) { " After the edit there is $($where.kind) at line $($where.line): $(if ($where.text.Length -gt 120) { $where.text.Substring(0, 117) + '...' } else { $where.text })." } else { '' }
        return "this edit would leave a { } block half open or half closed in the file, so part of that block would be left behind.$at Include the whole block through its closing brace (you may shorten its middle with a line containing only ...)"
    }
    $null
}

function Get-IndentWidth([string]$Ws) {
    <# Columns of leading whitespace (a tab moves to the next multiple of 4). #>
    $w = 0
    foreach ($ch in $Ws.ToCharArray()) { if ($ch -eq "`t") { $w += 4 - ($w % 4) } else { $w++ } }
    $w
}

function Set-EditIndent {
    <# After a SEARCH matched only when indentation is ignored: shift the REPLACE lines by as much as
       the file differs from the SEARCH text, written in the file's indent style (tabs or spaces).
       In Python indentation is part of the code, so a match whose lines are shifted unevenly, or a
       new line that would end up left of column 0, is refused. Returns @{ text } or @{ error }. #>
    param([string]$Search, [string]$Matched, [string]$Replace, [string]$Path)
    $s = $Search.Split("`n"); $m = $Matched.Split("`n")
    $delta = $null; $uneven = $false
    for ($i = 0; $i -lt [Math]::Min($s.Length, $m.Length); $i++) {
        if (-not $s[$i].Trim()) { continue }
        $d = (Get-IndentWidth ([regex]::Match($m[$i], '^[ \t]*').Value)) - (Get-IndentWidth ([regex]::Match($s[$i], '^[ \t]*').Value))
        if ($null -eq $delta) { $delta = $d } elseif ($d -ne $delta) { $uneven = $true }
    }
    if ($null -eq $delta) { $delta = 0 }
    $isPy = $Path -match '(?i)\.pyw?$'
    if ($uneven -and $isPy) { return @{ error = 'SEARCH text matches only when indentation is ignored, and its lines are indented differently from the file by different amounts. In Python indentation is part of the code: copy the current lines exactly, with their indentation' } }
    $useTabs = ($Matched -match '(?m)^\t') -and ($Matched -notmatch '(?m)^ +\S')
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Replace.Split("`n")) {
        if (-not $l.Trim()) { $out.Add($l); continue }
        $ws = [regex]::Match($l, '^[ \t]*').Value
        $w = (Get-IndentWidth $ws) + $delta
        if ($w -lt 0) {
            if ($isPy) { return @{ error = 'the new lines are indented less than the place SEARCH matched (indentation was ignored to find it). In Python indentation is part of the code: copy the current lines exactly, with their indentation' } }
            $w = 0
        }
        $ind = if ($useTabs) { ("`t" * [Math]::Floor($w / 4)) + (' ' * ($w % 4)) } else { ' ' * $w }
        $out.Add($ind + $l.Substring($ws.Length))
    }
    @{ text = ($out -join "`n") }
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
        if ($hit.error) { return [pscustomobject]@{ ok = $false; error = "pair $n`: $($hit.error). Nothing was changed. Read the file again and send a corrected edit block." } }

        if ($hit.note -eq 'matched ignoring indentation') {
            $fix = Set-EditIndent $search $text.Substring($hit.start, $hit.length) $replace $full
            if ($fix.error) { return [pscustomobject]@{ ok = $false; error = "pair $n`: $($fix.error). Nothing was changed. Read the file again and send a corrected edit block." } }
            $replace = $fix.text
            $hit.note = 'matched ignoring indentation; the new lines were re-indented to match the file'
        }
        if ($hit.note) { $notes.Add("pair ${n}: $($hit.note)") }
        $text = $text.Substring(0, $hit.start) + $replace + $text.Substring($hit.start + $hit.length)
        $after = $hit.start + $replace.Length
    }
    $half = Test-HalfBlock $info.Text $text $full
    if ($half) {
        # Show Copilot the whole block(s) its SEARCH cut into, as they are now, so its next edit can
        # cover them from start to end without another read.
        $shown = New-Object System.Collections.Generic.List[string]
        $orig = $info.Text.Replace("`r`n", "`n")
        $olines = $orig.Split("`n")
        $fence = '````'
        foreach ($e in $Edits) {
            $hit = Find-EditTarget $orig ($e.search.Replace("`r`n", "`n"))
            if ($hit.error -or $null -eq $hit.start) { continue }
            $a = Get-LineNumber $orig $hit.start
            $z = Get-LineNumber $orig ([Math]::Max($hit.start, $hit.start + $hit.length - 1))
            $w = Expand-ToWholeBlocks $orig $full $a $z 300
            if ($w.from -eq $a -and $w.to -eq $z) { continue }
            $body = ($olines[($w.from - 1)..($w.to - 1)] -join "`n")
            $shown.Add("Current lines $($w.from)-$($w.to) of $(ConvertTo-RelativePath $ProjectRoot $full) (the whole block your SEARCH starts or ends in; line numbers are not part of the file):`n$fence`n$body`n$fence")
            if ($shown.Count -ge 2) { break }
        }
        $more = if ($shown.Count) { "`n" + ($shown -join "`n") } else { '' }
        return [pscustomobject]@{ ok = $false; error = "$half. Nothing was changed. Send a corrected edit whose SEARCH covers the whole block from its first to its last line (the current lines are below), or replace the whole file with a write block.$more" }
    }
    $moveProblem = Test-MoveOrder $ProjectRoot $full $info.Text $text
    if ($moveProblem) { return [pscustomobject]@{ ok = $false; error = $moveProblem } }
    [pscustomobject]@{ ok = $true; full = $full; old = $info.Text; new = $text; bom = $info.Bom; crlf = $info.Crlf; encoding = $info.Encoding; pairs = $n; notes = @($notes)
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
    Write-TextFile $r.full $r.new $r.bom $r.crlf $r.encoding
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

# Commands that delete or move files (cmd, PowerShell and their aliases, Unix-style tools).
$script:DeleteVerbs = '(?i)^(del|erase|rd|rmdir|rm|ri|move|mv|mi|Remove-Item|Move-Item|Clear-Content|clc|Clear-Item|cli|Remove-ItemProperty|rp|Clear-RecycleBin|unlink|shred)$'
# Deleting from code: Python, Node, .NET, PowerShell methods.
$script:CodeDeletePattern = '(?i)shutil\.(rmtree|move)|os\.(remove|unlink|rmdir|removedirs|rename|replace)\b|\.unlink\(|\.rmdir\(|\bfs(Promises)?\.(rm|rmSync|unlink|unlinkSync|rmdir|rmdirSync|rename|renameSync)\b|rimraf|\[(System\.)?IO\.(File|Directory|FileInfo|DirectoryInfo)\]::(Delete|Move)|\.(Delete|MoveTo)\(|Remove-Item|Move-Item'
$script:FolderChange = '(?i)^(cd|chdir|pushd|popd|Set-Location|sl|Push-Location|Pop-Location)$|^cd\.\.|^cd\\'
$script:CmdSwitch = '(?i)^/(s|q|f|p|y|-y|e|a(:\S*)?|mir|purge|mov|move|xd|xf|xo|xx|xc|xn|xl|nfl|ndl|njh|njs|np|nc|ns|ts|fp|r:\d+|w:\d+|mt(:\d+)?|z|b|l|copy:\S+|dcopy:\S+|xj|xjd|xjf|sl|v|create|is|it)$'
$script:ScriptExt = '(?i)\.(ps1|psm1|cmd|bat|py|pyw|js|mjs|cjs)$'

function Split-CommandGroups([string]$Command) {
    <# Command text as groups of tokens, quotes respected: a group ends at & && || ; or a new line;
       a pipe stays inside the group as the token |. Quotes are kept on the tokens. #>
    $groups = New-Object System.Collections.Generic.List[object]
    $cur = New-Object System.Collections.Generic.List[string]
    $tok = New-Object Text.StringBuilder
    $quote = [char]0
    $flushTok = { if ($tok.Length) { $cur.Add($tok.ToString()); [void]$tok.Clear() } }
    $flushGroup = { & $flushTok; if ($cur.Count) { $groups.Add($cur.ToArray()); $cur.Clear() } }
    foreach ($ch in $Command.ToCharArray()) {
        if ($quote) { [void]$tok.Append($ch); if ($ch -eq $quote) { $quote = [char]0 }; continue }
        if ($ch -eq '"' -or $ch -eq "'") { $quote = $ch; [void]$tok.Append($ch); continue }
        if ($ch -eq "`n" -or $ch -eq "`r" -or $ch -eq ';' -or $ch -eq '&') { & $flushGroup; continue }
        if ($ch -eq '|') { & $flushTok; if ($cur.Count -and $cur[$cur.Count - 1] -eq '|') { $cur.RemoveAt($cur.Count - 1); & $flushGroup } else { $cur.Add('|') }; continue }
        if ($ch -eq ' ' -or $ch -eq "`t") { & $flushTok; continue }
        [void]$tok.Append($ch)
    }
    & $flushGroup
    $groups.ToArray()
}

function Test-ScopedPath([string]$ProjectRoot, [string]$Token) {
    <# Why a path written in a deleting command is not safely inside the project, or $null. #>
    $t = $Token.Trim().Trim('"', "'").TrimEnd(';', ',', ')').TrimStart('(')
    if (-not $t -or $t -eq '|' -or $t -match '^\d?>|^<' -or $t -match '(?i)^nul$') { return $null }
    if ($t -match '[$%!`]' -or $t.StartsWith('~')) { return "'$t' uses a variable, so the target cannot be checked" }
    $root = $ProjectRoot.TrimEnd('\')
    $p = $t.Replace('/', '\') -replace '[*?]', 'x'
    $full = try { [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root $p })).TrimEnd('\') } catch { return "'$t' is not a path that can be checked" }
    if ($full -eq $root) { return "'$t' is the project folder itself" }
    if (-not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { return "'$t' is outside the project folder" }
    try { Assert-NoOutsideLink $root $full $t } catch { return "'$t' goes through a link to a folder outside the project" }
    $null
}

function Test-DeleteScope {
    <# Hard boundary for commands: files may only be deleted or moved inside the project folder.
       Returns why a command is refused, or $null. No approval overrides it. A command that deletes
       or moves must name its targets as plain paths inside the project (relative or absolute):
       no .., no variables, no changing folders first, no encoded commands. Deleting code inside
       python -c / node -e / -Command text, and in project scripts the command runs, is checked
       the same way (its quoted paths). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][AllowEmptyString()][string]$Command, [int]$Depth = 0)
    if ($Command -match '(?i)(^|\s)-(e|ec|enc|encodedcommand)\s+[A-Za-z0-9+/=]{16,}') { return 'it contains an encoded command, which cannot be checked' }
    $groups = @(Split-CommandGroups $Command)
    $all = @($groups | ForEach-Object { $_ })
    $deletes = $false
    foreach ($g in $groups) {
        $verbs = @($g | Where-Object { ($_ -replace '^@', '') -match $script:DeleteVerbs })
        $isGit = ($g -contains 'git') -and (@($g | Where-Object { $_ -in 'clean', 'rm', 'mv' }).Count -gt 0)
        $isRobo = ($g | Where-Object { $_ -match '(?i)^robocopy(\.exe)?$' }) -and ($g | Where-Object { $_ -match '(?i)^/(mir|purge|mov|move)$' })
        if (-not ($verbs.Count -or $isGit -or $isRobo)) { continue }
        $deletes = $true
        foreach ($t in $g) {
            if ($t -match '^-' -or $t -match $script:CmdSwitch) { continue }
            $why = Test-ScopedPath $ProjectRoot $t
            if ($why) { return "it deletes or moves files and $why" }
        }
    }
    # Code that deletes: every quoted path in it must be inside, and no paths from variables.
    if ($Command -match $script:CodeDeletePattern) {
        $deletes = $true
        if ($Command -match '(?i)os\.environ|getenv|expanduser|process\.env|homedir\(|\$env:|%\w+%|GetFolderPath|\[Environment\]::') { return 'it deletes or moves files using a path from the environment, which cannot be checked' }
        # Each quoted string on its own (double- and single-quoted separately); a string that wraps
        # code (contains the other quote or ;) is skipped, as its own strings are checked.
        $strings = @([regex]::Matches($Command, '"([^"\r\n]*)"') | ForEach-Object { $_.Groups[1].Value }) + @([regex]::Matches($Command, '''([^''\r\n]*)''') | ForEach-Object { $_.Groups[1].Value })
        foreach ($s in $strings) {
            if ($s -match '["'';]') { continue }
            if ($s -notmatch '[\\/]|^\.\.?$' -and -not [IO.Path]::IsPathRooted($s)) { continue }   # only path-like strings
            if ($s -match '^\w+://') { continue }
            $why = Test-ScopedPath $ProjectRoot $s
            if ($why) { return "it deletes or moves files and $why" }
        }
    }
    if ($deletes -and @($all | Where-Object { $_ -match $script:FolderChange -or $_ -match '(?i)^--(work-tree|git-dir)' }).Count) { return 'it changes folder before deleting or moving files, so the targets cannot be checked' }
    if ($deletes -and ($all -contains 'git') -and ($all -contains '-C')) { return 'it runs git in another folder while deleting or moving files' }
    # Project scripts the command runs: the same check on their contents (one level deep).
    if ($Depth -lt 1) {
        foreach ($t in $all) {
            $p = $t.Trim('"', "'")
            if ($p -notmatch $script:ScriptExt) { continue }
            $full = try { Resolve-ProjectPath $ProjectRoot $p } catch { $null }
            if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf) -or (Get-Item -LiteralPath $full).Length -gt 500000) { continue }
            $why = Test-DeleteScope $ProjectRoot ([IO.File]::ReadAllText($full)) ($Depth + 1)
            if ($why) { return "the script $p $why" -replace "the script $([regex]::Escape($p)) it ", "the script $p " }
        }
    }
    $null
}

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

Export-ModuleMember -Function Get-LastChangeSetId, Resolve-RelRef, Test-ServedProject, Find-FileUrlBlocks, Start-RunSnapshot, Complete-RunSnapshot, Clear-RunSnapshot, Test-BinaryFile, Repair-CodeText, Get-TextEncodingName, Get-NewFileFormat, Find-CodeArtifacts, Test-EncodingFit, Write-TextFile, Find-SymbolDefinition, Get-LearnedNotes, Find-PlaceholderLine, Get-ChangedView, Get-BlockSpans, Expand-ToWholeBlocks, Get-BraceText, Get-BlockBalance, Find-UnbalancedBrace, Test-HalfBlock, Test-DeleteScope, Split-CommandGroups, Get-FileOutline, Get-CheckpointChanges, Get-ChangeSetContents, Set-EditIndent, Resolve-ModuleImport, ConvertTo-CheckableScript, Test-ProjectConsistency, Format-AlreadyApplied, Get-SessionChangeStats, Get-CommandRisk, Assert-Writable, Read-TextFile, New-Checkpoint, Undo-LastCheckpoint, Invoke-ReadAction, Invoke-GlobAction, Invoke-GrepAction,
    Get-WritePreview, Invoke-WriteAction, Get-EditResult, Invoke-EditAction, Invoke-RunAction
