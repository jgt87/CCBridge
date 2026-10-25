# Tidy-up list (only on request: the command menu). What the project likely no longer uses, each with a
# reason and a size, for the person to tick: script and style files nothing loads (Imports
# Find-UnloadedFiles, the import index), rules in the project's own stylesheets whose classes or ids no
# page or script uses, data files in data/ nothing names, and files in Work/ unchanged for 14 days.
# Never listed: Source/, .streamhub/, styles/kit/, Runbooks/, Scripts/, Logs/, protected paths,
# node_modules and build output, StreamHub's own data files (data-tools.js, data-index.js, the
# converted copies DataImport manages, data copies DataMirror writes), and any file a schedule, chain
# or hook names. Removing goes through Invoke-TidyRemove, which checks every ticked item again with the
# same rules first (a list made earlier never removes something now in use) and keeps the earlier
# versions in one change set, so Undo brings them back.

Import-Module (Join-Path $PSScriptRoot 'Workspace.psm1')   # Get-ProjectFiles, Resolve-ProjectPath, Resolve-ProjectLinkPath, Test-LinkPath, Test-ProtectedPath
Import-Module (Join-Path $PSScriptRoot 'Executor.psm1')    # New-Checkpoint, Save-CheckpointFile
Import-Module (Join-Path $PSScriptRoot 'Imports.psm1')     # Find-UnloadedFiles

$script:NeverListed = '(?i)^(Source|\.streamhub|styles/kit|Runbooks|Scripts|Logs|node_modules|dist|build|out|\.git)(/|$)|(^|/)(node_modules|\.git)/'
$script:CodeExt = '(?i)\.(m?js|cjs|jsx|tsx?|css|scss|less)$'
$script:UsageExt = '(?i)\.(html?|m?js|cjs|jsx|tsx?|vue|svelte|astro|php|cshtml|razor|ejs|hbs|njk|pug|json|md|ps1|psm1|py|xaml|txt)$'
$script:DataExt = '(?i)\.(json|js|csv|tsv|txt|xml|xlsx|xls|geojson|ya?ml)$'
$script:WorkDays = 14

function Get-TidyTexts([string]$ProjectRoot, $Files) {
    # rel -> text of the project's text files a page, script or setting could name another file in
    # (2 MB at most each). StreamHub's own records in .streamhub/ are not among them.
    $t = @{}
    foreach ($f in $Files) {
        if ($f.path -notmatch $script:UsageExt -or $f.size -gt 2MB) { continue }
        $t[$f.path] = try { [IO.File]::ReadAllText((Join-Path $ProjectRoot $f.path.Replace('/', '\'))) } catch { '' }
    }
    $t
}

function Get-NamedByAutomation([string]$ProjectRoot) {
    <# The text of what runs on its own: schedules, hooks and chains (a file named there is never
       listed). One string. #>
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($rel in '.streamhub\schedules.json', '.streamhub\hooks.json') {
        $p = Join-Path $ProjectRoot $rel
        if (Test-Path -LiteralPath $p -PathType Leaf) { $parts.Add([IO.File]::ReadAllText($p)) }
    }
    $rb = Join-Path $ProjectRoot 'Runbooks'
    if (Test-Path -LiteralPath $rb -PathType Container) {
        foreach ($c in Get-ChildItem -LiteralPath $rb -Filter '*.chain.md' -File -ErrorAction SilentlyContinue) { $parts.Add([IO.File]::ReadAllText($c.FullName)) }
    }
    ($parts -join "`n").Replace('\', '/')
}

function Test-TidyExcluded([string]$Rel, [string]$Automation, $ProtectedPatterns) {
    <# Why a project path is never listed, or $null when it may be. #>
    if ($Rel -match $script:NeverListed) { return 'a folder StreamHub or the build owns' }
    if (Test-ProtectedPath $Rel $ProtectedPatterns) { return 'protected' }
    $leaf = [IO.Path]::GetFileName($Rel)
    if ($Automation -and ($Automation.Contains($Rel) -or $Automation.Contains($leaf))) { return 'named by a schedule, chain or hook' }
    $null
}

function Test-NamedElsewhere([string]$Rel, $Texts) {
    # Whether another file names this one: its file name, or its name without extension in quotes
    # (DataTools.load('NAME'), an import without extension).
    $leaf = [IO.Path]::GetFileName($Rel); $stem = [IO.Path]::GetFileNameWithoutExtension($Rel)
    $quoted = '[/''"\x60]' + [regex]::Escape($stem) + '[''"\x60]'
    foreach ($k in $Texts.Keys) {
        if ($k -eq $Rel) { continue }
        $t = $Texts[$k]
        if ($t.Contains($leaf) -or ($stem.Length -ge 3 -and $t -match $quoted)) { return $true }
    }
    $false
}

function Get-CssRules([string]$Css) {
    <# The top-level rules of a stylesheet: @{ start; end (after the closing brace); selector; names
       (the classes and ids its selectors use, per selector) }. Comments and strings are blanked first;
       @-blocks (@media, @supports, @font-face...) are left out entirely. #>
    $mask = [regex]::Replace($Css, '(?s)/\*.*?\*/|"(?:[^"\\\r\n]|\\.)*"|''(?:[^''\\\r\n]|\\.)*''', { param($m) ' ' * $m.Length })
    $out = New-Object System.Collections.Generic.List[object]
    $i = 0; $from = 0
    while ($i -lt $mask.Length) {
        $ch = $mask[$i]
        if ($ch -eq ';') { $from = $i + 1; $i++; continue }
        if ($ch -eq '}') { $from = $i + 1; $i++; continue }   # a stray brace: start again after it
        if ($ch -ne '{') { $i++; continue }
        $depth = 0; $end = -1
        for ($k = $i; $k -lt $mask.Length; $k++) { if ($mask[$k] -eq '{') { $depth++ } elseif ($mask[$k] -eq '}') { $depth--; if ($depth -eq 0) { $end = $k; break } } }
        if ($end -lt 0) { break }   # unbalanced: nothing more is read
        $head = $mask.Substring($from, $i - $from)
        $start = $from + ($head.Length - $head.TrimStart().Length)
        $sel = $head.Trim()
        if ($sel -and -not $sel.StartsWith('@')) {
            $names = @(foreach ($s in $sel.Split(',')) { , @([regex]::Matches($s, '(?<![\w-])[.#](-?[A-Za-z_][\w-]*)') | ForEach-Object { $_.Value }) })
            $out.Add(@{ start = $start; end = $end + 1; selector = ($Css.Substring($start, $i - $start).Trim() -replace '\s+', ' '); names = $names })
        }
        $i = $end + 1; $from = $i
    }
    $out.ToArray()
}

function Test-CssNameUsed([string]$Name, [string]$AllText) {
    # Whether a class (.x) or id (#x) is in any page or script: the whole name, or a prefix ending in
    # '-' that code completes ('btn-' + kind, `btn-${kind}`).
    $bare = $Name.Substring(1)
    if ($AllText -match ('(?<![\w-])' + [regex]::Escape($bare) + '(?![\w-])')) { return $true }
    for ($i = $bare.IndexOf('-'); $i -gt 0; $i = $bare.IndexOf('-', $i + 1)) {
        $pre = [regex]::Escape($bare.Substring(0, $i + 1))
        if ($AllText -match ('(?<![\w-])' + $pre + '(["''\x60]|\$\{)')) { return $true }
    }
    $false
}

function Get-TidyCandidates {
    <# What the project likely no longer uses: @{ id; kind (file, css-rule, data, work); path;
       selector (css-rule); reason; size (bytes) }, sorted by kind and path. $Now and $Protected are
       for tests (default: the time now and the protected paths from the settings). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [datetime]$Now = (Get-Date), $Protected = $null)
    $root = $ProjectRoot.TrimEnd('\')
    $files = @(Get-ProjectFiles $root -MaxFiles 20000)   # skips links, node_modules, build output, .streamhub
    $texts = Get-TidyTexts $root $files
    $auto = Get-NamedByAutomation $root
    $items = New-Object System.Collections.Generic.List[object]
    $ok = { param($rel) -not (Test-TidyExcluded $rel $auto $Protected) }

    # 1. Script and style files nothing loads (the round check's rule, on every such file).
    $code = @($files | Where-Object { $_.path -match $script:CodeExt -and (& $ok $_.path) } | ForEach-Object { $_.path })
    $unloaded = @(if ($code.Count) { Find-UnloadedFiles -ProjectRoot $root -Paths $code })
    $sizes = @{}; foreach ($f in $files) { $sizes[$f.path] = [int64]$f.size }
    foreach ($p in $unloaded) {
        $items.Add(@{ id = "file|$p"; kind = 'file'; path = $p; selector = ''; reason = 'No page, script or stylesheet loads it, and no other file names it.'; size = $sizes[$p] })
    }

    # 2. Rules in the project's own stylesheets whose classes or ids nothing uses. Only judged when the
    #    project has pages or scripts to look in; a stylesheet nothing loads is listed whole above.
    $usage = @($texts.Keys | Where-Object { $_ -notmatch '(?i)\.css$' -and $_ -notmatch '(?i)\.(md|txt|json)$' })
    if ($usage.Count) {
        $all = ($usage | ForEach-Object { $texts[$_] }) -join "`n"
        $used = @{}   # class or id -> used (each looked up once)
        foreach ($f in $files) {
            if ($f.path -notmatch '(?i)\.css$' -or $f.path -match '(?i)(\.min\.css$|(^|/)vendor/)' -or $f.path -in $unloaded -or -not (& $ok $f.path) -or $f.size -gt 2MB) { continue }
            $css = [IO.File]::ReadAllText((Join-Path $root $f.path.Replace('/', '\')))
            if ($css.StartsWith('/* Generated by the helper program')) { continue }
            foreach ($r in @(Get-CssRules $css)) {
                $missing = New-Object System.Collections.Generic.List[string]
                $dead = $true
                # A selector with :not(), :is(), :where() or :has() can match without its names: kept.
                if ($r.selector -match '(?i):(not|is|where|has)\(') { continue }
                foreach ($names in $r.names) {
                    $gone = @($names | Where-Object { if (-not $used.ContainsKey($_)) { $used[$_] = Test-CssNameUsed $_ $all }; -not $used[$_] })
                    if (-not @($names).Count -or -not $gone.Count) { $dead = $false; break }   # a tag-only selector, or one whose names are all used
                    foreach ($g in $gone) { if (-not $missing.Contains($g)) { $missing.Add($g) } }
                }
                if (-not $dead) { continue }
                $items.Add(@{ id = "css-rule|$($f.path)|$($r.selector)"; kind = 'css-rule'; path = $f.path; selector = $r.selector; reason = "No page or script uses $($missing -join ', ')."; size = [int64]($r.end - $r.start) })
            }
        }
    }

    # 3. Data files in data/ that no file names, other than StreamHub's own.
    $managed = @{}
    $man = Join-Path $root '.streamhub\data-imports.json'
    if (Test-Path -LiteralPath $man) {
        try { foreach ($it in @(([IO.File]::ReadAllText($man) | ConvertFrom-Json).items)) { if ($it.output) { $managed["$($it.output)"] = 1; $managed[("$($it.output)" -replace '\.json$', '.js')] = 1 } } } catch { }
    }
    foreach ($f in $files) {
        if ($f.path -notmatch '(?i)^data/' -or $f.path -notmatch $script:DataExt -or -not (& $ok $f.path)) { continue }
        if ($f.path -match '(?i)^data/data-(tools|index)\.js$' -or $managed.ContainsKey($f.path)) { continue }
        if ($f.path -match '(?i)\.js$') {
            $head = try { $sr = New-Object IO.StreamReader((Join-Path $root $f.path.Replace('/', '\'))); try { "$($sr.ReadLine())" } finally { $sr.Dispose() } } catch { '' }
            if ($head -match '^\s*//\s*Generated from \S+ by the helper program') { continue }   # a data copy: follows its JSON
        }
        if (Test-NamedElsewhere $f.path $texts) { continue }
        $items.Add(@{ id = "data|$($f.path)"; kind = 'data'; path = $f.path; selector = ''; reason = 'No page, script or other file names it.'; size = [int64]$f.size })
    }

    # 4. One-off working files in Work/ unchanged for 14 days.
    foreach ($f in $files) {
        if ($f.path -notmatch '(?i)^Work/' -or -not (& $ok $f.path)) { continue }
        $age = ($Now - (New-Object IO.FileInfo (Join-Path $root $f.path.Replace('/', '\'))).LastWriteTime).TotalDays
        if ($age -lt $script:WorkDays) { continue }
        $items.Add(@{ id = "work|$($f.path)"; kind = 'work'; path = $f.path; selector = ''; reason = "A working file in Work/, unchanged for $([int][Math]::Floor($age)) days."; size = [int64]$f.size })
    }
    $order = @{ file = 0; 'css-rule' = 1; data = 2; work = 3 }
    @($items.ToArray() | Sort-Object { $order[$_.kind] }, { $_.path })
}

function Test-TidyItemStillUnused {
    <# Whether a ticked item is still on the list as the rules see the project now ($Candidates: a
       fresh Get-TidyCandidates, made once for many items). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$Item, $Candidates = $null)
    $list = if ($null -ne $Candidates) { @($Candidates) } else { @(Get-TidyCandidates $ProjectRoot) }
    [bool]@($list | Where-Object { $_.id -eq "$($Item.id)" }).Count
}

function Invoke-TidyRemove {
    <# Removes the ticked items ($Ids: the ids of Get-TidyCandidates), each checked again first: still
       on the list now, inside the project, not through a junction or link. Files are deleted, unused
       CSS rules cut from their stylesheet rule by rule; the earlier versions go into one change set
       ($Checkpoint, or a new 'Tidy up' one), so Undo brings everything back. Returns
       @{ removed = @(@{ id; kind; path; selector; size }); skipped = @(@{ id; path; reason });
          edited = @(@{ path; old; new }); checkpoint }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Ids, $Checkpoint = $null, [datetime]$Now = (Get-Date), $Protected = $null)
    $root = $ProjectRoot.TrimEnd('\')
    $fresh = @(Get-TidyCandidates $root -Now $Now -Protected $Protected)
    $byId = @{}; foreach ($c in $fresh) { $byId[$c.id] = $c }
    $removed = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $edited = New-Object System.Collections.Generic.List[object]
    $cp = $Checkpoint
    $rules = @{}   # stylesheet -> its ticked rules (cut together, from the end)
    foreach ($id in @($Ids | Where-Object { $_ } | Select-Object -Unique)) {
        $path = (("$id" -split '\|', 3) + @('', ''))[1]
        if (-not (Test-TidyItemStillUnused $root @{ id = $id } $fresh)) { $skipped.Add(@{ id = $id; path = $path; reason = 'in use now, or changed since the list was made' }); continue }
        $it = $byId[$id]
        try {
            $full = Resolve-ProjectPath $root $it.path
            if ((Resolve-ProjectLinkPath $root $full $it.path) -ne $full.TrimEnd('\') -or (Test-LinkPath $full)) { throw 'it goes through a junction or link' }
        } catch { $skipped.Add(@{ id = $id; path = $it.path; reason = "not removed: $($_.Exception.Message)" }); continue }
        if ($it.kind -eq 'css-rule') {
            if (-not $rules.ContainsKey($full)) { $rules[$full] = New-Object System.Collections.Generic.List[object] }
            $rules[$full].Add($it); continue
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $skipped.Add(@{ id = $id; path = $it.path; reason = 'already gone' }); continue }
        if (-not $cp) { $cp = New-Checkpoint $root 'Tidy up' }
        Save-CheckpointFile $cp $root $full
        try {
            (New-Object IO.FileInfo $full).Attributes = 'Normal'   # OneDrive can mark files read-only
            [IO.File]::Delete($full)
            $removed.Add(@{ id = $id; kind = $it.kind; path = $it.path; selector = ''; size = $it.size })
        } catch { $skipped.Add(@{ id = $id; path = $it.path; reason = "could not be deleted: $($_.Exception.Message)" }) }
    }
    foreach ($full in $rules.Keys) {
        $rel = $rules[$full][0].path
        $bytes = [IO.File]::ReadAllBytes($full)
        $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $skip = if ($bom) { 3 } else { 0 }
        $enc = New-Object Text.UTF8Encoding($false)
        $old = $enc.GetString($bytes, $skip, $bytes.Length - $skip)
        # The rules as they are in the file now (the same parse the list used), cut from the end.
        $inFile = @{}; foreach ($r in @(Get-CssRules $old)) { if (-not $inFile.ContainsKey($r.selector)) { $inFile[$r.selector] = $r } }
        $cuts = @(foreach ($it in $rules[$full]) { if ($inFile.ContainsKey($it.selector)) { @{ it = $it; r = $inFile[$it.selector] } } else { $skipped.Add(@{ id = $it.id; path = $rel; reason = 'the rule is no longer in the file' }) } })
        $text = $old
        foreach ($c in @($cuts | Sort-Object { $_.r.start } -Descending)) {
            $s = $c.r.start; $e = $c.r.end
            # The whole line when the rule is alone on it, with one line break after it.
            $ls = $text.LastIndexOf("`n", [Math]::Max(0, $s - 1)) + 1
            if ($s -gt 0 -and -not $text.Substring($ls, $s - $ls).Trim()) { $s = $ls }
            $rest = $text.Substring($e)
            $m = [regex]::Match($rest, '^[ \t]*\r?\n')
            if ($m.Success) { $e += $m.Length }
            $text = $text.Remove($s, $e - $s)
            $removed.Add(@{ id = $c.it.id; kind = 'css-rule'; path = $rel; selector = $c.it.selector; size = $c.it.size })
        }
        if ($text -ceq $old) { continue }
        if (-not $cp) { $cp = New-Checkpoint $root 'Tidy up' }
        Save-CheckpointFile $cp $root $full
        $body = $enc.GetBytes($text)
        if ($bom) { $body = [byte[]](@(0xEF, 0xBB, 0xBF) + $body) }
        [IO.File]::WriteAllBytes($full, $body)
        $edited.Add(@{ path = $rel; old = $old; new = $text })
    }
    @{ removed = $removed.ToArray(); skipped = $skipped.ToArray(); edited = $edited.ToArray(); checkpoint = $cp }
}

function Format-TidySize([int64]$Bytes) {
    # A size people read: 512 bytes, 3.4 KB, 1.2 MB.
    if ($Bytes -lt 1024) { return "$Bytes bytes" }
    if ($Bytes -lt 1MB) { return ('{0:0.#} KB' -f ($Bytes / 1KB)).Replace(',', '.') }
    ('{0:0.#} MB' -f ($Bytes / 1MB)).Replace(',', '.')
}

Export-ModuleMember -Function Get-TidyCandidates, Test-TidyItemStillUnused, Invoke-TidyRemove, Get-CssRules, Format-TidySize
