# A project overview for a colleague, on the person's request only (command menu > Write a project
# overview): Runbooks/Exports/project-overview.md in two parts.
#   1. Facts the helper program gathers itself with fixed rules (Get-ProjectOverviewFacts,
#      Format-ProjectOverviewFacts): what the project is built from, how it was set up, how to open it,
#      the data it reads and how to refresh it, runbooks, chains and schedules, the UI kit, what
#      earlier tasks did and the to-do items still open. Names and relative paths only: nothing
#      personal (Protect-LogText over the whole text), never connection details.
#   2. The explanation: three sections with a fixed placeholder line each, which an ordinary chat task
#      (Get-ProjectOverviewRequest) asks Copilot to fill with an edit, keeping the facts as they are.
# The file's first line marks it as the helper program's: such a file is replaced by the next
# overview. A person who wants to keep their own edits removes that line; the next overview is then
# written next to it as project-overview-STAMP.md.
# ASCII only (Windows PowerShell 5.1).

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Workspace', 'Config', 'UiKit', 'ProjectSetup', 'Progress', 'TaskNotes', 'DataImport', 'SharePointLink', 'SqlServer', 'Schedule', 'Runbook', 'Fetch', 'Chain') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:OverviewRel = 'Runbooks/Exports/project-overview.md'
$script:Marker = '<!-- streamhub:project-overview (remove this line to keep your own changes) -->'
# The sections Copilot writes, each with its placeholder line (plain text: no brackets or tags,
# which the chat page can change on the way).
$script:Sections = @(
    @{ heading = 'What it is for'; placeholder = 'TO BE WRITTEN: what it is for'; ask = 'what the project does and for whom, in plain words' }
    @{ heading = 'How to use it'; placeholder = 'TO BE WRITTEN: how to use it'; ask = 'how to open it and use it, step by step' }
    @{ heading = 'Things to know'; placeholder = 'TO BE WRITTEN: things to know'; ask = 'what to watch out for: data that must be refreshed, limits, open points' }
)
# The page a project's app starts from, in this order (the same rule as ui-src/src/lib/app-entry.ts
# findAppEntry: a build's output before a plain index.html at the root).
$script:EntryPages = @('dist/index.html', 'build/index.html', 'out/index.html', 'index.html')
$script:BuildLabels = @{ single = 'One HTML file with everything in it'; modular = 'Separate files (page, styles, scripts, data)'; copilot = 'Left to Copilot to choose' }
$script:RefreshNotes = @{
    'Refresh-Data.ps1' = 'copies the live data file into Source/Live/ again'
    'Refresh-Web-Data.ps1' = 'downloads the saved web data again'
    'Refresh-Database.ps1' = 'runs the saved database queries again'
}

function Get-OverviewSections { $script:Sections }

function Select-AppEntryPage([string[]]$Paths) {
    <# The app's entry page among project paths ('/' or '\', any case), as the entry list spells it;
       $null when there is none. #>
    $have = @{}
    foreach ($p in @($Paths)) { if ($p) { $have["$p".Replace('\', '/').TrimStart('/').ToLowerInvariant()] = $true } }
    foreach ($e in $script:EntryPages) { if ($have.ContainsKey($e)) { return $e } }
    $null
}

function Get-AppEntryPage([string]$ProjectRoot) {
    # The same rule on disk (the project file list skips dist/, build/ and out/, so it is not used here).
    $have = @($script:EntryPages | Where-Object { Test-Path -LiteralPath (Join-Path $ProjectRoot $_.Replace('/', '\')) -PathType Leaf })
    Select-AppEntryPage $have
}

function Test-ModulePage([string]$Path) {
    # A page with <script type="module"> works only from a web server, not opened from disk.
    try { [bool]([IO.File]::ReadAllText($Path) -match '(?i)<script[^>]*\btype\s*=\s*["'']?module\b') } catch { $false }
}

function Get-OneLine([AllowEmptyString()][string]$Text, [int]$Max = 200) {
    $t = ("$Text" -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3).TrimEnd() + '...' }
    $t
}

function Invoke-FactPart([string]$Name, [scriptblock]$Block) {
    # One part of the facts: a part that fails is logged and left empty, so the rest still comes.
    try { & $Block } catch { Write-CCBLog info overview "The $Name facts were not read: $($_.Exception.Message)"; $null }
}

function Get-ProjectOverviewFacts {
    <# What the helper program knows about a project, by fixed rules: @{ name; files; bytes; languages;
       sourceFiles; folders = @(@{ name; files }); entry; entryModule; build; buildBy; answers = @(label);
       data = @(@{ source; output; rows; status }); live (file name); sharepoint = @(name);
       databases = @(name); refresh = @(@{ path; note }); runbooks = @(@{ name; title; kind; shared });
       chains = @(@{ name; title; steps }); schedules = @(@{ title; kind; when; enabled });
       kit = @{ on; inProject; parts }; earlier = @(@{ when; status; request; result });
       todos = @(@{ file; items }) }. Reads only. $AppRoot for the UI kit settings, $StateDir for the
       earlier work (the project's state folder by default). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$AppRoot = '', [string]$StateDir = '')
    $root = $ProjectRoot.TrimEnd('\')
    $f = @{ name = (Split-Path -Leaf $root); files = 0; bytes = [int64]0; languages = @(); sourceFiles = 0; folders = @(); entry = $null; entryModule = $false
            build = ''; buildBy = ''; answers = @(); data = @(); live = ''; sharepoint = @(); databases = @(); refresh = @(); runbooks = @(); chains = @(); schedules = @()
            kit = @{ on = $false; inProject = $false; parts = @() }; earlier = @(); todos = @() }

    $null = Invoke-FactPart 'files' {
        $o = Get-ProjectOverview $root
        $f.files = [int]$o.files; $f.bytes = [int64]$o.bytes; $f.languages = @($o.languages); $f.sourceFiles = [int]$o.sourceFiles
        $count = @{}
        foreach ($p in @(Get-ProjectFiles $root)) {
            $top = if ("$($p.path)".Contains('/')) { "$($p.path)".Split('/')[0] + '/' } else { '(top level)' }
            $count[$top] = 1 + [int]$count[$top]
        }
        $f.folders = @($count.Keys | Sort-Object | ForEach-Object { @{ name = $_; files = $count[$_] } })
    }
    $null = Invoke-FactPart 'entry page' {
        $f.entry = Get-AppEntryPage $root
        if ($f.entry) { $f.entryModule = Test-ModulePage (Join-Path $root $f.entry.Replace('/', '\')) }
    }
    $null = Invoke-FactPart 'setup' {
        $s = Get-ProjectSetup $root
        $f.build = "$($s.build)"; $f.buildBy = "$($s.chosenBy)"
        if ($s.liveSource) { $f.live = [IO.Path]::GetFileName("$($s.liveSource)") }
        $f.answers = @(Get-SetupAnswerList $root | ForEach-Object { "$($_.label)" })
    }
    $null = Invoke-FactPart 'data' {
        $man = Read-DataImportManifest $root
        $f.data = @($man.Keys | Sort-Object | ForEach-Object {
            $it = $man[$_]
            $rows = [int64]0; foreach ($sh in @($it.sheets)) { if ($sh) { $rows += [int64]$sh.rows } }
            @{ source = "$($it.source)"; output = "$($it.output)"; rows = $rows; status = "$($it.status)" }
        })
    }
    $null = Invoke-FactPart 'SharePoint' { $f.sharepoint = @(@((Get-SharePointLinks $root).sources) | Where-Object { $_ } | ForEach-Object { if ($_.label) { "$($_.label)" } elseif ($_.fileName) { "$($_.fileName)" } else { 'a SharePoint list' } }) }
    # Database connections by their name only: never the server or database.
    $null = Invoke-FactPart 'database' { $f.databases = @(Get-DbConnections $root | ForEach-Object { "$($_.name)" }) }
    $null = Invoke-FactPart 'refresh' {
        $dir = Join-Path $root 'Scripts'
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $f.refresh = @(Get-ChildItem -LiteralPath $dir -Filter 'Refresh-*.ps1' -File | Sort-Object Name | ForEach-Object {
                @{ path = "Scripts/$($_.Name)"; note = "$($script:RefreshNotes[$_.Name])" }
            })
        }
    }
    $null = Invoke-FactPart 'runbooks' {
        $rb = @(Get-Runbooks $root | ForEach-Object { @{ name = "$($_.name)"; title = "$($_.title)"; kind = 'checked JSON'; shared = [bool]$_.shared } })
        $fp = @(Get-FetchPrompts $root | ForEach-Object { @{ name = "$($_.name)"; title = "$($_.name)"; kind = 'text answer'; shared = [bool]$_.shared } })
        $f.runbooks = @($rb + $fp)
    }
    $null = Invoke-FactPart 'chains' { $f.chains = @(Get-Chains $root | ForEach-Object { @{ name = "$($_.name)"; title = "$($_.title)"; steps = @($_.steps).Count } }) }
    $null = Invoke-FactPart 'schedules' {
        $file = Join-Path $root '.streamhub\schedules.json'
        if (Test-Path -LiteralPath $file) {
            # Assigned first: in PowerShell 5.1 ConvertFrom-Json hands a JSON array on as one object.
            $parsed = [IO.File]::ReadAllText($file) | ConvertFrom-Json
            $f.schedules = @(foreach ($o in $parsed) {
                if (-not $o -or -not $o.repeat) { continue }
                $when = try { Format-ScheduleWhen $o } catch { '' }
                @{ title = "$($o.title)"; kind = "$($o.kind)"; when = "$when"; enabled = [bool]$o.enabled }
            })
        }
    }
    $null = Invoke-FactPart 'UI kit' {
        $f.kit.inProject = Test-Path -LiteralPath (Join-Path $root 'styles\kit\tokens.css') -PathType Leaf
        if ($AppRoot) {
            $f.kit.on = [bool](Test-UiKitOn $AppRoot)
            if ($f.kit.on) { $f.kit.parts = @(Get-UiKitParts $AppRoot | Where-Object { $_ -notin 'base', 'palette', 'themeswitch' }) }
        }
    }
    $null = Invoke-FactPart 'earlier work' {
        $dir = if ($StateDir) { $StateDir } else { Get-ProjectStateDir $root }
        $f.earlier = @(Read-ProgressEntries $dir 10 | ForEach-Object { @{ when = "$($_.when)"; status = "$($_.status)"; request = (Get-OneLine "$($_.request)" 200); result = (Get-OneLine "$($_.result)" 200) } })
    }
    $null = Invoke-FactPart 'to-do' { $f.todos = @(Get-OpenTodoItems $root) }
    $f
}

function Format-Bytes([int64]$Bytes) {
    if ($Bytes -ge 1MB) { return ('{0:0.0} MB' -f ($Bytes / 1MB)).Replace(',', '.') }
    if ($Bytes -ge 1KB) { return "$([Math]::Round($Bytes / 1KB)) KB" }
    "$Bytes bytes"
}

function Format-ProjectOverviewFacts {
    <# The facts as Markdown sections (### headings), personal details masked. #>
    param([Parameter(Mandatory)]$Facts)
    $f = $Facts
    $sb = New-Object Text.StringBuilder
    $add = { param($l) [void]$sb.AppendLine($l) }

    & $add '### Built from'
    & $add ''
    & $add "- $($f.files) files, $(Format-Bytes $f.bytes)$(if (@($f.languages).Count) { "; mainly $(@($f.languages) -join ', ')" })."
    if ([int]$f.sourceFiles -gt 0) { & $add "- $($f.sourceFiles) source data file(s) in Source/ (read-only: the project reads them, never changes them)." }
    foreach ($d in @($f.folders | Select-Object -First 12)) { & $add "- $($d.name): $($d.files) file(s)" }
    if ($f.build) { & $add "- Build form: $($script:BuildLabels[$f.build])$(if ($f.buildBy -eq 'copilot') { ' (chosen by Copilot)' })." }
    foreach ($a in @($f.answers)) { if ($a) { & $add "- $a" } }
    & $add ''

    & $add '### How to open it'
    & $add ''
    if ($f.entry) {
        & $add "- Open $($f.entry) in Edge or another browser."
        if ($f.entryModule) { & $add '- This page loads its scripts as modules: it works from a web server (StreamHub serves it with Open app), not when opened straight from disk.' }
    } else { & $add '- No app entry page (index.html) was found.' }
    & $add ''

    & $add '### Data'
    & $add ''
    $any = $false
    foreach ($d in @($f.data)) {
        $any = $true
        $what = if ($d.status -eq 'script') { 'converted by a project script' } elseif ($d.output) { "converted to $($d.output)" } else { 'converted' }
        & $add "- $($d.source)$(if ([int64]$d.rows -gt 0) { " ($($d.rows) rows)" }), $what"
    }
    if ($f.live) { $any = $true; & $add "- Live data: $($f.live), a file outside the project, copied into Source/Live/ when it changes." }
    foreach ($s in @($f.sharepoint)) { if ($s) { $any = $true; & $add "- From SharePoint: $s" } }
    foreach ($n in @($f.databases)) { if ($n) { $any = $true; & $add "- Database connection: $n (read-only, with the viewer's Windows sign-in)" } }
    if (-not $any) { & $add '- No data files were converted and no data sources are linked.' }
    & $add ''

    & $add '### Keeping the data up to date'
    & $add ''
    if (@($f.refresh).Count) {
        foreach ($r in @($f.refresh)) { & $add "- $($r.path)$(if ($r.note) { ": $($r.note)" }). Run it with: powershell -NoProfile -ExecutionPolicy Bypass -File $($r.path.Replace('/', '\'))" }
    } else { & $add '- No refresh scripts.' }
    & $add ''

    & $add '### Automation'
    & $add ''
    $auto = $false
    foreach ($r in @($f.runbooks)) { $auto = $true; & $add "- Runbook $($r.name)$(if ($r.title -and $r.title -ne $r.name) { ": $($r.title)" }) ($($r.kind)$(if ($r.shared) { ', shared by every project in this folder' }))" }
    foreach ($c in @($f.chains)) { $auto = $true; & $add "- Chain $($c.name)$(if ($c.title -and $c.title -ne $c.name) { ": $($c.title)" }) ($($c.steps) step(s))" }
    foreach ($s in @($f.schedules)) { $auto = $true; & $add "- Schedule: $($s.title)$(if ($s.when) { ", $($s.when)" })$(if (-not $s.enabled) { ' (switched off)' })" }
    if (-not $auto) { & $add '- No runbooks, chains or schedules.' }
    & $add ''

    & $add '### Look'
    & $add ''
    if ($f.kit.inProject) {
        & $add "- Built with StreamHub's UI kit (styles/kit/)$(if (@($f.kit.parts).Count) { "; parts switched on: $(@($f.kit.parts) -join ', ')" })."
    } else { & $add "- Does not use StreamHub's UI kit." }
    & $add ''

    & $add '### Earlier work'
    & $add ''
    if (@($f.earlier).Count) {
        # Newest first: the reader wants the latest state.
        $list = @($f.earlier); [array]::Reverse($list)
        foreach ($e in $list) { & $add "- $($e.when), $($e.status): $($e.request)$(if ($e.result) { " Result: $($e.result)" })" }
    } else { & $add '- No earlier work recorded.' }
    & $add ''

    & $add '### Still open'
    & $add ''
    $open = $false
    foreach ($t in @($f.todos)) { foreach ($i in @($t.items | Select-Object -First 10)) { $open = $true; & $add "- $i ($($t.file))" } }
    if (-not $open) { & $add '- No open to-do items.' }
    Protect-LogText $sb.ToString().TrimEnd()
}

function New-ProjectOverviewText {
    # The whole file: the marker, the three sections to fill, then the facts.
    param([Parameter(Mandatory)]$Facts, [datetime]$Now = (Get-Date))
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($script:Marker)
    $lines.Add("# $($Facts.name): project overview")
    $lines.Add('')
    $lines.Add("Written by StreamHub on $($Now.ToString('yyyy-MM-dd')) for a colleague who has not seen this project. The facts at the end come from the project's files and settings; the sections before them are written by Copilot from the same files.")
    foreach ($s in $script:Sections) { $lines.Add(''); $lines.Add("## $($s.heading)"); $lines.Add(''); $lines.Add($s.placeholder) }
    $lines.Add('')
    $lines.Add('## Facts')
    $lines.Add('')
    $lines.Add((Format-ProjectOverviewFacts $Facts))
    ($lines -join "`n") + "`n"
}

function Test-OwnOverview([string]$Path) {
    # Whether a file is the helper program's (its first line is the marker): such a file may be replaced.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    # @() outside the try: a try statement hands a one-item array on as the item itself.
    $first = @(try { [IO.File]::ReadAllLines($Path) | Select-Object -First 1 } catch { })
    [bool]($first.Count -and "$($first[0])".TrimStart([char]0xFEFF).Trim() -eq $script:Marker)
}

function Write-ProjectOverview {
    <# Writes the overview: Runbooks/Exports/project-overview.md, replacing an older one only when the
       helper program wrote it (Test-OwnOverview); a person's own version stays and the new one goes to
       project-overview-yyyyMMdd-HHmm.md. Returns @{ rel; full; exists; old; new; kept (the person's
       file left alone, or '') }: what Agent needs for its own-change card and the request. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string]$AppRoot = '', [string]$StateDir = '', [datetime]$Now = (Get-Date))
    $root = $ProjectRoot.TrimEnd('\')
    $rel = $script:OverviewRel; $kept = ''
    $full = Join-Path $root $rel.Replace('/', '\')
    if ((Test-Path -LiteralPath $full) -and -not (Test-OwnOverview $full)) {
        $kept = $rel
        $rel = "Runbooks/Exports/project-overview-$($Now.ToString('yyyyMMdd-HHmm')).md"
        $full = Join-Path $root $rel.Replace('/', '\')
        # Another overview in the same minute that a person kept too: a numbered name.
        $n = 2
        while ((Test-Path -LiteralPath $full) -and -not (Test-OwnOverview $full)) { $rel = "Runbooks/Exports/project-overview-$($Now.ToString('yyyyMMdd-HHmm'))-$n.md"; $full = Join-Path $root $rel.Replace('/', '\'); $n++ }
    }
    $exists = Test-Path -LiteralPath $full
    $old = if ($exists) { [IO.File]::ReadAllText($full) } else { $null }
    $text = New-ProjectOverviewText (Get-ProjectOverviewFacts $root $AppRoot $StateDir) $Now
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full)
    [IO.File]::WriteAllText($full, $text, (New-Object Text.UTF8Encoding($false)))
    @{ rel = $rel; full = $full; exists = [bool]$exists; old = $old; new = $text; kept = $kept }
}

function Get-ProjectOverviewRequest {
    <# The chat request that has Copilot write the three sections of the overview at $Rel: each
       placeholder line replaced with an edit, the rest of the file as it is. Worded so it goes as
       project work that changes a file (Prompts Get-TaskKind, Get-TaskIntent 'change'). #>
    param([string]$Rel = $script:OverviewRel)
    $asks = @($script:Sections | ForEach-Object { "- Replace the line '$($_.placeholder)' with $($_.ask)." })
    @(
        "Write the explanation in $Rel, the project overview for a colleague who has not seen this project. Read that file and the project's own files first; the facts at the end of the overview name them."
        "Then edit $Rel with one edit block:"
        $asks
        'Use a few short paragraphs or a short list per section, in plain words for someone who did not build it. Write only what the files show; where they do not show something, say that it is not clear from the project.'
        "Leave the rest of the file exactly as it is: the first line, the headings and the Facts section stay as written. Touch no other file."
    ) -join "`n"
}

Export-ModuleMember -Function Get-OverviewSections, Select-AppEntryPage, Get-AppEntryPage, Test-ModulePage, Get-ProjectOverviewFacts, Format-ProjectOverviewFacts, New-ProjectOverviewText, Test-OwnOverview, Write-ProjectOverview, Get-ProjectOverviewRequest
