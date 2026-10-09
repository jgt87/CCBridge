<#
  Project setup: choices the user makes once for a project, asked by StreamHub itself before the
  first request goes to Copilot (CCBridge has no model: when to ask is a fixed rule on the request
  and the project's files). Kept in <project>\.streamhub\project.json and named to Copilot in every
  task (Agent Get-ProjectContext, Prompts rules:build-*).

  The first question: how a page, dashboard or report is built.
    single  - one HTML file with everything in it (OneFile.psm1: the UI kit and the data are blocks the
              helper program fills, Update-OneFilePages);
    modular - separate files (page, styles, scripts, data), as the web rules describe;
    copilot - the user leaves it to Copilot.
  Live data: a data file outside the project (for example a SharePoint folder synced by OneDrive).
  A page opened from disk cannot read it (the browser blocks fetch and XHR of local files; tested),
  so the helper program copies it into Source/Live/ when it changes (Sync-LiveSource: only ever
  reads the outside file) and the data import converts it; Scripts/Refresh-Data.ps1 does the same
  without StreamHub running (Invoke-LiveRefresh).
#>
foreach ($m in 'Log', 'Workspace', 'Executor', 'Config', 'UiKit', 'DataImport', 'OneFile') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:SetupRel = '.streamhub/project.json'
$script:LiveFolder = 'Live'
$script:LiveExt = '(?i)\.(csv|tsv|xlsx|xlsm|json)$'
$script:LiveMaxBytes = 25MB

# When to ask: a request that builds a page, dashboard, report or app (fixed words).
$script:BuildWords = '(?i)\b(build|create|make|develop|generate|design|set up|bouw|maak|ontwikkel)\b'
$script:PageWords = '(?i)\b(dashboards?|reports?|overview|web ?pages?|pages?|websites?|sites?|web ?apps?|apps?|visuali[sz]ations?|charts?|graphs?|html|rapport(age)?s?|overzicht|pagina)\b'
# The form said in the request itself: then nothing is asked.
$script:SinglePattern = '(?i)\b(single|one|1|standalone|stand-alone|self[- ]contained)[ -](html[ -])?file\b|\b(in|as) (a|one) (single )?(html )?file\b|\bembed(ded|ding)? (all|everything|the data|the styles?)\b|\ball in one file\b|\b(in )?(e|\u00e9)(e|\u00e9)n (html[ -])?bestand\b'
$script:ModularPattern = '(?i)\bmodular\b|\bseparate (html |css |js |javascript |style |script )?(files|stylesheets?)\b|\b(multiple|several) files\b|\bsplit (it )?(in|into|over) (separate |multiple )?files\b|\bstyles?\.css\b|\b(own|their own) (css|js|style|script) files?\b|\b(losse|aparte) bestanden\b'
# A data file outside the project named in the request (a full Windows path or a share).
$script:OutsidePathPattern = '(?i)(?<![\w/])(?:[a-z]:\\|\\\\[\w.$-]+\\)[^"<>|?*\r\n]*?\.(csv|tsv|xlsx|xlsm|json)\b'

function Get-ProjectSetupPath([string]$ProjectRoot) { Join-Path $ProjectRoot $script:SetupRel.Replace('/', '\') }

function Get-ProjectSetup([string]$ProjectRoot) {
    <# The project's saved choices: @{ build ('' when not chosen); liveSource; liveStamp; chosenBy; chosenAt }. #>
    $s = @{ build = ''; liveSource = ''; liveStamp = ''; chosenBy = ''; chosenAt = '' }
    if (-not $ProjectRoot) { return $s }
    $f = Get-ProjectSetupPath $ProjectRoot
    if (Test-Path -LiteralPath $f) {
        try {
            $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json
            foreach ($k in @($s.Keys)) { if ($null -ne $j.$k) { $s[$k] = "$($j.$k)" } }
        } catch { Write-CCBLog info setup "project.json not read: $($_.Exception.Message)" }
    }
    if ($s.build -notin 'single', 'modular', 'copilot') { $s.build = '' }
    $s
}

function Save-ProjectSetup {
    <# Merges $Changes (build, liveSource, liveStamp, chosenBy) into the project's setup and saves it. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][hashtable]$Changes)
    $s = Get-ProjectSetup $ProjectRoot
    foreach ($k in $Changes.Keys) { $s[$k] = "$($Changes[$k])" }
    if ($Changes.ContainsKey('build') -or $Changes.ContainsKey('liveSource')) { $s.chosenAt = (Get-Date).ToString('s') }
    $f = Get-ProjectSetupPath $ProjectRoot
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $f)
    $o = [ordered]@{}; foreach ($k in 'build', 'liveSource', 'liveStamp', 'chosenBy', 'chosenAt') { $o[$k] = $s[$k] }
    [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $o), (New-Object Text.UTF8Encoding($false)))
    $s
}

function Get-StatedBuild([AllowEmptyString()][string]$Text) {
    # The build form a request names itself: 'single', 'modular' or ''.
    if ("$Text" -match $script:SinglePattern) { return 'single' }
    if ("$Text" -match $script:ModularPattern) { return 'modular' }
    ''
}

function Get-NamedOutsideFile([AllowEmptyString()][string]$Text) {
    # The first data file outside the project a request names by its full path, or ''.
    $m = [regex]::Match("$Text", $script:OutsidePathPattern)
    if ($m.Success) { $m.Value.Trim() } else { '' }
}

function Test-OwnCode([string[]]$Paths) {
    # Whether the project has code of its own (not StreamHub's kit and data files).
    @($Paths | Where-Object { $_ -match '(?i)\.(html?|css|scss|m?js|cjs|jsx?|tsx?|vue|svelte|py|ps1|cs)$' -and $_ -notmatch '(?i)^(styles/kit|data|\.streamhub|Source|Work|Scripts)/' }).Count -gt 0
}

function Get-SetupQuestions {
    <# What to ask before the first request of a new project goes to Copilot: @() when nothing, else
       questions @{ id; question; options = @(@{ value; label; help }) } plus 'live' (offer a data
       file outside the project) and 'suggest' (a path the request named). Asked when the project has
       no build form yet, no code of its own, and the request builds a page, dashboard, report or app
       without saying how. $Setup from Get-ProjectSetup. #>
    param([AllowEmptyString()][string]$Text, [string[]]$Paths, $Setup)
    if ($Setup -and $Setup.build) { return $null }
    if (Test-OwnCode $Paths) { return $null }
    if ("$Text" -notmatch $script:BuildWords -or "$Text" -notmatch $script:PageWords) { return $null }
    if (Get-StatedBuild $Text) { return $null }
    $hasData = @($Paths | Where-Object { $_ -match '(?i)\.(csv|tsv|xlsx|xlsm)$' -or $_ -match '(?i)^Source/.+\.json$' }).Count -gt 0 -or "$Text" -match '(?i)\b(csv|tsv|excel|xlsx|spreadsheet|data ?file|sharepoint|onedrive)\b|\.(csv|tsv|xlsx|xlsm)\b'
    @{
        questions = @(@{
            id = 'build'; question = 'How should this be built?'
            options = @(
                @{ value = 'single'; label = 'One file'; help = 'Everything in one HTML file (page, styles, scripts, UI kit and data), to share or post as it is.' },
                @{ value = 'modular'; label = 'Separate files'; help = 'The page, styles, scripts and data in their own files and folders, easier to grow.' },
                @{ value = 'copilot'; label = 'Let Copilot decide'; help = 'Copilot picks what fits the request.' })
        })
        live = $hasData
        suggest = (Get-NamedOutsideFile $Text)
    }
}

function Test-LiveSourcePath {
    <# Why a path cannot be the live data file ('' when it can): a full path to an existing CSV, TSV,
       Excel or JSON file outside the project, at most 25 MB. #>
    param([AllowEmptyString()][string]$Path, [string]$ProjectRoot)
    $p = "$Path".Trim().Trim('"')
    if (-not $p) { return 'no path given' }
    if (-not [IO.Path]::IsPathRooted($p) -or $p -notmatch '^(?i)([a-z]:\\|\\\\)') { return "'$p' is not a full path (for example C:\Users\NAME\Company\Site - Documents\data.csv)" }
    if ($p -notmatch $script:LiveExt) { return "'$p' is not a CSV, TSV, Excel or JSON file" }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return "'$p' was not found (is the folder synced by OneDrive on this computer?)" }
    $full = [IO.Path]::GetFullPath($p)
    if ($ProjectRoot -and $full.StartsWith($ProjectRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return "'$p' is already in the project; a live file is one outside it" }
    if ((Get-Item -LiteralPath $full).Length -gt $script:LiveMaxBytes) { return "'$p' is larger than $($script:LiveMaxBytes / 1MB) MB" }
    ''
}

function Get-LiveCopyRel([string]$Source) {
    # Where the live file's copy lives in the project.
    "Source/$($script:LiveFolder)/$([IO.Path]::GetFileName($Source))"
}

function Sync-LiveSource {
    <# Copies the project's live data file into Source/Live/ when it changed (size and time), and
       accepts it as the user's source data (Sync-SourceVault). Only ever reads the outside file.
       Returns @{ changed; missing; rel; source } or $null without a live file. #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $s = Get-ProjectSetup $ProjectRoot
    if (-not $s.liveSource) { return $null }
    $rel = Get-LiveCopyRel $s.liveSource
    if (-not (Test-Path -LiteralPath $s.liveSource -PathType Leaf)) { return @{ changed = $false; missing = $true; rel = $rel; source = $s.liveSource } }
    $fi = Get-Item -LiteralPath $s.liveSource
    $stamp = "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
    $target = Join-Path $ProjectRoot $rel.Replace('/', '\')
    if ($stamp -eq $s.liveStamp -and (Test-Path -LiteralPath $target)) { return @{ changed = $false; missing = $false; rel = $rel; source = $s.liveSource } }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $target)
    if (Test-Path -LiteralPath $target) { (New-Object IO.FileInfo $target).IsReadOnly = $false }
    # Read with sharing, so a file another program has open (Excel, OneDrive) still copies.
    $in = [IO.File]::Open($fi.FullName, 'Open', 'Read', 'ReadWrite')
    try { $out = [IO.File]::Create($target); try { $in.CopyTo($out) } finally { $out.Dispose() } } finally { $in.Dispose() }
    try { Sync-SourceVault $ProjectRoot } catch { Write-CCBLog info setup "source vault: $($_.Exception.Message)" }
    $null = Save-ProjectSetup $ProjectRoot @{ liveStamp = $stamp }
    Write-CCBLog info setup 'Live data file copied' @{ bytes = $fi.Length }
    @{ changed = $true; missing = $false; rel = $rel; source = $s.liveSource }
}

function Get-DataBlockText {
    <# The content of a one-file page's data block: window.GLOBAL = rows; from the converted file of
       its source (DataImport manifest). @{ text; global; note }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)]$Block, $Manifest)
    $src = "$($Block.source)".Replace('\', '/').TrimStart('./')
    $key = @($Manifest.Keys | Where-Object { "$($Manifest[$_].source)" -ieq $src }) | Select-Object -First 1
    if (-not $key) { return @{ text = "/* no converted data for '$src': name a CSV, TSV, Excel or Source/ JSON file of this project in data-source */"; global = ''; note = "data block: no data file '$src' in the project" } }
    $it = $Manifest[$key]
    $json = Join-Path $ProjectRoot $key.Replace('/', '\')
    if ($it.status -or -not (Test-Path -LiteralPath $json)) { return @{ text = "/* $src could not be converted$(if ($it.status) { " ($($it.status))" }) */"; global = ''; note = "data block: $src could not be converted" } }
    $global = if ($Block.global) { $Block.global } elseif ($it.global) { "$($it.global)" } else { Get-DataGlobalName ([IO.Path]::GetFileNameWithoutExtension($key)) }
    # </ inside a script block would end it: written as <\/ (the same string in JavaScript).
    $data = [IO.File]::ReadAllText($json).Trim().Replace('</', '<\/')
    # When the data is from (the source file's time), for a kit-stamp with data-kit-stamp-of="GLOBAL".
    $asOf = ''
    if ("$($it.stamp)" -match '\|(\d+)$') { $asOf = "(window.kitDataAsOf = window.kitDataAsOf || {})[`"$global`"] = `"$((New-Object DateTime ([long]$Matches[1]), ([DateTimeKind]::Utc)).ToString('yyyy-MM-ddTHH:mm:ssZ'))`";`n" }
    @{ text = "`nwindow.$global = $data;`n$asOf"; global = $global; note = '' }
}

function Get-KitBlockTexts {
    <# The UI kit for a one-file page: @{ css; js; parts } from the project's kit catalogue - the
       tokens (the project's own styles/kit/tokens.css) and the rules of the kit classes the page and
       its kit scripts use; the kit scripts the page uses (icons, kit.js, charts, file readers) and the
       data tools when it calls them. $null without a catalogue. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$PageText)
    $cat = Join-Path $ProjectRoot (Get-UiKitCatalog).Replace('/', '\')
    $kitCss = Join-Path $cat 'kit.css'
    $page = Hide-GeneratedBlocks $PageText
    $js = New-Object System.Collections.Generic.List[string]
    $parts = New-Object System.Collections.Generic.List[string]
    $hasCat = Test-Path -LiteralPath $kitCss
    if ($hasCat) {
        $want = [ordered]@{
            'kit-icons.js'  = ($page -match 'data-kit-icon|KitIcons\.')
            'kit.js'        = ($page -match 'data-kit-(sort|pages|rows|hold|search|drop|theme|open|multi|range|filter|tip|stamp|print|menu|iconbar|avatar|slider-range|tags|board|calendar|cycle)|KitUI\.|kit-(tabs|segmented)--animated|kit-progress[^>]*aria-valuenow|aria-valuenow[^>]*kit-progress')
            'kit-charts.js' = ($page -match 'KitCharts\.|data-kit-chart')
            'kit-data.js'   = ($page -match 'KitData\.')
        }
        foreach ($name in $want.Keys) {
            if (-not $want[$name]) { continue }
            if ($name -eq 'kit-icons.js') {
                if (-not (Test-UiKitPart 'icons' $AppRoot)) { continue }
                $icons = @([regex]::Matches($page, '(?:data-kit-icon\s*=\s*|KitIcons\.svg\(\s*)["'']([a-z0-9-]+)["'']') | ForEach-Object { $_.Groups[1].Value })
                # The theme switch shows a sun or a moon.
                if ($page -match 'data-kit-theme') { $icons += 'sun', 'moon' }
                $js.Add((Get-KitIconsText $AppRoot $icons)); $parts.Add('icons'); continue
            }
            $f = Join-Path $cat $name
            if (Test-Path -LiteralPath $f) { $js.Add([IO.File]::ReadAllText($f)); $parts.Add($name) }
        }
    }
    if ($page -match '\bDataTools\.') {
        $tools = @((Join-Path $ProjectRoot 'data\data-tools.js'), (Join-Path $AppRoot 'templates\data\data-tools.js')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($tools) { $js.Add([IO.File]::ReadAllText($tools)); $parts.Add('data-tools.js') }
    }
    $css = ''
    if ($hasCat) {
        $tokens = @((Join-Path $ProjectRoot ((Get-UiKitFolder).Replace('/', '\') + '\tokens.css')), (Join-Path $cat 'tokens.css')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        $usage = Get-KitTextUsage (@($page) + @($js))
        $css = $(if ($tokens) { [IO.File]::ReadAllText($tokens).Trim() + "`n" } else { '' }) + (Select-KitCss ([IO.File]::ReadAllText($kitCss)) $usage -NoPrint:(-not (Test-UiKitPart 'print' $AppRoot))).Trim() + "`n" + (Get-KitSettingsCss $AppRoot $usage)
    }
    $jsText = (@($js) -join "`n;`n").Replace('</script', '<\/script')
    @{ css = $(if ($css) { "`n$css`n" } else { '' }); js = $(if ($jsText) { "`n$jsText`n" } else { '' }); parts = $parts.ToArray(); kit = $hasCat }
}

function Get-OneFilePages([string]$ProjectRoot) {
    # The project's pages with a block the helper program writes (one-file pages).
    $root = $ProjectRoot.TrimEnd('\')
    @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.html, *.htm -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.Substring($root.Length) -notmatch '(?i)\\(node_modules|dist|build|\.git|\.streamhub|Source|styles\\kit)\\' -and $_.Length -lt 100MB } |
        ForEach-Object { $_.FullName } | Where-Object {
            $sr = New-Object IO.StreamReader($_)
            try { $found = $false; while (-not $sr.EndOfStream -and -not $found) { if ($sr.ReadLine() -match 'data-streamhub') { $found = $true } }; $found } finally { $sr.Dispose() }
        })
}

function Update-OneFilePages {
    <# Fills the blocks of every one-file page (Get-OneFilePages) with the current UI kit and data and
       writes a page when that changed. Earlier versions go into one change set. Returns
       @{ files = @(rel); notes = @(); checkpoint; items = @(@{ path; old; new }) }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$AppRoot, $Checkpoint = $null, [switch]$NoCheckpoint)
    $root = $ProjectRoot.TrimEnd('\')
    $cp = $Checkpoint
    $files = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]
    $items = New-Object System.Collections.Generic.List[object]
    $man = Read-DataImportManifest $root
    foreach ($full in @(Get-OneFilePages $root)) {
        $rel = $full.Substring($root.Length + 1).Replace('\', '/')
        $info = Read-TextFile $full
        $text = $info.Text
        $blocks = @(Get-GeneratedBlocks $text)
        if (-not $blocks.Count) { continue }
        $kit = $null
        if (@($blocks | Where-Object { $_.kind -eq 'kit' }).Count) { $kit = Get-KitBlockTexts $root $AppRoot $text }
        $sb = New-Object Text.StringBuilder
        $at = 0
        foreach ($b in $blocks) {
            [void]$sb.Append($text.Substring($at, $b.start - $at))
            $new = $b.content
            if ($b.kind -eq 'data') {
                $d = Get-DataBlockText $root $b $man
                $new = $d.text
                if ($d.note) { $notes.Add("${rel}: $($d.note)") }
            } elseif ($kit -and ($kit.kit -or $kit.js)) {
                $new = if ($b.tag -eq 'style') { $kit.css } else { $kit.js }
            }
            [void]$sb.Append($new)
            $at = $b.start + $b.length
        }
        [void]$sb.Append($text.Substring($at))
        $out = $sb.ToString()
        if ($out -ceq $text) { continue }
        if (-not $NoCheckpoint) {
            if (-not $cp) { $cp = New-Checkpoint $root 'One-file page brought up to date' }
            Save-CheckpointFile $cp $root $full
        }
        Write-TextFile $full $out $info.Bom $info.Crlf $info.Encoding
        $files.Add($rel)
        $items.Add(@{ path = $rel; old = (Hide-GeneratedBlocks $text); new = (Hide-GeneratedBlocks $out) })
    }
    if ($files.Count) { Write-CCBLog info setup 'One-file pages filled' @{ pages = $files.Count } }
    @{ files = $files.ToArray(); notes = $notes.ToArray(); checkpoint = $cp; items = $items.ToArray() }
}

function Format-ProjectSetupContext {
    <# The project-context lines for the saved setup ('' when nothing is chosen). #>
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $s = Get-ProjectSetup $ProjectRoot
    $lines = New-Object System.Collections.Generic.List[string]
    switch ($s.build) {
        'single' { $lines.Add('- Build form: one HTML file (the user chose this for the project). Everything the page needs is in that file; see the one-file rules.') }
        'modular' { $lines.Add('- Build form: separate files (the user chose this for the project): the page, its styles, scripts and data each in their own file.') }
        'copilot' { $lines.Add('- Build form: the user left it to you; keep to what the project already has.') }
    }
    if ($s.liveSource) {
        $rel = Get-LiveCopyRel $s.liveSource
        $lines.Add("- Live data: $rel is a copy of a file outside the project ($([IO.Path]::GetFileName($s.liveSource)), kept up to date by the helper program whenever it changes). Build on that data so the page follows the file; never put the outside path in the page or read the file from there.")
        if ($s.build -ne 'single') { $lines.Add("- Load it with DataTools.load(`"$rel`") (data/data-tools.js): when the user opens the page through the helper program, every load or reload reads the file as it is at that moment; opened from disk, the page reads the last converted copy.") }
    }
    if (-not $lines.Count) { return '' }
    "Project setup:`n" + ($lines -join "`n")
}

function Get-RefreshScriptText([string]$AppRoot) {
    # Scripts/Refresh-Data.ps1: the live data refresh without StreamHub running.
    $app = $AppRoot.TrimEnd('\')
    @"
<#
  Refreshes this project's live data: copies the data file outside the project (see
  .streamhub\project.json) into Source\Live\, converts it for the pages and fills the data in
  one-file pages. StreamHub does this by itself while it runs; run this script (by hand or from
  Windows Task Scheduler) to refresh the dashboard while StreamHub is closed.
  Run: powershell -NoProfile -ExecutionPolicy Bypass -File Scripts\Refresh-Data.ps1
#>
`$ErrorActionPreference = 'Stop'
`$app = '$app'
if (-not (Test-Path (Join-Path `$app 'lib\ProjectSetup.psm1'))) { throw "StreamHub was not found in `$app. Start StreamHub once from its new place to write this script again." }
Import-Module (Join-Path `$app 'lib\ProjectSetup.psm1')
`$r = Invoke-LiveRefresh -ProjectRoot (Split-Path -Parent `$PSScriptRoot) -AppRoot `$app
Write-Host `$r
"@
}

function Write-RefreshScript {
    <# Writes Scripts/Refresh-Data.ps1 (StreamHub's own, written again when it differs). Returns the
       relative path when written, '' when it was already current. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$AppRoot)
    $f = Join-Path $ProjectRoot 'Scripts\Refresh-Data.ps1'
    $text = (Get-RefreshScriptText $AppRoot).Replace("`r`n", "`n")
    $old = if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f).Replace("`r`n", "`n") } else { $null }
    if ($old -ceq $text) { return '' }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $f)
    [IO.File]::WriteAllText($f, $text.Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
    'Scripts/Refresh-Data.ps1'
}

function Invoke-LiveRefresh {
    <# The whole refresh, for Scripts/Refresh-Data.ps1: the live file into Source/Live/, the data
       import, the one-file pages. Returns a one-line summary. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$AppRoot)
    $root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\')
    $live = Sync-LiveSource $root
    if (-not $live) { return 'This project has no live data file.' }
    if ($live.missing) { return "The live data file was not found: $($live.source)" }
    $null = Update-DataImports $root -JsCopy (Test-DataCopiesOn $AppRoot) -AppRoot $AppRoot
    $pages = Update-OneFilePages $root $AppRoot -NoCheckpoint
    "Live data $(if ($live.changed) { 'refreshed' } else { 'was already current' }) from $($live.source)$(if (@($pages.files).Count) { "; pages updated: $(@($pages.files) -join ', ')" })."
}

Export-ModuleMember -Function Get-ProjectSetup, Save-ProjectSetup, Get-StatedBuild, Get-NamedOutsideFile, Test-OwnCode, Get-SetupQuestions, Test-LiveSourcePath, Get-LiveCopyRel, Sync-LiveSource,
    Get-DataBlockText, Get-KitBlockTexts, Get-OneFilePages, Update-OneFilePages, Format-ProjectSetupContext, Get-RefreshScriptText, Write-RefreshScript, Invoke-LiveRefresh
