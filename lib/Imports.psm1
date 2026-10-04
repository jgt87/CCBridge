# The import index: which project file uses which, on which line. Per code file it keeps
#   refs  imports and loads of other project files (import/require/export-from, script src, link
#         href, CSS @import, Python import, PowerShell Import-Module / dot-source), with the line,
#         the text as written and the file it resolves to;
#   defs  hook points the file offers: element ids (HTML), functions (JS), custom hooks (useX);
#   uses  hook points it uses: ids from getElementById / querySelector('#x') / $('#x'), functions
#         called from inline handlers (onclick="fn()"), custom hooks called.
# Kept in <project>\.streamhub\imports.json and updated incrementally: every file whose size or
# time changed at the start of a task, and the files a round changed after every round, so line
# numbers follow the edits. Used to tell Copilot who uses a file it reads (Get-ImportUsers) and to
# report links a round broke (Update-ImportsAfterRound): an import of a file that was deleted or
# moved, an id, function or hook that was removed while other files still use it.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Workspace', 'Executor') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:CodeExt = '(?i)\.(html?|m?js|cjs|jsx|ts|mts|cts|tsx|vue|svelte|css|scss|less|py|ps1|psm1)$'
$script:Skip = '(?i)(^|/)(source|\.streamhub|node_modules|dist|build|out|bin|obj|coverage|vendor|History|Logs|Runbooks/Exports)/|\.min\.(js|css)$'
$script:JsExts = '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.mts', '.cts', '.vue', '.svelte', '.json', '.css', '.scss'

function Get-ImportIndexPath([string]$ProjectRoot) { Join-Path $ProjectRoot '.streamhub\imports.json' }

function New-LineFinder([string]$Text) {
    # Offsets of the newlines, so a match index becomes a line number with a binary search.
    $nl = New-Object System.Collections.Generic.List[int]
    for ($i = $Text.IndexOf("`n"); $i -ge 0; $i = $Text.IndexOf("`n", $i + 1)) { $nl.Add($i) }
    , $nl.ToArray()
}
function Get-LineAt([int[]]$Newlines, [int]$Index) {
    $k = [Array]::BinarySearch($Newlines, $Index)
    if ($k -lt 0) { $k = -bnot $k }
    $k + 1
}

function Test-ProjectFile([string]$ProjectRoot, [string]$Rel) {
    $Rel -and (Test-Path -LiteralPath (Join-Path $ProjectRoot $Rel.Replace('/', '\')) -PathType Leaf)
}

function Resolve-ImportTarget([string]$ProjectRoot, [string]$Want, [switch]$Js) {
    # The project file an import resolves to: as written, or (JS) with an extension, an index file,
    # or a .js name that is a .ts source. $null when none exists.
    if (-not $Want) { return $null }
    if (Test-ProjectFile $ProjectRoot $Want) { return $Want }
    if (-not $Js) { return $null }
    foreach ($e in $script:JsExts) { if (Test-ProjectFile $ProjectRoot "$Want$e") { return "$Want$e" } }
    foreach ($e in $script:JsExts) { if (Test-ProjectFile $ProjectRoot "$Want/index$e") { return "$Want/index$e" } }
    if ($Want -match '(?i)\.(m|c)?jsx?$') {
        $stem = $Want -replace '(?i)\.(m|c)?jsx?$', ''
        foreach ($e in '.ts', '.tsx', '.mts', '.cts') { if (Test-ProjectFile $ProjectRoot "$stem$e") { return "$stem$e" } }
    }
    $null
}

function Get-FileLinks {
    <# The refs, defs and uses of one file (see the top of this file). Fixed patterns, no parsing. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Text)
    $ext = [IO.Path]::GetExtension($Rel).ToLowerInvariant()
    $nl = New-LineFinder $Text
    $dir = (Split-Path -Parent $Rel).Replace('\', '/')
    $refs = New-Object System.Collections.Generic.List[object]
    $defs = New-Object System.Collections.Generic.List[object]
    $uses = New-Object System.Collections.Generic.List[object]
    $seenRef = @{}
    $addRef = {
        param([int]$At, [string]$Ref, [string]$Want, [string]$Target)
        $line = Get-LineAt $nl $At
        if ($seenRef.ContainsKey("$line|$Ref")) { return }; $seenRef["$line|$Ref"] = $true
        $refs.Add([pscustomobject]@{ line = $line; ref = $Ref; want = $Want; target = $Target })
    }
    $isWeb = $ext -match '^\.(html?|m?js|cjs|jsx|ts|mts|cts|tsx|vue|svelte)$'
    if ($isWeb) {
        $pats = @()
        if ($ext -in '.html', '.htm') {
            $pats += '(?i)<script\b[^>]*?\bsrc\s*=\s*["'']([^"''?#]+)'
            $pats += '(?i)<link\b[^>]*?\bhref\s*=\s*["'']([^"''?#]+\.(?:css|js|mjs|json))'
        }
        $pats += '(?i)\bimport\s[^;]*?\bfrom\s*["'']([^"''?#]+)', '(?im)^\s*import\s*["'']([^"''?#]+)', '(?i)\bimport\(\s*["'']([^"''?#]+)["'']\s*\)',
                 '(?i)\bexport\s[^;]*?\bfrom\s*["'']([^"''?#]+)', '(?i)\brequire\(\s*["'']([^"''?#]+)["'']\s*\)'
        foreach ($re in $pats) {
            foreach ($m in [regex]::Matches($Text, $re)) {
                $ref = $m.Groups[1].Value.Trim()
                if (-not $ref -or $ref -match '(?i)^([a-z][a-z0-9+.-]*:|//|#|\$|\{)') { continue }
                $isTag = $re.StartsWith('(?i)<')
                if (-not $isTag -and $ref -notmatch '^\.{1,2}/|^/') { continue }   # packages and aliases
                $want = Resolve-RelRef $ProjectRoot $dir $ref
                if (-not $want) { continue }
                & $addRef $m.Groups[1].Index $ref $want (Resolve-ImportTarget $ProjectRoot $want -Js:(-not $isTag))
            }
        }
        # Hook points: element ids, functions, custom hooks.
        if ($ext -in '.html', '.htm') {
            foreach ($m in [regex]::Matches($Text, '(?i)\bid\s*=\s*["'']([A-Za-z][\w:.-]*)["'']')) { $defs.Add([pscustomobject]@{ kind = 'id'; name = $m.Groups[1].Value; line = (Get-LineAt $nl $m.Index) }) }
            foreach ($m in [regex]::Matches($Text, '(?i)\bon[a-z]+\s*=\s*["'']\s*(?:return\s+)?([A-Za-z_$][\w$]*)\s*\(')) { $uses.Add([pscustomobject]@{ kind = 'fn'; name = $m.Groups[1].Value; line = (Get-LineAt $nl $m.Index) }) }
        }
        $idPats = '(?i)\bgetElementById\(\s*["'']([A-Za-z][\w:.-]*)["'']', '(?i)\bquerySelector(?:All)?\(\s*["'']#([A-Za-z][\w-]*)["'']', '\$\(\s*["'']#([A-Za-z][\w-]*)["'']'
        foreach ($re in $idPats) { foreach ($m in [regex]::Matches($Text, $re)) { $uses.Add([pscustomobject]@{ kind = 'id'; name = $m.Groups[1].Value; line = (Get-LineAt $nl $m.Index) }) } }
        $fnPats = '(?m)^[ \t]*(?:export[ \t]+)?(?:default[ \t]+)?(?:async[ \t]+)?function[ \t]*\*?[ \t]*([A-Za-z_$][\w$]*)',
                  '(?m)^[ \t]*(?:export[ \t]+)?(?:const|let|var)[ \t]+([A-Za-z_$][\w$]*)[ \t]*=[ \t]*(?:async[ \t]*)?(?:function\b|\([^)]*\)[ \t]*=>|[A-Za-z_$][\w$]*[ \t]*=>)',
                  '\bwindow\.([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:function\b|\([^)]*\)\s*=>)'
        $hooks = @{}
        foreach ($re in $fnPats) {
            foreach ($m in [regex]::Matches($Text, $re)) {
                $name = $m.Groups[1].Value
                $kind = if ($name -cmatch '^use[A-Z]') { 'hook' } else { 'fn' }
                if ($kind -eq 'hook') { $hooks[$name] = $true }
                $defs.Add([pscustomobject]@{ kind = $kind; name = $name; line = (Get-LineAt $nl $m.Index) })
            }
        }
        foreach ($m in [regex]::Matches($Text, '\b(use[A-Z][\w$]*)\s*\(')) {
            $name = $m.Groups[1].Value
            if ($hooks.ContainsKey($name)) { continue }   # its own definition or a call inside its file
            $uses.Add([pscustomobject]@{ kind = 'hook'; name = $name; line = (Get-LineAt $nl $m.Index) })
        }
    }
    if ($ext -in '.css', '.scss', '.less') {
        foreach ($m in [regex]::Matches($Text, '(?i)@import\s+(?:url\(\s*)?["'']?([^"'');\s]+)')) {
            $ref = $m.Groups[1].Value
            if ($ref -match '(?i)^([a-z][a-z0-9+.-]*:|//)') { continue }
            $want = Resolve-RelRef $ProjectRoot $dir $ref
            if ($want) { & $addRef $m.Groups[1].Index $ref $want (Resolve-ImportTarget $ProjectRoot $want) }
        }
    }
    if ($ext -eq '.py') {
        foreach ($m in [regex]::Matches($Text, '(?m)^[ \t]*(?:from[ \t]+(\.*)([\w.]*)[ \t]+import\b|import[ \t]+([\w.]+))')) {
            $dots = $m.Groups[1].Value.Length
            $mod = if ($m.Groups[3].Success) { $m.Groups[3].Value } else { $m.Groups[2].Value }
            if (-not $mod) { continue }
            $path = $mod.Replace('.', '/')
            $bases = if ($dots) { $b = $dir; for ($k = 1; $k -lt $dots; $k++) { $b = (Split-Path -Parent $b).Replace('\', '/') }; @($b) } else { @($dir, '') }
            foreach ($b in $bases) {
                $stem = if ($b) { "$b/$path" } else { $path }
                $target = if (Test-ProjectFile $ProjectRoot "$stem.py") { "$stem.py" } elseif (Test-ProjectFile $ProjectRoot "$stem/__init__.py") { "$stem/__init__.py" } else { $null }
                if ($target -or $dots) { & $addRef $m.Index $mod $(if ($target) { $target } else { "$stem.py" }) $target; break }
            }
        }
    }
    if ($ext -in '.ps1', '.psm1') {
        foreach ($m in [regex]::Matches($Text, '(?im)^.*?(?:Import-Module|^\s*\.\s|&\s|Join-Path).*?["'']((?:\$PSScriptRoot[\\/])?[^"''$]*?\.ps(?:m1|1|d1))["'']')) {
            $ref = $m.Groups[1].Value
            $want = Resolve-RelRef $ProjectRoot $dir (($ref -replace '^\$PSScriptRoot[\\/]', '').Replace('\', '/'))
            if ($want) { & $addRef $m.Groups[1].Index $ref $want (Resolve-ImportTarget $ProjectRoot $want) }
        }
    }
    @{ refs = $refs.ToArray(); defs = $defs.ToArray(); uses = $uses.ToArray() }
}

function Read-ImportIndex([string]$ProjectRoot) {
    $ix = @{ version = 1; updated = $null; files = @{} }
    $p = Get-ImportIndexPath $ProjectRoot
    if (Test-Path -LiteralPath $p) {
        try {
            $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
            foreach ($f in @($j.files.PSObject.Properties)) {
                $ix.files[$f.Name] = @{ size = [int64]$f.Value.size; mtime = [int64]$f.Value.mtime
                    refs = @($f.Value.refs | Where-Object { $_ }); defs = @($f.Value.defs | Where-Object { $_ }); uses = @($f.Value.uses | Where-Object { $_ }) }
            }
        } catch { }
    }
    $ix
}

function Save-ImportIndex([string]$ProjectRoot, $Index) {
    $Index.updated = (Get-Date).ToString('s')
    $p = Get-ImportIndexPath $ProjectRoot
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $p)
    $tmp = "$p.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Index -Depth 6 -Compress), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $p) { [IO.File]::Replace($tmp, $p, [NullString]::Value) } else { [IO.File]::Move($tmp, $p) }
}

function Update-ImportEntry([string]$ProjectRoot, $Index, [string]$Rel) {
    # Re-reads one file into the index (or drops it when it is gone or not code). Returns whether
    # the entry changed.
    $full = Join-Path $ProjectRoot $Rel.Replace('/', '\')
    if ($Rel -notmatch $script:CodeExt -or $Rel -match $script:Skip -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        if ($Index.files.ContainsKey($Rel)) { $Index.files.Remove($Rel); return $true }
        return $false
    }
    $fi = New-Object IO.FileInfo $full
    if ($fi.Length -gt 1MB) { if ($Index.files.ContainsKey($Rel)) { $Index.files.Remove($Rel) }; return $true }
    $links = Get-FileLinks $ProjectRoot $Rel (Read-TextFile $full).Text
    $Index.files[$Rel] = @{ size = $fi.Length; mtime = $fi.LastWriteTimeUtc.Ticks; refs = $links.refs; defs = $links.defs; uses = $links.uses }
    $true
}

function Update-ImportIndex {
    <# Brings the index up to date: with -Paths only those files, otherwise every code file whose
       size or time changed (and files that are gone are dropped). Returns the index. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Paths)
    $ix = Read-ImportIndex $ProjectRoot
    $dirty = $false
    if ($PSBoundParameters.ContainsKey('Paths')) {
        foreach ($p in @($Paths | Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/') } | Select-Object -Unique)) { if (Update-ImportEntry $ProjectRoot $ix $p) { $dirty = $true } }
    } else {
        $seen = @{}
        foreach ($f in @(Get-ProjectFiles $ProjectRoot)) {
            $rel = $f.path
            if ($rel -notmatch $script:CodeExt -or $rel -match $script:Skip) { continue }
            $seen[$rel] = $true
            $old = $ix.files[$rel]
            $fi = New-Object IO.FileInfo (Join-Path $ProjectRoot $rel.Replace('/', '\'))
            if ($old -and $old.size -eq $fi.Length -and $old.mtime -eq $fi.LastWriteTimeUtc.Ticks) { continue }
            if (Update-ImportEntry $ProjectRoot $ix $rel) { $dirty = $true }
        }
        foreach ($rel in @($ix.files.Keys)) { if (-not $seen.ContainsKey($rel)) { $ix.files.Remove($rel); $dirty = $true } }
        # A file that appeared can resolve refs that pointed nowhere before.
        foreach ($rel in @($ix.files.Keys)) {
            foreach ($r in @($ix.files[$rel].refs)) {
                if (-not $r.target -and $r.want -and (Test-ProjectFile $ProjectRoot $r.want)) { $r.target = $r.want; $dirty = $true }
            }
        }
    }
    if ($dirty -or -not (Test-Path -LiteralPath (Get-ImportIndexPath $ProjectRoot))) { Save-ImportIndex $ProjectRoot $ix }
    $ix
}

function Get-KindText([string]$Kind, [string]$Name) {
    switch ($Kind) { 'id' { "element #$Name" } 'fn' { "$Name() in an inline handler" } 'hook' { "hook $Name" } default { $Name } }
}

function Get-ImportUsers {
    <# Who uses $Path: files that import or load it, and files that use its ids, functions (inline
       handlers) or hooks; each as @{ path; line; what }. At most $Max. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Path, $Index, [int]$Max = 12)
    $ix = if ($Index) { $Index } else { Read-ImportIndex $ProjectRoot }
    $rel = $Path.Replace('\', '/')
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in @($ix.files.Keys | Sort-Object)) {
        if ($f -eq $rel) { continue }
        foreach ($r in @($ix.files[$f].refs)) { if ($r.target -eq $rel) { $out.Add(@{ path = $f; line = [int]$r.line; what = "imports $($r.ref)" }) } }
    }
    $mine = $ix.files[$rel]
    if ($mine) {
        $offer = @{}; foreach ($d in @($mine.defs)) { $offer["$($d.kind)|$($d.name)"] = $true }
        foreach ($f in @($ix.files.Keys | Sort-Object)) {
            if ($f -eq $rel) { continue }
            foreach ($u in @($ix.files[$f].uses)) { if ($offer.ContainsKey("$($u.kind)|$($u.name)")) { $out.Add(@{ path = $f; line = [int]$u.line; what = "uses $(Get-KindText $u.kind $u.name)" }) } }
        }
    }
    @($out | Select-Object -First $Max)
}

function Format-ImportUsers([string]$ProjectRoot, [string[]]$Paths) {
    <# A short "Used by" note per read file, so Copilot sees what depends on it (with lines). #>
    try { $ix = Read-ImportIndex $ProjectRoot } catch { return '' }
    if (-not $ix.files.Count) { return '' }
    $lines = foreach ($p in @($Paths | ForEach-Object { ($_ -replace ':(\d+(-\d+)?|outline)$', '').Replace('\', '/') } | Select-Object -Unique)) {
        $users = @(Get-ImportUsers $ProjectRoot $p $ix)
        if ($users.Count) { "Used by (file:line) for ${p}: " + (($users | ForEach-Object { "$($_.path):$($_.line) ($($_.what))" }) -join ', ') }
    }
    @($lines) -join "`n"
}

function Update-ImportsAfterRound {
    <# After a round of changes: updates the changed files and returns what the round broke, one
       line per problem with the place to fix: imports of a file that was deleted or moved, and
       ids, functions or hooks that were removed from a changed file while others still use them. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Paths)
    $list = @($Paths | Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/') } | Select-Object -Unique)
    if (-not $list.Count) { return }
    $before = Read-ImportIndex $ProjectRoot
    $removedDefs = @{}
    foreach ($p in $list) { $e = $before.files[$p]; if ($e) { foreach ($d in @($e.defs)) { $removedDefs["$($d.kind)|$($d.name)"] = $p } } }
    $ix = Update-ImportIndex $ProjectRoot -Paths $list
    foreach ($p in $list) { $e = $ix.files[$p]; if ($e) { foreach ($d in @($e.defs)) { $removedDefs.Remove("$($d.kind)|$($d.name)") } } }
    foreach ($f in @($ix.files.Keys)) { foreach ($d in @($ix.files[$f].defs)) { $removedDefs.Remove("$($d.kind)|$($d.name)") } }
    $changed = @{}; foreach ($p in $list) { $changed[$p] = $true }
    foreach ($f in @($ix.files.Keys | Sort-Object)) {
        foreach ($r in @($ix.files[$f].refs)) {
            if ($r.target -and $changed.ContainsKey("$($r.target)") -and -not (Test-ProjectFile $ProjectRoot "$($r.target)")) {
                "${f}:$($r.line): imports $($r.ref), but $($r.target) was deleted or moved in this round; point it at the new place or remove it"
            }
        }
        foreach ($u in @($ix.files[$f].uses)) {
            $from = $removedDefs["$($u.kind)|$($u.name)"]
            if ($from) { "${f}:$($u.line): uses $(Get-KindText $u.kind $u.name), which this round removed from $from; put it back or update this line" }
        }
    }
}

Export-ModuleMember -Function Get-FileLinks, Read-ImportIndex, Update-ImportIndex, Get-ImportUsers, Format-ImportUsers, Update-ImportsAfterRound
