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
    <# The project's saved choices: @{ build ('' when not chosen); liveSource; liveStamp; chosenBy; chosenAt;
       answers = @{ id = value } (the setup questions answered for this project) }. #>
    $s = @{ build = ''; liveSource = ''; liveStamp = ''; chosenBy = ''; chosenAt = ''; answers = @{} }
    if (-not $ProjectRoot) { return $s }
    $f = Get-ProjectSetupPath $ProjectRoot
    if (Test-Path -LiteralPath $f) {
        try {
            $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json
            foreach ($k in @($s.Keys)) { if ($k -ne 'answers' -and $null -ne $j.$k) { $s[$k] = "$($j.$k)" } }
            if ($j.answers) { foreach ($p in @($j.answers.PSObject.Properties)) { if ("$($p.Value)" -ne '') { $s.answers[$p.Name] = "$($p.Value)" } } }
        } catch { Write-CCBLog info setup "project.json not read: $($_.Exception.Message)" }
    }
    if ($s.build -notin 'single', 'modular', 'copilot') { $s.build = '' }
    $s
}

function Save-ProjectSetup {
    <# Merges $Changes (build, liveSource, liveStamp, chosenBy, and answers = @{ id = value }, where '' forgets
       an answer) into the project's setup and saves it. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][hashtable]$Changes)
    $s = Get-ProjectSetup $ProjectRoot
    foreach ($k in $Changes.Keys) {
        if ($k -eq 'answers') {
            foreach ($a in @($Changes.answers.Keys)) { $v = "$($Changes.answers[$a])"; if ($v) { $s.answers[$a] = $v } else { $s.answers.Remove($a) } }
            continue
        }
        $s[$k] = "$($Changes[$k])"
    }
    if ($Changes.ContainsKey('build') -or $Changes.ContainsKey('liveSource') -or $Changes.ContainsKey('answers')) { $s.chosenAt = (Get-Date).ToString('s') }
    $f = Get-ProjectSetupPath $ProjectRoot
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $f)
    $o = [ordered]@{}; foreach ($k in 'build', 'liveSource', 'liveStamp', 'chosenBy', 'chosenAt') { $o[$k] = $s[$k] }
    $ans = [ordered]@{}; foreach ($a in @($s.answers.Keys | Sort-Object)) { $ans[$a] = $s.answers[$a] }
    $o.answers = $ans
    [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $o -Depth 4), (New-Object Text.UTF8Encoding($false)))
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
    <# What to ask before a request goes to Copilot: $null when nothing, else @{ questions = @(@{ id;
       question; options = @(@{ value; label; help }); multi; scope }); live (offer a data file outside
       the project); suggest (a path the request named); stated = @{ id = value } (project-scope answers
       the request states itself, to save without asking); statedTurn (the same for this request only) }.
       The build question (one file, separate files, Copilot) comes when the project has no build form
       yet, no code of its own, and the request builds a page, dashboard, report or app without saying
       how; every other question comes from the registry ($script:SetupQuestionDefs) when its trigger
       fires: a project-scope one until it is answered, a request-scope one every time. At most
       $script:MaxQuestionsPerCard per card (the rest at the next request that triggers them). #>
    param([AllowEmptyString()][string]$Text, [string[]]$Paths, $Setup, [string]$ProjectRoot = '', [string]$AppRoot = '')
    $info = Get-SetupInfo $Paths $Setup $ProjectRoot $AppRoot
    $questions = New-Object System.Collections.Generic.List[object]
    $askBuild = -not ($Setup -and $Setup.build) -and -not $info.hasCode -and "$Text" -match $script:BuildWords -and "$Text" -match $script:PageWords -and -not (Get-StatedBuild $Text)
    if ($askBuild) {
        $questions.Add(@{
            id = 'build'; question = 'How should this be built?'; multi = $false; scope = 'project'
            options = @(
                @{ value = 'single'; label = 'One file'; help = 'Everything in one HTML file (page, styles, scripts, UI kit and data), to share or post as it is.' },
                @{ value = 'modular'; label = 'Separate files'; help = 'The page, styles, scripts and data in their own files and folders, easier to grow.' },
                @{ value = 'copilot'; label = 'Let Copilot decide'; help = 'Copilot picks what fits the request.' })
        })
    }
    $t = Get-TriggeredQuestions $Text $info
    # The build form (one file, separate files) belongs to web pages: it waits while the kind of app is
    # asked, and never comes for a React app, a desktop app or a script (stated now or saved).
    $kind = if ($t.stated.ContainsKey('appkind')) { $t.stated.appkind } elseif ($Setup -and $Setup.answers -and $Setup.answers.ContainsKey('appkind')) { "$($Setup.answers.appkind)" } else { '' }
    if ($questions.Count -and (@($t.questions | Where-Object { $_.id -eq 'appkind' }).Count -or $kind -in 'react', 'desktop', 'script')) { $questions.Clear() }
    foreach ($q in @($t.questions)) { if ($questions.Count -lt $script:MaxQuestionsPerCard) { $questions.Add($q) } }
    if (-not $questions.Count -and -not @($t.stated.Keys).Count -and -not @($t.statedTurn.Keys).Count) { return $null }
    $hasData = $info.hasData -or "$Text" -match '(?i)\b(csv|tsv|excel|xlsx|spreadsheet|data ?file|sharepoint|onedrive)\b|\.(csv|tsv|xlsx|xlsm)\b'
    @{
        questions = $questions.ToArray()
        live = ($askBuild -and $hasData)
        suggest = $(if ($askBuild) { Get-NamedOutsideFile $Text } else { '' })
        stated = $t.stated
        statedTurn = $t.statedTurn
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
    $cat = Get-UiKitCatalogPath $ProjectRoot
    $kitCss = Join-Path $cat 'kit.css'
    $page = Hide-GeneratedBlocks $PageText
    $js = New-Object System.Collections.Generic.List[string]
    $parts = New-Object System.Collections.Generic.List[string]
    $hasCat = Test-Path -LiteralPath $kitCss
    if ($hasCat) {
        $want = [ordered]@{
            'kit-icons.js'  = ($page -match 'data-kit-icon|KitIcons\.')
            'kit.js'        = ($page -match 'data-kit-(sort|pages|rows|hold|search|drop|theme|open|close|multi|range|filter|tip|stamp|print|menu|iconbar|avatar|slider-range|tags|board|calendar|cycle|shell-menu|select|bulk)|KitUI\.|kit-(tabs|segmented)--animated|kit-progress[^>]*aria-valuenow|aria-valuenow[^>]*kit-progress')
            'kit-charts.js' = ($page -match 'KitCharts\.|data-kit-chart')
            'kit-data.js'   = ($page -match 'KitData\.')
            # SQL in the page: the engine first, then the kit's helper (Python needs a served page, so not here).
            'vendor/sqljs/sql-asm.js' = ($page -match 'KitSql\.')
            'kit-sql.js'    = ($page -match 'KitSql\.')
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
    @(Get-KitScanFiles $root @('.html', '.htm') -Max 100000 |
        Where-Object { $_.FullName -notmatch '(?i)\\styles\\kit\\' -and $_.Length -lt 100MB } |
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
    <# The project-context lines for the saved setup and this request's answers ('' when nothing is chosen). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [hashtable]$TurnAnswers = @{})
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
    foreach ($l in @(Get-SetupAnswerContext $s.answers $TurnAnswers)) { $lines.Add($l) }
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

# --- The setup questions ---------------------------------------------------------------------------
# Every question is a fixed rule: a trigger on the request and the project (never on what Copilot
# thinks), the answer the request already states (then nothing is asked), the choices, and the
# context line each answer puts into every task. Project-scope questions are asked once per project
# (the answer is saved in project.json "answers"; Project setup in the Files tab forgets one);
# request-scope questions are asked whenever their trigger fires and apply to that request only.
$script:AppWords = '(?i)\b(apps?|application|applicatie|tool|program|programma|utility|scripts?)\b'
# Page words without the app words: a request for an app (kind unknown) is not a page request.
$script:PageOnlyWords = '(?i)\b(dashboards?|reports?|overview|web ?pages?|pages?|websites?|sites?|web ?apps?|visuali[sz]ations?|charts?|graphs?|html|rapport(age)?s?|overzicht|pagina)\b'
$script:DutchWords = '(?i)\b(een|het|maak|bouw|met|van|voor|niet|graag|pagina|overzicht|gegevens|bestand|toon|laat|nieuwe?|alle)\b'
$script:PersonalColumn = '(?i)^(e-?mail|mail|phone|tel(efoon)?|mobile|mobiel|name|naam|full ?name|first ?name|last ?name|voornaam|achternaam|iban|bsn|ssn|address|adres|street|straat|postcode|zip|birth(day|date)?|geboorte(datum)?|salary|salaris)$'
$script:BigRequestChars = 600
$script:MaxQuestionsPerCard = 6

$script:SetupQuestionDefs = @(
    @{ id = 'appkind'; scope = 'project'; question = 'What kind of app is this?'
       options = @(
           @{ value = 'web'; label = 'Web pages'; help = 'HTML, CSS and JavaScript, opened from disk or served by the helper program.' },
           @{ value = 'react'; label = 'React app'; help = 'A React app; the helper program builds it in Edge, no Node.js needed.' },
           @{ value = 'desktop'; label = 'Windows desktop app'; help = 'A PowerShell window app (WPF) with the kit''s look.' },
           @{ value = 'script'; label = 'Command-line script'; help = 'PowerShell or Python without a window.' })
       trigger = { param($Text, $Info) (-not $Info.hasCode) -and $Text -match $script:BuildWords -and $Text -match $script:AppWords -and $Text -notmatch $script:PageOnlyWords }
       stated = { param($Text)
           if ($Text -match '(?i)\b(react|vite|next\.?js|tsx|jsx)\b') { 'react' }
           elseif ($Text -match '(?i)\b(wpf|winforms|desktop app|windows app|window app|gui|venster)\b') { 'desktop' }
           elseif ($Text -match '(?i)\b(scripts?|command[- ]line|cli|console app)\b') { 'script' }
           elseif ($Text -match '(?i)\b(html|web ?pages?|websites?|web ?apps?|browser)\b') { 'web' } else { '' } }
       context = { param($v) switch ($v) {
           'web' { '- App kind: web pages (HTML, CSS, JavaScript), as the web rules say.' }
           'react' { '- App kind: a React app (src/main.tsx or src/App.tsx); the helper program builds dist/ in Edge, no npm needed.' }
           'desktop' { '- App kind: a Windows desktop app in PowerShell (WPF) with the kit''s look; see the window app rules.' }
           'script' { '- App kind: a command-line script (PowerShell or Python), no interface.' } } }
    },
    @{ id = 'audience'; scope = 'project'; question = 'Who opens it, and from where?'
       options = @(
           @{ value = 'me'; label = 'Only me, from disk'; help = 'Opened from the project folder on this computer.' },
           @{ value = 'shared'; label = 'Colleagues, from SharePoint or OneDrive'; help = 'Posted in a shared folder and opened from there; nothing may depend on this computer.' },
           @{ value = 'served'; label = 'Through the helper program'; help = 'Opened with Open app while the helper program runs (local files and modules work).' })
       trigger = { param($Text, $Info) $Text -match '(?i)\b(share|sharing|shared|colleagues?|collega''?s|delen|gedeeld|everyone|other users|publish(ed)?|publiceren|intranet|post(ed)? (on|to|in) (sharepoint|onedrive|teams)|for (the|my|our) (team|colleagues|department|afdeling))\b' -and ($Info.hasPages -or $Text -match $script:PageWords -or $Text -match $script:BuildWords) }
       stated = { param($Text)
           if ($Text -match '(?i)\b(only (for )?me|just me|myself|alleen (voor )?mij)\b') { 'me' }
           elseif ($Text -match '(?i)\b(post(ed)? (on|to) (sharepoint|onedrive|teams)|shared? (via|on|through|in) (sharepoint|onedrive|teams)|publish(ed)? (on|to) (sharepoint|the intranet))\b') { 'shared' }
           elseif ($Text -match '(?i)\b(served|localhost|on a server|through the helper program)\b') { 'served' } else { '' } }
       context = { param($v) switch ($v) {
           'me' { '- Audience: only the user, opened from disk (file://): no fetch of local files, no server; data through script tags or the one-file blocks.' }
           'shared' { '- Audience: colleagues open it from a SharePoint or OneDrive folder, from disk (file://): no fetch of local files, no server, nothing that depends on this computer; one file travels best.' }
           'served' { '- Audience: opened through the helper program (served on localhost): DataTools.load, module scripts and local data files work.' } } }
    },
    @{ id = 'persist'; scope = 'project'; question = 'Where does what people enter stay?'
       options = @(
           @{ value = 'none'; label = 'View only'; help = 'Nothing is entered or saved.' },
           @{ value = 'browser'; label = 'In the browser'; help = 'localStorage, per person and per computer; lost in another browser.' },
           @{ value = 'file'; label = 'As a file'; help = 'The user downloads a JSON file and loads it again; nothing stays in the page.' })
       trigger = { param($Text, $Info) $Text -match '(?i)\b(save|saves|saving|store|remember|enter(ed|ing)?|input|forms?|tracks?|tracking|register|crud|view[- ]only|read[- ]only|invoer(en)?|opslaan|bewaren|bijhouden|formulier)\b|\b(add|edit|delete|remove) (new )?(records?|rows?|items?|entries|users?|tasks?|notes?)\b' -and ($Info.hasPages -or $Text -match $script:BuildWords) }
       stated = { param($Text)
           if ($Text -match '(?i)\b(localstorage|local storage|browser storage|in the browser)\b') { 'browser' }
           elseif ($Text -match '(?i)\b(download(s|ed)?|export(s|ed)?) (it |the data |a )?(as |to )?(a )?(json|file)\b|\bupload\b') { 'file' }
           elseif ($Text -match '(?i)\b(view[- ]only|read[- ]only|alleen (lezen|bekijken)|no (saving|input))\b') { 'none' } else { '' } }
       context = { param($v) switch ($v) {
           'none' { '- Entered data: none. The app only shows; no forms that save.' }
           'browser' { '- Entered data stays in the browser (localStorage), per person and per computer: say so in the app, and offer an export so nothing is lost.' }
           'file' { '- Entered data is saved as a file the user downloads (JSON) and loads again through a file input; nothing is kept in the page itself.' } } }
    },
    @{ id = 'm365data'; scope = 'project'; question = 'How does the app get the Microsoft 365 data?'
       options = @(
           @{ value = 'runbook'; label = 'A scheduled runbook'; help = 'The helper program runs it on a schedule and exports the data as JSON for the app.' },
           @{ value = 'file'; label = 'A file I export myself'; help = 'From Outlook, Teams or SharePoint into the project''s Source folder.' },
           @{ value = 'once'; label = 'Copilot gathers it once now'; help = 'Written as a data file in the project; the app reads that.' })
       trigger = { param($Text, $Info) $Text -match '(?i)\b(outlook|teams|sharepoint( lists?)?|onedrive|calendar|agenda|e-?mails?|mailbox|inbox|meetings?|afspraken|planner|to ?do|microsoft 365|m365|graph api)\b' -and ($Info.hasPages -or $Text -match $script:PageWords -or $Text -match $script:BuildWords) }
       stated = { param($Text)
           if ($Text -match '(?i)\b(runbook|scheduled?|every (day|week|month)|daily|weekly|elke (dag|week))\b') { 'runbook' }
           elseif ($Text -match '(?i)\b(export(ed)? (file|csv|excel)|from (a|the|an|my) (csv|excel|export)|uit (een|de) export)\b') { 'file' }
           elseif ($Text -match '(?i)\b(once|one[- ]off|eenmalig|just now)\b') { 'once' } else { '' } }
       context = { param($v) switch ($v) {
           'runbook' { '- Microsoft 365 data: a runbook gathers it (Runbooks/NAME.runbook.md with output Runbooks/Exports/NAME.json, per the runbook rules), the helper program runs it on a schedule, and the app reads that JSON. The app itself never calls Microsoft 365 (a page cannot).' }
           'file' { '- Microsoft 365 data: the user exports it into Source/ as a file; build on that file. The app itself never calls Microsoft 365.' }
           'once' { '- Microsoft 365 data: gather it once now and write it as data/NAME.json; the app reads that file and never calls Microsoft 365 itself.' } } }
    },
    @{ id = 'sampledata'; scope = 'project'; question = 'There is no data file yet. Build with what?'
       options = @(
           @{ value = 'sample'; label = 'Made-up sample data'; help = 'Clearly marked, in a data file the real one replaces.' },
           @{ value = 'wait'; label = 'Wait for my file'; help = 'I add the data file to the project first.' },
           @{ value = 'columns'; label = 'Ask me the columns'; help = 'Copilot asks what the data holds, then builds with an empty state.' })
       trigger = { param($Text, $Info) (-not $Info.hasData) -and $Text -match $script:BuildWords -and $Text -match '(?i)\b(dashboards?|reports?|charts?|graphs?|tables?|overview|rapport(age)?|overzicht|grafiek|tabel)\b' -and $Text -notmatch '(?i)\.(csv|tsv|xlsx|xlsm|json)\b' -and $Text -notmatch '(?i)\b(outlook|teams|sharepoint|onedrive|calendar|agenda|e-?mails?|meetings?)\b' }
       stated = { param($Text) if ($Text -match '(?i)\b(sample|dummy|fake|example|voorbeeld|fictieve|test)[- ]?(data|gegevens|values|rows)\b') { 'sample' } else { '' } }
       context = { param($v) switch ($v) {
           'sample' { '- Data: there is no data file yet. Use clearly made-up sample data (a note on the page says so) in a data file the real one can replace without changes to the page.' }
           'wait' { '- Data: the user adds a data file first. Build the structure to load data/NAME.json; invent nothing.' }
           'columns' { '- Data: ask the user which columns and values the data holds (one list of questions) before building, then build with an empty state until the file arrives.' } } }
    },
    @{ id = 'personal'; scope = 'project'; question = 'The data has personal details (names, contact details). Show them?'
       options = @(
           @{ value = 'show'; label = 'Show as is'; help = 'Only people allowed to see the data open the app.' },
           @{ value = 'mask'; label = 'Mask them'; help = 'Initials for names, hidden digits, no e-mail addresses.' },
           @{ value = 'aggregate'; label = 'Totals only'; help = 'Counts and totals; no row about one person.' })
       trigger = { param($Text, $Info) @($Info.columns | Where-Object { "$_" -match $script:PersonalColumn }).Count -gt 0 -and ($Info.hasPages -or $Text -match $script:PageWords -or $Text -match $script:BuildWords) }
       stated = { param($Text)
           if ($Text -match '(?i)\b(mask(ed)?|anonymi[sz]ed?|anonymous|initials|pseudonym|geanonimiseerd|initialen)\b') { 'mask' }
           elseif ($Text -match '(?i)\b(totals only|aggregate(d)?|no names|geen namen|alleen totalen)\b') { 'aggregate' } else { '' } }
       context = { param($v) switch ($v) {
           'show' { '- Personal details in the data: shown as they are (the user decided only people allowed to see them open the app).' }
           'mask' { '- Personal details in the data: masked everywhere they show: initials for names, digits hidden but the last two, no e-mail addresses or phone numbers.' }
           'aggregate' { '- Personal details in the data: never show a row about one person; counts, totals and groups only.' } } }
    },
    @{ id = 'language'; scope = 'project'; question = 'Language of the texts, numbers and dates?'
       options = @(
           @{ value = 'nl'; label = 'Dutch'; help = '1.234,56 and 10-10-2026, labels in Dutch.' },
           @{ value = 'en'; label = 'English'; help = '1,234.56 and 10 Oct 2026, labels in English.' })
       trigger = { param($Text, $Info) ([regex]::Matches($Text, $script:DutchWords).Count -ge 2) -or ($Text -match $script:BuildWords -and @($Info.columns | Where-Object { "$_" -match '(?i)(date|datum|month|maand|year|jaar)' }).Count -gt 0) }
       stated = { param($Text)
           if ($Text -match '(?i)\b(in english|english (texts?|labels)|engels(talig)?)\b') { 'en' }
           elseif ($Text -match '(?i)\b(in dutch|dutch (texts?|labels)|nederlands(talig)?|in het nederlands)\b') { 'nl' } else { '' } }
       context = { param($v) switch ($v) {
           'nl' { '- Language: texts, numbers and dates in Dutch: <html lang="nl">, 1.234,56, dates as dd-mm-yyyy, day and month names in Dutch (the kit''s format helpers follow lang).' }
           'en' { '- Language: texts, numbers and dates in English: <html lang="en">, 1,234.56, dates as 10 Oct 2026 (the kit''s format helpers follow lang).' } } }
    },
    @{ id = 'extras'; scope = 'project'; multi = $true; question = 'Extras for tables and reports?'
       options = @(
           @{ value = 'export'; label = 'Export to CSV or Excel'; help = 'A button per table (the kit''s KitData.download).' },
           @{ value = 'print'; label = 'A print view'; help = 'Fits the paper, hides buttons (the kit''s print part).' },
           @{ value = 'theme'; label = 'A light/dark switch'; help = 'In the header (data-kit-theme).' })
       trigger = { param($Text, $Info) $Info.kit -and $Text -match $script:BuildWords -and $Text -match '(?i)\b(tables?|tabel(len)?|lists?|lijst(en)?|reports?|rapport(age)?s?|overview|overzicht|dashboards?)\b' }
       stated = { param($Text)
           $v = @()
           if ($Text -match '(?i)\b(export|csv|excel|xlsx|download)\b') { $v += 'export' }
           if ($Text -match '(?i)\b(print(ing|able)?|afdrukken|pdf)\b') { $v += 'print' }
           if ($Text -match '(?i)\b(dark mode|dark theme|theme switch|light/dark|donkere? (modus|thema))\b') { $v += 'theme' }
           $v -join ',' }
       context = { param($v)
           $set = @("$v" -split ',' | Where-Object { $_ })
           if (-not $set.Count) { return '- Extras: none asked for: no export buttons, print view or theme switch unless the user asks later.' }
           $parts = @(foreach ($x in $set) { switch ($x) { 'export' { 'an export button per table (KitData.toCsv/download)' } 'print' { 'a print view (@media print, data-kit-print)' } 'theme' { 'a light/dark switch (data-kit-theme) in the header' } } })
           "- Extras the user wants: $($parts -join '; ')." }
    },
    @{ id = 'bigtask'; scope = 'project'; question = 'This is a big request. How to start?'
       options = @(
           @{ value = 'build'; label = 'Build it at once'; help = 'Copilot starts right away.' },
           @{ value = 'clarify'; label = 'Clarify first'; help = 'Copilot asks up to five questions, then plans and builds.' },
           @{ value = 'plan'; label = 'Plan first'; help = 'A plan to approve before anything is built.' })
       trigger = { param($Text, $Info) Test-BigRequest $Text }
       stated = { param($Text) if ($Text -match '(?i)\b(clarify|ask (me )?(questions|first)|vraag (eerst|door))\b') { 'clarify' } elseif ($Text -match '(?i)\b(plan first|make a plan|plan it|eerst een plan)\b') { 'plan' } elseif ($Text -match '(?i)\b(start (right away|now|at once)|no questions|just build)\b') { 'build' } else { '' } }
       context = { param($v) '' }
    },
    @{ id = 'recurring'; scope = 'request'; question = 'This sounds like recurring work.'
       options = @(
           @{ value = 'runbook'; label = 'Make it a runbook'; help = 'Repeatable and schedulable under Automation; the answer is saved each time.' },
           @{ value = 'once'; label = 'A one-off answer'; help = 'Just this time.' })
       trigger = { param($Text, $Info) $Text -match '(?i)\b(weekly|daily|monthly|every (day|week|month|monday|tuesday|wednesday|thursday|friday|morning|evening)|each (week|day|month)|wekelijks|dagelijks|maandelijks|elke (dag|week|maand|maandag|dinsdag|woensdag|donderdag|vrijdag|ochtend)|iedere (dag|week|maand))\b' -and $Text -notmatch '(?i)\brunbooks?\b' -and $Text -notmatch $script:BuildWords }
       stated = { param($Text) if ($Text -match '(?i)\b(one[- ]off|once|only now|eenmalig|alleen nu)\b') { 'once' } else { '' } }
       context = { param($v) if ($v -eq 'runbook') { '- The user wants this as a runbook (Runbooks/NAME.runbook.md per the runbook rules, with its output file), not as a one-off answer; the helper program can run it on a schedule.' } else { '' } }
       textPrefix = { param($v) if ($v -eq 'runbook') { 'Make this a runbook (a Runbooks/NAME.runbook.md per the runbook rules), not a one-off answer: ' } else { '' } }
    },
    @{ id = 'addto'; scope = 'request'; question = 'Where does the new page go?'
       options = @(
           @{ value = 'existing'; label = 'Into the existing app'; help = 'Linked from its navigation, same look and data.' },
           @{ value = 'separate'; label = 'A separate page'; help = 'Beside the existing ones, same styles and data, no navigation changes.' },
           @{ value = 'project'; label = 'A new project'; help = 'I will create one in the project list first.' })
       trigger = { param($Text, $Info) $Info.hasPages -and $Text -match '(?i)\b(new|another|extra|second|additional|nieuwe?|nog een|tweede) (page|report|dashboard|overview|view|tab|screen|pagina|rapport|overzicht|scherm)\b|\badd (a|an) (page|report|dashboard|view|tab|pagina)\b' }
       stated = { param($Text) if ($Text -match '(?i)\b(in(to)? the (existing|current) app|to the (navigation|menu)|in the same app)\b') { 'existing' } elseif ($Text -match '(?i)\b(separate page|standalone page|losse pagina|aparte pagina)\b') { 'separate' } else { '' } }
       context = { param($v) switch ($v) {
           'existing' { '- The new page goes into the existing app: linked from its navigation (the shell or header the pages share), the same styles, kit and data.' }
           'separate' { '- The new page is a separate page beside the existing ones: the same styles/kit and data, no change to the existing pages or their navigation.' } default { '' } } }
    },
    @{ id = 'rebuild'; scope = 'request'; question = 'Start over: what happens to the current files?'
       options = @(
           @{ value = 'replace'; label = 'Replace them'; help = 'The new version takes their place; the helper program keeps backups.' },
           @{ value = 'alongside'; label = 'Keep them, build v2 alongside'; help = 'In a v2/ folder; the current files stay untouched.' })
       trigger = { param($Text, $Info) $Info.hasCode -and $Text -match '(?i)\b(rebuild|redo|start (over|again|afresh|from scratch)|from scratch|begin again|scrap (it|everything|the current)|opnieuw (beginnen|bouwen|maken)|herbouw(en)?|vanaf nul)\b' }
       stated = { param($Text) if ($Text -match '(?i)\b(replace (the|all|everything)|overwrite|delete the old|vervang)\b') { 'replace' } elseif ($Text -match '(?i)\b(alongside|next to the (old|current)|keep the (old|current)|v2|new folder|naast de (oude|huidige))\b') { 'alongside' } else { '' } }
       context = { param($v) switch ($v) {
           'replace' { '- Start over: replace the existing files of the app (the helper program keeps backups); delete what the new version does not need, so no dead files stay.' }
           'alongside' { '- Start over in a new folder v2/ and leave every current file untouched; the old version keeps working.' } default { '' } } }
    }
)

function Test-BigRequest([AllowEmptyString()][string]$Text) {
    # A request large enough to clarify or plan first: long, or a whole app in one sentence.
    "$Text".Length -gt $script:BigRequestChars -or "$Text" -match '(?i)\b(build|create|make|develop|bouw|maak) (?:(?:me|us|een|an?) )*(whole|complete|full|entire|hele|volledige) (app|application|system|tool|website|applicatie|systeem)\b'
}

function Get-SetupQuestionDef([string]$Id) { @($script:SetupQuestionDefs | Where-Object { $_.id -eq $Id }) | Select-Object -First 1 }

function Get-SetupInfo {
    # What the triggers look at: the project's files, its saved setup, and the data columns.
    param([string[]]$Paths, $Setup, [string]$ProjectRoot = '', [string]$AppRoot = '')
    $columns = @()
    if ($ProjectRoot) {
        try { foreach ($it in (Read-DataImportManifest $ProjectRoot).Values) { foreach ($sh in @($it.sheets)) { foreach ($c in @($sh.columns)) { if ($c.name) { $columns += "$($c.name)" } } } } } catch { }
    }
    @{
        paths = @($Paths); setup = $Setup
        hasCode = (Test-OwnCode $Paths)
        hasPages = (@($Paths | Where-Object { $_ -match '(?i)\.html?$' -and $_ -notmatch '(?i)^(styles/kit|\.streamhub)/' }).Count -gt 0)
        hasData = (@($Paths | Where-Object { $_ -match '(?i)\.(csv|tsv|xlsx|xlsm)$' -or $_ -match '(?i)^Source/.+\.json$' }).Count -gt 0)
        columns = @($columns | Select-Object -Unique)
        kit = $(if ($AppRoot) { try { [bool](Test-UiKitOn $AppRoot) } catch { $false } } else { $false })
    }
}

function Get-TriggeredQuestions {
    <# The registry questions a request triggers, with what the request states by itself:
       @{ questions = @(@{ id; question; options; multi; scope }); stated = @{ id = value } (project scope,
       to save); statedTurn = @{ id = value } (request scope, for this turn) }. A project-scope question
       with a saved answer is never asked again. #>
    param([AllowEmptyString()][string]$Text, $Info)
    $questions = New-Object System.Collections.Generic.List[object]
    $stated = @{}; $statedTurn = @{}
    $answers = if ($Info.setup -and $Info.setup.answers) { $Info.setup.answers } else { @{} }
    foreach ($d in $script:SetupQuestionDefs) {
        if ($d.scope -eq 'project' -and $answers.ContainsKey($d.id) -and "$($answers[$d.id])" -ne '') { continue }
        if (-not (& $d.trigger "$Text" $Info)) { continue }
        $v = "$(& $d.stated "$Text")"
        if ($v) { if ($d.scope -eq 'project') { $stated[$d.id] = $v } else { $statedTurn[$d.id] = $v }; continue }
        $questions.Add(@{ id = $d.id; question = $d.question; options = @($d.options); multi = [bool]$d.multi; scope = $d.scope })
    }
    @{ questions = $questions.ToArray(); stated = $stated; statedTurn = $statedTurn }
}

function Get-SetupAnswerLabel([string]$Id, [string]$Value) {
    # "Kind of app: Web pages" for the status line and the Project setup section.
    $d = Get-SetupQuestionDef $Id
    if (-not $d) { return "${Id}: $Value" }
    $labels = @(foreach ($v in @("$Value" -split ',' | Where-Object { $_ })) { $o = @($d.options | Where-Object { $_.value -eq $v }) | Select-Object -First 1; if ($o) { $o.label } else { $v } })
    "$($d.question.TrimEnd('?')): $(if ($labels.Count) { $labels -join ', ' } else { 'none' })"
}

function Get-SetupAnswerList([string]$ProjectRoot) {
    # The saved project-scope answers with their labels, for the Project setup section.
    $s = Get-ProjectSetup $ProjectRoot
    @(foreach ($d in $script:SetupQuestionDefs) {
        if ($d.scope -ne 'project' -or -not $s.answers.ContainsKey($d.id)) { continue }
        [pscustomobject]@{ id = $d.id; question = $d.question; value = "$($s.answers[$d.id])"; label = (Get-SetupAnswerLabel $d.id "$($s.answers[$d.id])") }
    })
}

function Get-SetupAnswerContext {
    # The context lines of saved answers plus this turn's request-scope answers.
    param([hashtable]$Saved, [hashtable]$Turn)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($d in $script:SetupQuestionDefs) {
        $v = $null
        if ($Turn -and $Turn.ContainsKey($d.id)) { $v = "$($Turn[$d.id])" }
        elseif ($Saved -and $Saved.ContainsKey($d.id) -and $d.scope -eq 'project') { $v = "$($Saved[$d.id])" }
        if ($null -eq $v -or ($v -eq '' -and -not $d.multi)) { continue }
        $line = "$(& $d.context $v)"
        if ($line) { $lines.Add($line) }
    }
    $lines.ToArray()
}

function Get-SetupTextPrefix([hashtable]$Turn) {
    # Words a request-scope answer puts before the request itself (a runbook instead of a one-off answer).
    $out = ''
    foreach ($d in $script:SetupQuestionDefs) { if ($d.textPrefix -and $Turn -and $Turn.ContainsKey($d.id)) { $out += "$(& $d.textPrefix "$($Turn[$d.id])")" } }
    $out
}

Export-ModuleMember -Function Test-BigRequest, Get-SetupQuestionDef, Get-SetupInfo, Get-TriggeredQuestions, Get-SetupAnswerLabel, Get-SetupAnswerList, Get-SetupAnswerContext, Get-SetupTextPrefix,
    Get-ProjectSetup, Save-ProjectSetup, Get-StatedBuild, Get-NamedOutsideFile, Test-OwnCode, Get-SetupQuestions, Test-LiveSourcePath, Get-LiveCopyRel, Sync-LiveSource,
    Get-DataBlockText, Get-KitBlockTexts, Get-OneFilePages, Update-OneFilePages, Format-ProjectSetupContext, Get-RefreshScriptText, Write-RefreshScript, Invoke-LiveRefresh
