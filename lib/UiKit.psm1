# The UI kit (templates/ui-kit): colour and size tokens, components and an examples page, added to a
# project the first time Copilot builds an interface there (setting uiKit). Copied, not linked: the
# files are then the project's own, and nothing in them is overwritten later.

Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

# The files of each part (Settings > UI kit). The base is always there with the kit.
$script:KitParts = [ordered]@{
    base        = @('tokens.css', 'kit.css', 'kit-examples.html', 'kit.js', 'LICENSE-kokonutui.txt')   # kit.js: tables, bars, dashboard parts
    interactive = @('kit.js', 'LICENSE-kokonutui.txt')
    charts      = @('kit-charts.js', 'LICENSE-bklit-ui.txt')
    icons       = @('LICENSE-lucide.txt')       # kit-icons.js is written by Update-KitIcons
    data        = @('kit-data.js')
    sql         = @('kit-sql.js', 'vendor/sqljs/sql-asm.js', 'vendor/sqljs/LICENSE-sqljs.txt', 'vendor/sqljs/README.txt')
    python      = @('kit-python.js', 'vendor/pyodide/pyodide.js', 'vendor/pyodide/pyodide.asm.mjs', 'vendor/pyodide/pyodide.asm.wasm', 'vendor/pyodide/python_stdlib.zip', 'vendor/pyodide/pyodide-lock.json', 'vendor/pyodide/README.txt')
    pdf         = @('vendor/pdfjs/pdf.min.js', 'vendor/pdfjs/pdf.worker.min.js', 'vendor/pdfjs/LICENSE-pdfjs.txt', 'vendor/pdfjs/README.txt')
}
$script:ReactFiles = @{ icons = @('Icon.tsx'); interactive = @('HoldButton.tsx', 'SearchBox.tsx', 'DropZone.tsx', 'Tabs.tsx', 'Loading.tsx', 'Composer.tsx', 'CommandButton.tsx'); charts = @('Chart.tsx'); data = @('useFileData.ts')
    dashboard = @('Drawer.tsx', 'Toast.tsx', 'Tip.tsx', 'MultiSelect.tsx', 'PeriodFilter.tsx', 'Stamp.tsx')
    extras = @('Menu.tsx', 'IconBar.tsx', 'Avatar.tsx', 'SliderRange.tsx', 'TagInput.tsx', 'Board.tsx', 'Calendar.tsx', 'Switch.tsx') }

function Get-UiKitColors([string]$AppRoot) {
    <# Setting uiKitColors: blue (default), neutral, or none (no colours set for the project). #>
    try { $v = "$((Get-CCBridgeConfig harness $AppRoot).uiKitColors)" } catch { $v = '' }
    if ($v -in 'neutral', 'none') { $v } else { 'blue' }
}

function Get-UiKitDarkMode([string]$AppRoot) {
    <# Setting uiKitDarkMode: light-only (default: no dark mode and no switch unless asked for),
       follow-system (dark when the computer is), switch (that plus a light/dark button). #>
    try { $v = "$((Get-CCBridgeConfig harness $AppRoot).uiKitDarkMode)" } catch { $v = '' }
    if ($v -in 'follow-system', 'switch') { $v } else { 'light-only' }
}

function Remove-DarkTokens([string]$Text) {
    <# Tokens without their dark values (light only): the @media (prefers-color-scheme: dark) block and
       the :root[data-theme="dark"] block go, and the header says how to add dark mode later. #>
    foreach ($start in @('@media (prefers-color-scheme: dark)', ':root[data-theme="dark"]')) {
        $i = $Text.IndexOf($start)
        if ($i -lt 0) { continue }
        $open = $Text.IndexOf('{', $i)
        if ($open -lt 0) { continue }
        $depth = 0; $end = -1
        for ($k = $open; $k -lt $Text.Length; $k++) {
            if ($Text[$k] -eq '{') { $depth++ } elseif ($Text[$k] -eq '}') { $depth--; if ($depth -eq 0) { $end = $k; break } }
        }
        if ($end -lt 0) { continue }
        $Text = $Text.Remove($i, $end - $i + 1)
    }
    $Text = [regex]::Replace($Text, '(?m)^  values only; the components in kit.css follow\. Light by default, dark when the computer prefers it\r?\n  \(or with data-theme="dark" on <html>; data-theme="light" keeps it light\)\.', "  values only; the components in kit.css follow. Light only (Settings > UI kit > Dark mode): the dark`n  values are in .streamhub/ui-kit/tokens.css, to copy here when the project wants a dark mode.")
    if ($Text -notmatch 'Light only \(Settings') {
        $end = $Text.IndexOf('*/')
        if ($end -ge 0) { $Text = $Text.Insert($end + 2, "`n/* Light only (Settings > UI kit > Dark mode): the dark values are in .streamhub/ui-kit/tokens.css, to copy here when the project wants a dark mode. */") }
    }
    [regex]::Replace($Text, '(\r?\n){3,}', "`n`n")
}

$script:TailwindCache = @{ root = ''; at = [datetime]::MinValue; on = $false; version = 0 }

function Get-TailwindInfo([string]$ProjectRoot) {
    <# Whether the project uses Tailwind CSS and which major version: a tailwind.config file, tailwindcss
       or @tailwindcss/* in a package.json, a stylesheet with @tailwind or @import "tailwindcss", or a page
       loading Tailwind from its CDN. @{ on; version } (4 for @import "tailwindcss", @tailwindcss/* or a
       ^4 version, else 3); cached for 15 seconds. #>
    $c = $script:TailwindCache
    if ($c.root -eq $ProjectRoot -and ((Get-Date) - $c.at).TotalSeconds -lt 15) { return @{ on = $c.on; version = $c.version } }
    $on = $false; $v4 = $false
    $skip = '\\(node_modules|\.git|\.streamhub|dist|build|out|Source)\\'
    $files = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -ErrorAction SilentlyContinue -Include 'package.json', 'tailwind.config.*', '*.css', '*.html', '*.htm' |
        Where-Object { $_.FullName -notmatch $skip -and $_.FullName -notmatch '\\styles\\kit\\' -and $_.Length -lt 1MB } | Select-Object -First 400)
    foreach ($f in $files) {
        $n = $f.Name.ToLowerInvariant()
        if ($n -like 'tailwind.config.*') { $on = $true; continue }
        $t = try { [IO.File]::ReadAllText($f.FullName) } catch { '' }
        if ($n -eq 'package.json') {
            $m = [regex]::Match($t, '"tailwindcss"\s*:\s*"[~^>=\s]*(\d+)')
            if ($m.Success) { $on = $true; if ([int]$m.Groups[1].Value -ge 4) { $v4 = $true } }
            if ($t -match '"@tailwindcss/(vite|postcss|cli|browser)"') { $on = $true; $v4 = $true }
        } elseif ($n -like '*.css') {
            if ($t -match '@import\s+["'']tailwindcss') { $on = $true; $v4 = $true }
            elseif ($t -match '@tailwind\s+(base|components|utilities)') { $on = $true }
        } elseif ($t -match 'cdn\.tailwindcss\.com') { $on = $true }
        elseif ($t -match '@tailwindcss/browser') { $on = $true; $v4 = $true }
    }
    $version = if ($on) { if ($v4) { 4 } else { 3 } } else { 0 }
    $script:TailwindCache = @{ root = $ProjectRoot; at = (Get-Date); on = $on; version = $version }
    @{ on = $on; version = $version }
}

function Test-TailwindProject([string]$ProjectRoot) { [bool](Get-TailwindInfo $ProjectRoot).on }

function Update-KitTailwind {
    <# In a project that uses Tailwind (setting uiKitParts.tailwind): styles/kit/tailwind/ gets the kit's
       tokens as Tailwind names, kit-tailwind.css for Tailwind 4 or kit-preset.cjs for 3, written again when
       the kit's copy changes (a file without the helper program's header is the project's own and stays).
       Returns the paths written. #>
    param([string]$ProjectRoot, [string]$AppRoot)
    if (-not (Test-UiKitPart 'tailwind' $AppRoot)) { return @() }
    $info = Get-TailwindInfo $ProjectRoot
    if (-not $info.on) { return @() }
    $name = if ($info.version -ge 4) { 'kit-tailwind.css' } else { 'kit-preset.cjs' }
    $src = Join-Path $AppRoot "templates\ui-kit\tailwind\$name"
    if (-not (Test-Path -LiteralPath $src)) { return @() }
    $dst = Join-Path $ProjectRoot ((Get-UiKitFolder).Replace('/', '\') + "\tailwind\$name")
    $new = [IO.File]::ReadAllText($src)
    $old = if (Test-Path -LiteralPath $dst) { [IO.File]::ReadAllText($dst) } else { $null }
    if ($old -eq $new -or ($null -ne $old -and $old -notmatch 'written by the helper program')) { return @() }
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $dst)
    [IO.File]::WriteAllText($dst, $new, (New-Object Text.UTF8Encoding($false)))
    @("$(Get-UiKitFolder)/tailwind/$name")
}

function Get-TokenValues([string]$Css) {
    <# The light values of the kit's tokens (the first :root block): name (without --kit-) -> value,
       var(--kit-...) references resolved. #>
    $m = [regex]::Match($Css, '(?s):root\s*\{(.*?)\n\}')
    $map = @{}
    if (-not $m.Success) { return $map }
    foreach ($d in [regex]::Matches($m.Groups[1].Value, '--kit-([\w-]+)\s*:\s*([^;]+);')) { $map[$d.Groups[1].Value] = $d.Groups[2].Value.Trim() }
    for ($round = 0; $round -lt 4; $round++) {
        foreach ($k in @($map.Keys)) {
            $v = [regex]::Match($map[$k], '^var\(--kit-([\w-]+)\)$')
            if ($v.Success -and $map.ContainsKey($v.Groups[1].Value)) { $map[$k] = $map[$v.Groups[1].Value] }
        }
    }
    $map
}

function Get-WpfThemeText {
    <# A kit theme for window apps with the project's colours, font and corners from its tokens.css:
       the WPF theme (templates/ui-kit/wpf/KitTheme.template.xaml), or with -Template the Windows Forms
       one (winforms\KitTheme.template.ps1). #>
    param([Parameter(Mandatory)][string]$AppRoot, [AllowEmptyString()][string]$TokensCss, [string]$Template = 'wpf\KitTheme.template.xaml')
    $t = [IO.File]::ReadAllText((Join-Path $AppRoot ('templates\ui-kit\' + $Template)))
    $tok = Get-TokenValues $TokensCss
    $fallback = @{ bg = '#f5f5f6'; surface = '#ffffff'; 'surface-2' = '#edeeee'; text = '#000000'; 'text-muted' = '#5a5b5e'; border = '#d6d7d9'; 'border-strong' = '#5a5b5e'; accent = '#10069f'; 'accent-hover' = '#0e0587'; 'accent-soft' = '#e5f6fc'; 'on-accent' = '#ffffff'; ok = '#187623'; warn = '#a63b17'; error = '#c50e16'
        'chart-1' = '#10069f'; 'chart-2' = '#0089b7'; 'chart-3' = '#119d97'; 'chart-4' = '#d04a1e'; 'chart-5' = '#df1995'; 'chart-6' = '#8021a7' }
    foreach ($k in $fallback.Keys) {
        $v = "$($tok[$k])"
        if ($v -notmatch '^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$') { $v = $fallback[$k] }
        $t = $t.Replace('{{' + $k + '}}', $v)
    }
    $font = ("$($tok['font'])" -split ',')[0].Trim().Trim('"', "'")
    if (-not $font -or $font -match '^(system-ui|sans-serif)$') { $font = 'Arial' }
    $t = $t.Replace('{{font}}', $(if ($Template -match '\.ps1$') { $font.Replace("'", "''") } else { [Security.SecurityElement]::Escape($font) }))
    $px = { param($n, $d) $x = [regex]::Match("$($tok[$n])", '^(\d+(?:\.\d+)?)px$'); if ($x.Success) { $x.Groups[1].Value } else { $d } }
    $t.Replace('{{radius-lg}}', (& $px 'radius-lg' '10')).Replace('{{radius}}', (& $px 'radius' '6'))
}

function Test-PsGuiProject([string]$ProjectRoot, [switch]$Forms) {
    <# The project has a PowerShell window app: a script that loads WPF or Windows Forms, or a .xaml file
       (-Forms: a script that uses Windows Forms). #>
    $files = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -Include *.ps1, *.psm1, *.xaml, *.csproj, *.xaml.cs -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|\.streamhub|Source|styles\\kit)\\' -and $_.Name -notmatch '(?i)\.Tests\.ps1$' -and $_.Length -lt 1MB } | Select-Object -First 200)
    # A .xaml next to a C# project (a .csproj or code-behind .xaml.cs) is a C#, Avalonia or MAUI
    # window, not a PowerShell one: only its scripts count.
    $csharp = @($files | Where-Object { $_.Name -match '(?i)\.(csproj|xaml\.cs)$' }).Count -gt 0
    foreach ($f in $files) {
        if ($f.Name -match '(?i)\.(csproj|xaml\.cs)$') { continue }
        if ($f.Extension -ieq '.xaml') { if ($Forms -or $csharp) { continue } else { return $true } }
        $t = try { [IO.File]::ReadAllText($f.FullName) } catch { '' }
        if ($Forms) { if ($t -match '(?i)System\.Windows\.Forms') { return $true } else { continue } }
        if ($t -match '(?i)PresentationFramework|System\.Windows\.Forms|XamlReader|\bShow-KitWindow\b|KitWpf\.ps1') { return $true }
    }
    $false
}

function Update-KitWpf {
    <# In a project with a PowerShell window app: styles/kit/wpf/KitTheme.xaml with the project's colours
       (written again when tokens.css or the kit's template changes; a file without the helper program's
       note is the project's own and stays). Returns the paths written. #>
    param([string]$ProjectRoot, [string]$AppRoot, [switch]$NoTheme)
    if (-not (Test-PsGuiProject $ProjectRoot)) { return @() }
    $tokens = Join-Path $ProjectRoot ((Get-UiKitFolder).Replace('/', '\') + '\tokens.css')
    # The project's own colours, else those of the colour preset in Settings.
    $css = if (Test-Path -LiteralPath $tokens) { [IO.File]::ReadAllText($tokens) } else { [IO.File]::ReadAllText((Join-Path $AppRoot $(if ((Get-UiKitColors $AppRoot) -eq 'blue') { 'templates\ui-kit\tokens.css' } else { 'templates\ui-kit\tokens-neutral.css' }))) }
    $written = New-Object System.Collections.Generic.List[string]
    # The helpers always (KitWpf.ps1, copied as it is); the theme with the UI kit on (-NoTheme: off):
    # WPF, and the Windows Forms version when a script uses Windows Forms.
    $themes = @(@{ template = 'wpf\KitWpf.ps1'; rel = 'wpf/KitWpf.ps1'; copy = $true })
    if (-not $NoTheme) {
        $themes += @{ template = 'wpf\KitTheme.template.xaml'; rel = 'wpf/KitTheme.xaml' }
        if (Test-PsGuiProject $ProjectRoot -Forms) { $themes += @{ template = 'winforms\KitTheme.template.ps1'; rel = 'winforms/KitTheme.ps1' } }
    }
    foreach ($th in $themes) {
        $new = if ($th.copy) { [IO.File]::ReadAllText((Join-Path $AppRoot ('templates\ui-kit\' + $th.template))) } else { Get-WpfThemeText $AppRoot $css -Template $th.template }
        $dst = Join-Path $ProjectRoot ((Get-UiKitFolder).Replace('/', '\') + '\' + $th.rel.Replace('/', '\'))
        $old = if (Test-Path -LiteralPath $dst) { [IO.File]::ReadAllText($dst) } else { $null }
        if ($old -eq $new -or ($null -ne $old -and $old -notmatch 'written by the(\s|\r?\n\s*)helper program')) { continue }
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $dst)
        # A PowerShell file with a BOM (its text may hold non-ASCII once the font name does).
        [IO.File]::WriteAllText($dst, $new, (New-Object Text.UTF8Encoding($th.rel -match '\.ps1$')))
        $written.Add("$(Get-UiKitFolder)/$($th.rel)")
    }
    $written.ToArray()
}

function Get-UiKitParts([string]$AppRoot) {
    <# The kit parts switched on: base plus interactive / charts / icons / data / dashboard / print / pdf / react as set
       (pdf.js only with the file readers). #>
    $on = @(foreach ($p in 'interactive', 'charts', 'icons', 'data', 'sql', 'python', 'dashboard', 'extras', 'print', 'tailwind', 'pdf', 'react') { if (Test-UiKitPart $p $AppRoot) { $p } })
    if ($on -notcontains 'data') { $on = @($on | Where-Object { $_ -ne 'pdf' }) }
    @('base') + $on + @(if ((Get-UiKitColors $AppRoot) -eq 'blue') { 'palette' }) + @(if ((Get-UiKitDarkMode $AppRoot) -eq 'switch') { 'themeswitch' })
}

function Get-KitExamplesText([string]$Text, [string[]]$Parts) {
    <# The examples page without the sections of parts that are off (<!-- kit-part:NAME --> ... <!-- /kit-part:NAME -->). #>
    foreach ($p in 'interactive', 'charts', 'icons', 'data', 'sql', 'python', 'dashboard', 'extras', 'print', 'pdf', 'palette', 'themeswitch') {
        if ($Parts -contains $p) { continue }
        $Text = [regex]::Replace($Text, '(?s)<!-- kit-part:' + $p + ' -->.*?<!-- /kit-part:' + $p + ' -->\r?\n?', '')
    }
    $Text
}

function Get-UiKitFolder { 'styles/kit' }

function Get-UiKitCatalog { '.streamhub/ui-kit' }

# Files that go with a kit file: its licence (the parts adapted from other projects keep their notice).
$script:Companions = @{
    'kit.js'                         = @('LICENSE-kokonutui.txt')
    'kit-charts.js'                  = @('LICENSE-bklit-ui.txt')
    'kit-icons.js'                   = @('LICENSE-lucide.txt')
    'kit-sql.js'                     = @('vendor/sqljs/sql-asm.js', 'vendor/sqljs/LICENSE-sqljs.txt', 'vendor/sqljs/README.txt')
    'kit-python.js'                  = @('vendor/pyodide/pyodide.js', 'vendor/pyodide/pyodide.asm.mjs', 'vendor/pyodide/pyodide.asm.wasm', 'vendor/pyodide/python_stdlib.zip', 'vendor/pyodide/pyodide-lock.json', 'vendor/pyodide/README.txt')
    'vendor/pdfjs/pdf.min.js'        = @('vendor/pdfjs/LICENSE-pdfjs.txt', 'vendor/pdfjs/README.txt')
    'vendor/pdfjs/pdf.worker.min.js' = @('vendor/pdfjs/LICENSE-pdfjs.txt', 'vendor/pdfjs/README.txt')
}
# The kit's revision: raise it when the kit changes in a way projects should get (new classes, chart
# options the rules name). Update-UiKitCatalog brings an older project catalogue up to date.
$script:KitRevision = 9
$script:KitCssHeader = '/* Generated by the helper program from the UI kit (.streamhub/ui-kit/kit.css): the rules of the kit classes this project uses, nothing else.'

function Get-UiKitFiles([string]$AppRoot) {
    # The kit files of the parts that are switched on, as paths inside templates/ui-kit.
    $parts = @(Get-UiKitParts $AppRoot)
    $files = @(@(foreach ($p in $parts) { if ($script:KitParts.Contains($p)) { $script:KitParts[$p] } }) | Select-Object -Unique)
    if ($parts -contains 'react') {
        foreach ($p in 'interactive', 'charts', 'icons', 'data', 'dashboard', 'extras') { if ($parts -contains $p) { $files += @($script:ReactFiles[$p] | ForEach-Object { "react/$_" }) } }
    }
    @($files)
}

function Get-KitCatalogRevision([string]$Catalog) {
    # The kit revision a catalogue holds (VERSION.txt "Kit revision N"): 1 before revisions were written, 0 without one.
    $f = Join-Path $Catalog 'VERSION.txt'
    if (-not (Test-Path -LiteralPath $f)) { return 0 }
    $m = [regex]::Match([IO.File]::ReadAllText($f), 'Kit revision (\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    1
}

function Write-KitCatalogVersion([string]$Catalog, [string]$AppRoot, [string]$Verb) {
    $v = try { Get-CCBridgeVersion $AppRoot } catch { '' }
    [IO.File]::WriteAllText((Join-Path $Catalog 'VERSION.txt'), "UI kit from StreamHub $v, $Verb $((Get-Date).ToString('yyyy-MM-dd')). Kit revision $($script:KitRevision). The helper program takes what the pages use from here into styles/kit/.`n")
}

function Update-UiKitCatalog {
    <# A project catalogue from an older kit revision: StreamHub's kit files in .streamhub/ui-kit/
       replaced by this version's (tokens.css stays: the project's colours), and every copy in
       styles/kit/ that is still the old catalogue file unchanged is replaced too; a copy the project
       changed stays. kit.css in styles/kit follows at the next Update-UiKitProject (a whole unchanged
       copy of the old catalogue's kit.css is marked generated first, so that one follows too). Returns the
       styles/kit paths replaced. Nothing without a catalogue. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$AppRoot)
    $cat = Join-Path $ProjectRoot (Get-UiKitCatalog).Replace('/', '\')
    if (-not (Test-Path -LiteralPath $cat -PathType Container)) { return @() }
    if ((Get-KitCatalogRevision $cat) -ge $script:KitRevision) { return @() }
    $src = Join-Path $AppRoot 'templates\ui-kit'
    $kit = Join-Path $ProjectRoot (Get-UiKitFolder).Replace('/', '\')
    $parts = @(Get-UiKitParts $AppRoot)
    $utf8 = New-Object Text.UTF8Encoding($false)
    $replaced = New-Object System.Collections.Generic.List[string]
    foreach ($f in Get-UiKitFiles $AppRoot) {
        if ($f -eq 'tokens.css') { continue }
        $from = Join-Path $src $f.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $from)) { continue }
        $to = Join-Path $cat $f.Replace('/', '\')
        $old = if (Test-Path -LiteralPath $to) { [IO.File]::ReadAllText($to) } else { $null }
        $new = if ($f -eq 'kit-examples.html') { Get-KitExamplesText ([IO.File]::ReadAllText($from)) $parts } else { [IO.File]::ReadAllText($from) }
        if ($old -ne $new) {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $to)
            if ($f -eq 'kit-examples.html') { [IO.File]::WriteAllText($to, $new, $utf8) } else { Copy-Item -LiteralPath $from -Destination $to -Force }
        }
        if ($f -eq 'kit.css' -and $null -ne $old) {
            # A whole copy of the old catalogue's kit.css (from before kit.css was generated) is
            # StreamHub's, not the project's: mark it generated, so Update-UiKitProject writes it.
            $copy = Join-Path $kit 'kit.css'
            if ((Test-Path -LiteralPath $copy) -and [IO.File]::ReadAllText($copy) -eq $old) {
                [IO.File]::WriteAllText($copy, $script:KitCssHeader + " */`n" + [IO.File]::ReadAllText($from), $utf8)
                $replaced.Add("$(Get-UiKitFolder)/kit.css")
            }
            continue
        }
        if ($f -eq 'kit-examples.html' -or $null -eq $old -or $old -eq $new) { continue }
        $copy = Join-Path $kit $f.Replace('/', '\')
        if ((Test-Path -LiteralPath $copy) -and [IO.File]::ReadAllText($copy) -eq $old) {
            Copy-Item -LiteralPath $from -Destination $copy -Force
            $replaced.Add("$(Get-UiKitFolder)/$f")
        }
    }
    Write-KitCatalogVersion $cat $AppRoot 'updated'
    @($replaced)
}

function Get-KitExamplesIndex([string]$Text) {
    <# The parts of kit-examples.html with their lines: the page header and every <section>, with the
       title (its h2) and the kit classes the comment above it names. For ranged reads. #>
    $lines = "$Text".Replace("`r`n", "`n").Split("`n")
    $out = New-Object System.Collections.Generic.List[object]
    $comment = ''; $inComment = $false; $buf = ''; $cur = $null; $from = 0; $commentFrom = 0
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $l = $lines[$i]
        if (-not $cur) {
            if ($inComment -or $l -match '^\s*<!--') {
                if (-not $inComment) { $from = $i + 1 }
                $buf += ' ' + $l
                $inComment = $l -notmatch '-->'
                if (-not $inComment) { if ($buf -notmatch '<!--\s*/?kit-part:') { $comment = $buf; $commentFrom = $from }; $buf = '' }
                continue
            }
            $m = [regex]::Match($l, '^\s*<(section|header)\b([^>]*)')
            if ($m.Success) { $cur = @{ tag = $m.Groups[1].Value; id = [regex]::Match($m.Groups[2].Value, '\bid="([\w-]+)"').Groups[1].Value; start = $(if ($comment) { $commentFrom } else { $i + 1 }); title = $(if ($m.Groups[1].Value -eq 'header') { 'Page header' } else { '' }); comment = $comment } }
        }
        if ($cur) {
            if (-not $cur.title) { $h = [regex]::Match($l, '<h2[^>]*>([^<]+)</h2>'); if ($h.Success) { $cur.title = $h.Groups[1].Value.Trim() } }
            if ($l -match "</$($cur.tag)>") {
                # The classes the comment names first, then the main classes (no __ or --) the markup uses.
                $named = @([regex]::Matches($cur.comment, '(?<![\w-])kit-[a-z0-9_-]*[a-z0-9](?![\w-])(?!\.\w)') | ForEach-Object { $_.Value })
                $body = ($lines[($cur.start - 1)..$i] -join "`n")
                $inMarkup = @([regex]::Matches($body, '\bclass="([^"]*)"') | ForEach-Object { $_.Groups[1].Value -split '\s+' } | Where-Object { $_ -match '^kit-[a-z0-9-]+$' -and $_ -notmatch '__|--' -and $_ -notmatch '^kit-(h[1-3]|row|stack|small|muted|mono|prose|container)$' })
                $classes = @(@($named) + @($inMarkup) | Where-Object { $_ -ne 'kit-part' } | Select-Object -Unique -First 12)
                $out.Add([pscustomobject]@{ title = $(if ($cur.title) { $cur.title } else { $cur.id }); id = $cur.id; start = $cur.start; end = $i + 1; classes = $classes })
                $cur = $null; $comment = ''
            }
        }
    }
    $out.ToArray()
}

$script:KitFileNotes = [ordered]@{
    'kit.js'        = 'behaviour by data-kit-* attributes: sortable tables with pages and a search box, progress bars from aria-valuenow, hold to confirm, search with suggestions, file drop zone, animated tabs and choices, side panel and dialog openers, filters for several values and for a period, info tips, data-as-of stamps, a print button; KitUI.toast for confirmations'
    'kit-charts.js' = 'charts on the kit colours: bar (grouped, stacked or 100% stacked), line, area, ring, gauge, heatmap, sparkline, barlist (shares, funnels, colours by meaning); target lines; filter the page on a click; KitCharts.palette for canvas code'
    'kit-data.js'   = 'reading a file a person picks or drops: CSV, TSV, Excel, JSON, Word, PowerPoint'
    'kit-sql.js'    = 'SQL in the page: KitSql.open({ name: rows }) then db.query("SELECT ...") (SQLite; load vendor/sqljs/sql-asm.js first; works from disk)'
    'kit-python.js' = 'Python in the page: KitPython.run(code, { data }) (Pyodide, standard library only; only when the page is served)'
}

function Format-UiKitContext {
    <# What the UI kit offers in this project, for the project context of every task: where the
       catalogue is, its examples page part by part with lines (for a ranged read), its scripts and
       React parts, and which files the project uses. '' without a catalogue. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$AppRoot)
    $catRel = Get-UiKitCatalog
    $cat = Join-Path $ProjectRoot $catRel.Replace('/', '\')
    $ex = Join-Path $cat 'kit-examples.html'
    if (-not (Test-Path -LiteralPath $ex)) { return '' }
    $t = New-Object System.Collections.Generic.List[string]
    $t.Add("UI kit (this project uses it: build every interface from it first, and write your own markup or CSS only for what it does not have). The whole kit is in $catRel/ (read-only).")
    $t.Add("- $catRel/kit-examples.html has the markup of every part; read the part you need (read PATH:START-END):")
    foreach ($s in Get-KitExamplesIndex ([IO.File]::ReadAllText($ex))) {
        $t.Add("  $($s.title): lines $($s.start)-$($s.end)$(if (@($s.classes).Count) { ' (' + (@($s.classes) -join ' ') + ')' })")
    }
    $scripts = @(foreach ($k in $script:KitFileNotes.Keys) { if (Test-Path -LiteralPath (Join-Path $cat $k)) { "$k ($($script:KitFileNotes[$k]))" } })
    if (Test-UiKitPart 'icons' $AppRoot) { $scripts += 'kit-icons.js (icons: any Lucide name with <span data-kit-icon="NAME" aria-hidden="true"></span>; the helper program writes it with the icons the pages use)' }
    if ($scripts.Count) { $t.Add("- Scripts (refer to styles/kit/NAME and the helper program adds the file): " + ($scripts -join '; ')) }
    $react = @(if (Test-ReactProject $ProjectRoot) { Get-ChildItem -LiteralPath (Join-Path $cat 'react') -File -ErrorAction SilentlyContinue | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) } | Sort-Object })
    if ($react.Count) { $t.Add("- React parts (import from styles/kit/react/NAME): " + ($react -join ', ')) }
    $kit = Join-Path $ProjectRoot (Get-UiKitFolder).Replace('/', '\')
    $used = @(Get-ChildItem -LiteralPath $kit -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($kit.Length + 1).Replace('\', '/') } | Where-Object { $_ -notmatch '^LICENSE' } | Sort-Object)
    if ($used.Count) { $t.Add("- In use: $(Get-UiKitFolder)/ $($used -join ', ') (tokens.css holds this project's colours and sizes; kit.css is written by the helper program)") }
    $t -join "`n"
}

function Install-UiKit {
    <# The kit for a project: the whole kit (the parts that are on) once into its catalogue
       .streamhub/ui-kit/ (a newer kit revision replaces it through Update-UiKitCatalog),
       styles/kit/tokens.css as the project's own colours and sizes, and from then on only what the
       pages use (Update-UiKitProject). Returns the styles/kit paths added. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$AppRoot)
    $src = Join-Path $AppRoot 'templates\ui-kit'
    $cat = Join-Path $ProjectRoot (Get-UiKitCatalog).Replace('/', '\')
    $parts = @(Get-UiKitParts $AppRoot)
    $files = @(Get-UiKitFiles $AppRoot)
    foreach ($f in $files) {
        $to = Join-Path $cat $f.Replace('/', '\')
        if (Test-Path -LiteralPath $to) { continue }
        $from = Join-Path $src $f.Replace('/', '\')
        # Colours (Settings > UI kit): the neutral palette comes from its own file.
        $colors = Get-UiKitColors $AppRoot
        if ($f -eq 'tokens.css' -and $colors -in 'neutral', 'none') { $from = Join-Path $src 'tokens-neutral.css' }
        if (-not (Test-Path -LiteralPath $from)) { continue }
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $to)
        if ($f -eq 'tokens.css' -and $colors -eq 'none') {
            # No colours set: the neutral values only as a start, with a header that says they are free.
            $t = [regex]::Replace([IO.File]::ReadAllText($from), '\A/\*[\s\S]*?\*/', "/*`n  UI kit tokens, no colours set (Settings > UI kit > Colours: None): neutral starting values only,`n  so the kit's parts show. This project chooses its own colours: change any value here, or use`n  colours in the project's own CSS. Keep text readable (WCAG AA) in light and dark.`n*/")
            [IO.File]::WriteAllText($to, $t, (New-Object Text.UTF8Encoding($false)))
        }
        elseif ($f -eq 'kit-examples.html') { [IO.File]::WriteAllText($to, (Get-KitExamplesText ([IO.File]::ReadAllText($from)) $parts), (New-Object Text.UTF8Encoding($false))) }
        else { Copy-Item -LiteralPath $from -Destination $to }
    }
    $verFile = Join-Path $cat 'VERSION.txt'
    if (-not (Test-Path -LiteralPath $verFile) -and (Test-Path -LiteralPath $cat)) { Write-KitCatalogVersion $cat $AppRoot 'copied' }
    $added = @()
    # The project's own colours and sizes: copied once, then the project's to change.
    $tokens = Join-Path $ProjectRoot ((Get-UiKitFolder).Replace('/', '\') + '\tokens.css')
    $catTokens = Join-Path $cat 'tokens.css'
    if (-not (Test-Path -LiteralPath $tokens) -and (Test-Path -LiteralPath $catTokens)) {
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $tokens)
        # Light only (setting uiKitDarkMode): the project gets the tokens without their dark values.
        if ((Get-UiKitDarkMode $AppRoot) -eq 'light-only') { [IO.File]::WriteAllText($tokens, (Remove-DarkTokens ([IO.File]::ReadAllText($catTokens))), (New-Object Text.UTF8Encoding($false))) }
        else { Copy-Item -LiteralPath $catTokens -Destination $tokens }
        $added += "$(Get-UiKitFolder)/tokens.css"
    }
    $sync = Update-UiKitProject $ProjectRoot $AppRoot
    @($added) + @($sync.added)
}

function Get-RelativeHref([string]$FromDir, [string]$To) {
    # How a page in $FromDir refers to $To (both project-relative, / separated).
    # Not $to: PowerShell names ignore case, so that would be the [string] parameter $To.
    $fromParts = @("$FromDir".Split('/') | Where-Object { $_ }); $toParts = @($To.Split('/'))
    $i = 0
    while ($i -lt $fromParts.Count -and $i -lt ($toParts.Count - 1) -and $fromParts[$i] -eq $toParts[$i]) { $i++ }
    (@(for ($k = $i; $k -lt $fromParts.Count; $k++) { '..' }) + @($toParts[$i..($toParts.Count - 1)])) -join '/'
}

function Find-UnlinkedKitTokens {
    <# Pages that use the UI kit's tokens (var(--kit-...) in the page or in a stylesheet it links)
       without loading styles/kit/tokens.css: the colours and sizes then have no value. For the pages
       among $Paths and the pages that link a stylesheet among $Paths. A project that imports
       tokens.css from its code (a bundler) counts as loading it. "PAGE: ..." texts. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [string[]]$Paths)
    $root = $ProjectRoot.TrimEnd('\')
    $rels = @($Paths | ForEach-Object { "$_".Replace('\', '/') })
    if (-not @($rels | Where-Object { $_ -match '(?i)\.(html?|css|scss|less)$' }).Count) { return }
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.html, *.htm, *.css, *.scss, *.less, *.js, *.mjs, *.jsx, *.ts, *.tsx -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(node_modules|dist|build|\.git|\.streamhub)\\' -and $_.Length -lt 2MB } | Select-Object -First 3000)
    $text = @{}
    foreach ($f in $files) { $text[$f.FullName.Substring($root.Length + 1).Replace('\', '/')] = try { [IO.File]::ReadAllText($f.FullName) } catch { '' } }
    # Imported from code or another stylesheet (a bundler loads it): counts for every page.
    foreach ($k in $text.Keys) { if ($k -match '(?i)\.(m?js|jsx|tsx?|css|scss|less)$' -and $text[$k] -match '(?i)(import\s*\(?\s*|@import\s+(url\()?)\s*[''"][^''"]*tokens\.css') { return } }
    $tokens = "$(Get-UiKitFolder)/tokens.css"
    $pages = @($text.Keys | Where-Object { $_ -match '(?i)\.html?$' -and $_ -notmatch '(?i)^styles/kit/' })
    foreach ($pg in $pages) {
        $html = $text[$pg]
        $dir = if ($pg.Contains('/')) { $pg.Substring(0, $pg.LastIndexOf('/')) } else { '' }
        $links = @([regex]::Matches($html, '(?i)<link\b[^>]*\bhref\s*=\s*["'']([^"''#?]+)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notmatch '^(https?:)?//' })
        $linked = @($links | ForEach-Object {
            $parts = New-Object System.Collections.Generic.List[string]
            foreach ($s in (($(if ($_.StartsWith('/')) { '' } else { $dir }) + '/' + $_.TrimStart('/')) -split '/')) { if ($s -eq '..') { if ($parts.Count) { $parts.RemoveAt($parts.Count - 1) } } elseif ($s -and $s -ne '.') { $parts.Add($s) } }
            $parts -join '/'
        })
        $relevant = ($rels -contains $pg) -or @($linked | Where-Object { $rels -contains $_ }).Count
        if (-not $relevant) { continue }
        if (@($linked | Where-Object { $_ -match '(?i)(^|/)tokens\.css$' }).Count) { continue }
        $uses = $html -match 'var\(\s*--kit-'
        if (-not $uses) { foreach ($l in $linked) { if ($text.ContainsKey($l) -and $text[$l] -match 'var\(\s*--kit-') { $uses = $true; break } } }
        if (-not $uses) { continue }
        $href = Get-RelativeHref $dir $tokens
        "${pg}: uses the UI kit's colours and sizes (var(--kit-...)) but does not load $tokens, so they have no value: add <link rel=`"stylesheet`" href=`"$href`"> (and kit.css after it) before the page's own stylesheets"
    }
}

function Get-KitUsage([string]$ProjectRoot) {
    <# What the project's pages and code use of the kit: classes (kit-NAME; a name that ends in - or _
       is a prefix, as in "kit-btn--" + variant), and kit files they refer to (styles/kit/FILE). Kit
       scripts already in styles/kit count for classes (they add markup), not for files. #>
    $root = $ProjectRoot.TrimEnd('\')
    $kitDir = (Get-UiKitFolder)
    $classes = New-Object 'System.Collections.Generic.HashSet[string]'
    $prefixes = New-Object 'System.Collections.Generic.HashSet[string]'
    $refs = New-Object 'System.Collections.Generic.HashSet[string]'
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include *.html, *.htm, *.js, *.mjs, *.cjs, *.jsx, *.ts, *.tsx, *.vue, *.svelte, *.css, *.scss -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(node_modules|dist|build|\.git|\.streamhub)\\' -and $_.Length -lt 2MB } | Select-Object -First 3000)
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
        $inKit = $rel.StartsWith("$kitDir/", [StringComparison]::OrdinalIgnoreCase)
        if ($inKit -and $rel -match '(?i)^styles/kit/(kit\.css|tokens\.css|kit-examples\.html|vendor/)') { continue }
        $t = try { [IO.File]::ReadAllText($f.FullName) } catch { '' }
        if ($t -notmatch 'kit') { continue }
        foreach ($m in [regex]::Matches($t, '(?<![\w-])kit-[A-Za-z0-9_-]+')) {
            $v = $m.Value
            if ($v -match '[-_]$') { [void]$prefixes.Add($v) } else { [void]$classes.Add($v) }
        }
        if ($inKit) { continue }
        foreach ($m in [regex]::Matches($t, '(?i)styles/kit/([\w./-]+?)(?=["''`?#)\s;,]|$)')) { [void]$refs.Add($m.Groups[1].Value) }
    }
    @{ classes = $classes; prefixes = @($prefixes); refs = @($refs) }
}

function Get-KitTextUsage([string[]]$Texts) {
    <# The kit classes some texts use, in the form Select-KitCss takes (Get-KitUsage for one page's
       own text and the kit scripts it carries, as in a one-file page). #>
    $classes = New-Object 'System.Collections.Generic.HashSet[string]'
    $prefixes = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($t in $Texts) {
        foreach ($m in [regex]::Matches("$t", '(?<![\w-])kit-[A-Za-z0-9_-]+')) {
            $v = $m.Value
            if ($v -match '[-_]$') { [void]$prefixes.Add($v) } else { [void]$classes.Add($v) }
        }
    }
    @{ classes = $classes; prefixes = @($prefixes); refs = @() }
}

function Get-KitIconsText([string]$AppRoot, [string[]]$Names) {
    <# The text of kit-icons.js with these icons (and the base set): the icon data and the runtime. #>
    $lib = Get-LucideIcons $AppRoot
    $all = @(@($script:BaseIcons) + @($Names) | Where-Object { $_ -and $lib.icons.ContainsKey($_) } | Sort-Object -Unique)
    $data = ($all | ForEach-Object { '  ' + (ConvertTo-Json $_ -Compress) + ': ' + (ConvertTo-Json $lib.icons[$_] -Compress) }) -join (",`n")
    $runtime = [IO.File]::ReadAllText((Join-Path $AppRoot 'templates\ui-kit\kit-icons-runtime.js'))
    "/* Lucide icons $($lib.version) (ISC licence, see LICENSE-lucide.txt) for this project: the common ones and`n   every icon its pages use. Written by the helper program: use an icon (data-kit-icon=`"NAME`") and it is`n   added here; do not edit this file. */`nwindow.KitIconData = {`n$data`n};`n" + $runtime
}

function Split-CssItems([string]$Css) {
    <# Top-level parts of a stylesheet, in order: @{ type = comment | rule | at | stmt; head; body; text }.
       Comments and strings inside are skipped when matching braces. #>
    $items = New-Object System.Collections.Generic.List[object]
    $i = 0; $n = $Css.Length
    while ($i -lt $n) {
        while ($i -lt $n -and [char]::IsWhiteSpace($Css[$i])) { $i++ }
        if ($i -ge $n) { break }
        if ($Css[$i] -eq '/' -and $i + 1 -lt $n -and $Css[$i + 1] -eq '*') {
            $e = $Css.IndexOf('*/', $i + 2); if ($e -lt 0) { $e = $n - 2 }
            $items.Add(@{ type = 'comment'; text = $Css.Substring($i, $e + 2 - $i) }); $i = $e + 2; continue
        }
        $start = $i; $par = 0
        while ($i -lt $n) {
            $c = $Css[$i]
            if ($c -eq '(') { $par++ } elseif ($c -eq ')') { $par-- }
            elseif ($c -eq '"' -or $c -eq "'") { $q = $c; $i++; while ($i -lt $n -and $Css[$i] -ne $q) { if ($Css[$i] -eq '\') { $i++ }; $i++ } }
            elseif ($par -eq 0 -and ($c -eq '{' -or $c -eq ';')) { break }
            $i++
        }
        $head = $Css.Substring($start, [Math]::Min($i, $n) - $start).Trim()
        if ($i -ge $n -or $Css[$i] -eq ';') { $items.Add(@{ type = 'stmt'; text = "$head;" }); $i++; continue }
        $b = $i + 1; $i++; $depth = 1
        while ($i -lt $n -and $depth -gt 0) {
            $c = $Css[$i]
            if ($c -eq '/' -and $i + 1 -lt $n -and $Css[$i + 1] -eq '*') { $e = $Css.IndexOf('*/', $i + 2); $i = $(if ($e -lt 0) { $n } else { $e + 2 }); continue }
            if ($c -eq '"' -or $c -eq "'") { $q = $c; $i++; while ($i -lt $n -and $Css[$i] -ne $q) { if ($Css[$i] -eq '\') { $i++ }; $i++ } }
            elseif ($c -eq '{') { $depth++ } elseif ($c -eq '}') { $depth-- }
            $i++
        }
        $items.Add(@{ type = $(if ($head.StartsWith('@')) { 'at' } else { 'rule' }); head = $head; body = $Css.Substring($b, [Math]::Max(0, $i - 1 - $b)); text = $Css.Substring($start, $i - $start) })
    }
    $items.ToArray()
}

function Split-CssSelectors([string]$Head) {
    # Selectors of a list, split at commas outside parentheses.
    $out = New-Object System.Collections.Generic.List[string]
    $par = 0; $cur = New-Object Text.StringBuilder
    foreach ($ch in $Head.ToCharArray()) {
        if ($ch -eq '(') { $par++ } elseif ($ch -eq ')') { $par-- }
        if ($ch -eq ',' -and $par -eq 0) { $out.Add($cur.ToString().Trim()); [void]$cur.Clear(); continue }
        [void]$cur.Append($ch)
    }
    if ($cur.Length) { $out.Add($cur.ToString().Trim()) }
    $out.ToArray()
}

function Test-KitSelectorUsed([string]$Selector, $Usage) {
    # Every kit class in the selector is used (or starts with a used prefix).
    foreach ($m in [regex]::Matches($Selector, '\.(kit-[A-Za-z0-9_-]+)')) {
        $c = $m.Groups[1].Value
        if ($Usage.classes.Contains($c)) { continue }
        if (@($Usage.prefixes | Where-Object { $c.StartsWith($_) }).Count) { continue }
        return $false
    }
    $true
}

function Get-KitSettingsCss {
    <# What Settings > UI kit puts into a project's kit.css, for the parts its pages use: the period
       filter's first day of the week (--kit-week-start: 1 Monday, 0 Sunday; setting uiKitWeekStart)
       and the paper orientation for printing (@page; setting uiKitPrintOrientation, with print
       styles on). '' when none applies. #>
    param([string]$AppRoot, $Usage)
    $cfg = try { Get-CCBridgeConfig harness $AppRoot } catch { $null }
    $out = New-Object System.Collections.Generic.List[string]
    if ($Usage -and $Usage.classes -and $Usage.classes.Contains('kit-range')) {
        $week = if ("$($cfg.uiKitWeekStart)" -eq 'sunday') { 0 } else { 1 }
        $out.Add("/* Settings: the first day of the week for the period filter (1 Monday, 0 Sunday). */")
        $out.Add(":root { --kit-week-start: $week; }")
    }
    $o = "$($cfg.uiKitPrintOrientation)"
    if ($o -in 'landscape', 'portrait' -and (Test-UiKitPart 'print' $AppRoot)) {
        $out.Add("/* Settings: the paper orientation when the page is printed. */")
        $out.Add("@page { size: $o; margin: 12mm; }")
    }
    $out -join "`n"
}

function Select-KitCss {
    <# The kit's stylesheet with only the rules for the classes $Usage has: a selector list keeps the
       selectors whose kit classes are all used; @media and similar blocks keep their used rules;
       @keyframes stay when a kept rule names them. A comment goes with the rule after it, and a
       licence note with any rule of its section. -NoPrint (print styles switched off) leaves out
       @media print and @page. #>
    param([string]$Css, $Usage, [switch]$Inner, [switch]$NoPrint)
    $out = New-Object System.Collections.Generic.List[string]
    $frames = New-Object System.Collections.Generic.List[object]
    $note = $null; $noteOut = $false; $comment = $null
    $items = @(Split-CssItems $Css)
    for ($k = 0; $k -lt $items.Count; $k++) {
        $it = $items[$k]
        switch ($it.type) {
            'comment' {
                if ($k -eq 0 -and -not $Inner) { continue }   # the kit's own file header
                if ($it.text -match '(?i)licen[cs]e') { $note = $it.text; $noteOut = $false; $comment = $null } else { $comment = $it.text }
            }
            'stmt' { $out.Add($it.text) }
            'rule' {
                $all = @(Split-CssSelectors $it.head)
                $kept = @($all | Where-Object { Test-KitSelectorUsed $_ $Usage })
                if ($kept.Count) {
                    if ($note -and -not $noteOut) { $out.Add($note); $noteOut = $true }
                    if ($comment) { $out.Add($comment) }
                    $out.Add($(if ($kept.Count -eq $all.Count) { $it.text } else { ($kept -join ', ') + ' {' + $it.body + '}' }))
                }
                $comment = $null
            }
            'at' {
                $kf = [regex]::Match($it.head, '^@(?:-webkit-)?keyframes\s+([\w-]+)')
                if ($kf.Success) { $frames.Add(@{ name = $kf.Groups[1].Value; text = $it.text }); $comment = $null; continue }
                if ($NoPrint -and $it.head -match '^@(media\s+print\b|page\b)') { $comment = $null; continue }
                if ($it.head -match '^@(media|supports|container|layer)\b') {
                    $innerCss = Select-KitCss -Css $it.body -Usage $Usage -Inner:$true -NoPrint:$NoPrint
                    if ($innerCss.Trim()) {
                        if ($note -and -not $noteOut) { $out.Add($note); $noteOut = $true }
                        $out.Add("$($it.head) { $($innerCss.Trim()) }")
                    }
                } else { $out.Add($it.text) }
                $comment = $null
            }
        }
    }
    $text = $out -join "`n"
    # Kept when a kept rule names them, or a page or kit script does (an animation set from code).
    foreach ($f in $frames) { if ($Usage.classes.Contains($f.name) -or $text -match ('(?<![\w-])' + [regex]::Escape($f.name) + '(?![\w-])')) { $out.Add($f.text) } }
    $out -join "`n"
}

function Get-KitFileSource([string]$ProjectRoot, [string]$AppRoot, [string]$Name) {
    <# Where a kit file comes from: the project's catalogue (Install-UiKit puts the parts that are on
       there; a part switched on later arrives at the next interface task). A React import may leave
       out the extension. $null when the catalogue has no such file. #>
    $cat = Join-Path $ProjectRoot (Get-UiKitCatalog).Replace('/', '\')
    $names = @($Name); if ($Name -notmatch '\.\w+$') { $names = @("$Name.tsx", "$Name.ts", "$Name.js") }
    foreach ($n in $names) {
        $p = Join-Path $cat $n.Replace('/', '\')
        if (Test-Path -LiteralPath $p -PathType Leaf) { return @{ name = $n; path = $p } }
    }
    $null
}

function Get-KitFileDeps([string]$Name, [string]$Text) {
    # Kit files a kit file needs: its companions, relative imports and the licence files it names.
    $dir = if ($Name.Contains('/')) { $Name.Substring(0, $Name.LastIndexOf('/')) } else { '' }
    $deps = @($script:Companions[$Name])
    foreach ($m in [regex]::Matches($Text, '(?:\bfrom\s+|\bimport\s+)["''](\.{1,2}/[^"'']+)["'']|(?:\.\./|\./)?(LICENSE-[\w.-]+\.txt)')) {
        $ref = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Value }
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($seg in (($(if ($dir) { "$dir/" } else { '' }) + $ref) -split '/')) {
            if ($seg -eq '..') { if ($parts.Count) { $parts.RemoveAt($parts.Count - 1) } } elseif ($seg -and $seg -ne '.') { $parts.Add($seg) }
        }
        $deps += ($parts -join '/')
    }
    @($deps | Where-Object { $_ } | Select-Object -Unique)
}

function Update-UiKitProject {
    <# Brings styles/kit/ in line with what the project uses (after each change and at install):
       kit.css written from the catalogue with only the rules of the kit classes in use (when it is
       StreamHub's file: a kit.css without the Generated line is the project's own and stays), and
       every kit file a page or script refers to (styles/kit/FILE) copied with what it needs, and the
       icons the pages use (kit-icons.js). Returns @{ added; updated; unknown (icons) }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$AppRoot)
    $kit = Join-Path $ProjectRoot (Get-UiKitFolder).Replace('/', '\')
    $added = New-Object System.Collections.Generic.List[string]
    $updated = New-Object System.Collections.Generic.List[string]
    $usage = Get-KitUsage $ProjectRoot
    $queue = New-Object System.Collections.Generic.Queue[string]
    foreach ($r in $usage.refs) { $queue.Enqueue($r) }
    # Files the pages refer to, with what they need (run again for what the stylesheet names).
    $seen = @{}; $wantIcons = $false
    $copyQueued = {
        while ($queue.Count) {
            $name = $queue.Dequeue()
            if ($seen.ContainsKey($name.ToLowerInvariant())) { continue }
            $seen[$name.ToLowerInvariant()] = $true
            if ($name -ieq 'kit-icons.js') { $wantIcons = $true; continue }   # written by Update-KitIcons
            if ($name -in 'kit.css', 'tokens.css', 'tokens-neutral.css', 'kit-examples.html', 'VERSION.txt') { continue }
            $src = Get-KitFileSource $ProjectRoot $AppRoot $name
            if (-not $src) { continue }
            $to = Join-Path $kit $src.name.Replace('/', '\')
            if (-not (Test-Path -LiteralPath $to)) {
                $null = New-Item -ItemType Directory -Force -Path (Split-Path $to)
                Copy-Item -LiteralPath $src.path -Destination $to
                $added.Add("$(Get-UiKitFolder)/$($src.name)")
            }
            if ($src.name -match '(?i)\.(js|ts|tsx|css)$') {
                $t = try { [IO.File]::ReadAllText($to) } catch { '' }
                foreach ($d in Get-KitFileDeps $src.name $t) { $queue.Enqueue($d) }
            } else { foreach ($d in @($script:Companions[$src.name])) { if ($d) { $queue.Enqueue($d) } } }
        }
    }
    $before = $added.Count
    . $copyQueued
    # Kit scripts just copied add markup of their own: their classes count too.
    if ($added.Count -gt $before) { $usage = Get-KitUsage $ProjectRoot }
    # The stylesheet: only the rules in use.
    $cssSrc = Get-KitFileSource $ProjectRoot $AppRoot 'kit.css'
    $cssFile = Join-Path $kit 'kit.css'
    $exists = Test-Path -LiteralPath $cssFile
    $first = if ($exists) { try { (Get-Content -LiteralPath $cssFile -TotalCount 1) } catch { '' } } else { '' }
    if ($cssSrc -and (-not $exists -or "$first".StartsWith('/* Generated by the helper program from the UI kit'))) {
        $body = (Select-KitCss ([IO.File]::ReadAllText($cssSrc.path)) $usage -NoPrint:(-not (Test-UiKitPart 'print' $AppRoot))).Trim() + "`n" + (Get-KitSettingsCss $AppRoot $usage)
        $text = $script:KitCssHeader + " Do not edit: use a kit class in a page and its rules are added after the change; change colours and sizes in tokens.css and put other rules in your own stylesheet. */`n" + $body.Trim() + "`n"
        $old = if ($exists) { [IO.File]::ReadAllText($cssFile) } else { '' }
        if ($old -ne $text) {
            $null = New-Item -ItemType Directory -Force -Path $kit
            [IO.File]::WriteAllText($cssFile, $text, (New-Object Text.UTF8Encoding($false)))
            if ($exists) { $updated.Add("$(Get-UiKitFolder)/kit.css") } else { $added.Add("$(Get-UiKitFolder)/kit.css") }
        }
        foreach ($d in Get-KitFileDeps 'kit.css' $body) { $queue.Enqueue($d) }
    }
    . $copyQueued
    # Icons: the base set and every icon the pages use, once a page uses one or loads kit-icons.js.
    $unknown = @()
    if (Test-UiKitPart 'icons' $AppRoot) {
        $create = $wantIcons -or @(Find-UsedIcons $ProjectRoot).Count -gt 0
        $ic = Update-KitIcons $ProjectRoot $AppRoot -Create:$create
        if ($ic.written) { if ($ic.created) { $added.Add("$(Get-UiKitFolder)/kit-icons.js") } else { $updated.Add("$(Get-UiKitFolder)/kit-icons.js") } }
        if ($ic.written -or (Test-Path -LiteralPath (Join-Path $kit 'kit-icons.js'))) {
            $lic = Join-Path $kit 'LICENSE-lucide.txt'
            $ls = Get-KitFileSource $ProjectRoot $AppRoot 'LICENSE-lucide.txt'
            if (-not (Test-Path -LiteralPath $lic) -and $ls) { Copy-Item -LiteralPath $ls.path -Destination $lic; $added.Add("$(Get-UiKitFolder)/LICENSE-lucide.txt") }
        }
        $unknown = @($ic.unknown)
    }
    # Tailwind (setting uiKitParts.tailwind): the kit's tokens as Tailwind names in a Tailwind project.
    foreach ($tw in @(Update-KitTailwind $ProjectRoot $AppRoot)) { $added.Add($tw) }
    # A PowerShell window app (WPF): the kit's theme with the project's colours.
    foreach ($wp in @(Update-KitWpf $ProjectRoot $AppRoot)) { $added.Add($wp) }
    @{ added = $added.ToArray(); updated = $updated.ToArray(); unknown = $unknown }
}

# Icons every project gets (common interface icons); the others come when a page uses them.
$script:BaseIcons = @('check', 'x', 'plus', 'minus', 'search', 'settings', 'trash-2', 'pencil', 'copy', 'download', 'upload', 'external-link',
    'link', 'chevron-down', 'chevron-up', 'chevron-left', 'chevron-right', 'arrow-left', 'arrow-right', 'arrow-up', 'arrow-down', 'arrow-up-down',
    'menu', 'ellipsis', 'ellipsis-vertical', 'filter', 'funnel', 'list-filter', 'calendar', 'calendar-days', 'clock', 'user', 'users', 'mail', 'bell',
    'house', 'file', 'file-text', 'folder', 'folder-open', 'info', 'circle-alert', 'triangle-alert', 'circle-check', 'circle-x', 'circle-help', 'eye',
    'eye-off', 'lock', 'lock-open', 'log-in', 'log-out', 'refresh-cw', 'rotate-ccw', 'save', 'send', 'share-2', 'star', 'heart', 'sun', 'moon',
    'loader-circle', 'chart-column', 'chart-line', 'chart-pie', 'table', 'list', 'layout-grid', 'sliders-horizontal', 'grip-vertical', 'paperclip',
    'image', 'play', 'pause', 'square', 'maximize-2', 'minimize-2', 'zoom-in', 'zoom-out', 'printer', 'globe', 'map-pin', 'phone',
    'message-square', 'tag', 'bookmark', 'flag', 'archive', 'inbox', 'database', 'server', 'cloud', 'power', 'shield', 'key', 'at-sign', 'hash',
    'percent', 'euro', 'trending-up', 'trending-down', 'activity', 'zap', 'lightbulb', 'wrench', 'panel-left', 'circle-plus', 'check-check',
    'undo-2', 'redo-2', 'history')
$script:IconCache = $null

function Get-LucideIcons([string]$AppRoot) {
    <# Every Lucide icon the kit ships: name -> the markup inside <svg> (templates/ui-kit/icons). #>
    if ($script:IconCache) { return $script:IconCache }
    $j = [IO.File]::ReadAllText((Join-Path $AppRoot 'templates\ui-kit\icons\lucide-icons.json')) | ConvertFrom-Json
    $h = @{}
    foreach ($p in $j.icons.PSObject.Properties) { $h[$p.Name] = "$($p.Value)" }
    $script:IconCache = @{ version = "$($j.version)"; icons = $h }
    $script:IconCache
}

function Find-UsedIcons([string]$ProjectRoot) {
    <# Icon names the project's pages and code use: data-kit-icon="NAME", <Icon name="NAME">, KitIcons.svg('NAME'). #>
    $names = New-Object 'System.Collections.Generic.HashSet[string]'
    $files = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -Include *.html, *.htm, *.js, *.mjs, *.jsx, *.ts, *.tsx, *.vue, *.svelte -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(node_modules|dist|build|\.git|\.streamhub|styles\\kit)\\' -and $_.Length -lt 2MB } | Select-Object -First 3000)
    foreach ($f in $files) {
        $t = try { [IO.File]::ReadAllText($f.FullName) } catch { '' }
        if ($t -notmatch 'kit-icon|<Icon|KitIcons') { continue }
        foreach ($m in [regex]::Matches($t, '(?:data-kit-icon\s*=\s*|<Icon\b[^>]*?\bname\s*=\s*|KitIcons\.svg\(\s*)["'']([a-z0-9-]+)["'']')) { [void]$names.Add($m.Groups[1].Value) }
    }
    @($names)
}

function Get-IconSuggestions([string]$Name, $Known, [int]$Max = 3) {
    <# Real icon names close to one that does not exist: the most shared words first, then the shortest. #>
    $words = @($Name.Split('-') | Where-Object { $_.Length -gt 1 })
    if (-not $words.Count) { return @() }
    $scored = foreach ($k in $Known.Keys) {
        $parts = $k.Split('-')
        # A whole shared word counts 2, a word with the same first four letters (a typo) 1.
        $score = 0
        foreach ($w in $words) {
            if ($parts -contains $w) { $score += 2 }
            elseif ($w.Length -ge 4 -and @($parts | Where-Object { $_.Length -ge 4 -and $_.Substring(0, 4) -eq $w.Substring(0, 4) }).Count) { $score += 1 }
        }
        if ($score) { [pscustomobject]@{ name = $k; score = $score } }
    }
    @($scored | Sort-Object @{ e = { $_.score }; Descending = $true }, @{ e = { $_.name.Length } } | Select-Object -First $Max | ForEach-Object { $_.name })
}

function Update-KitIcons {
    <# Writes styles/kit/kit-icons.js with the base icons and every icon the project uses, when that
       set changed (or with -Create when the file is not there). Returns @{ written; created; count;
       unknown = @(@{ name; like }) } for names Lucide does not have. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$AppRoot, [switch]$Create)
    $file = Join-Path $ProjectRoot ((Get-UiKitFolder).Replace('/', '\') + '\kit-icons.js')
    $exists = Test-Path -LiteralPath $file
    if (-not $exists -and -not $Create) { return @{ written = $false; created = $false; count = 0; unknown = @() } }
    $lib = Get-LucideIcons $AppRoot
    $used = @(Find-UsedIcons $ProjectRoot)
    $unknown = @($used | Where-Object { -not $lib.icons.ContainsKey($_) } | ForEach-Object { @{ name = $_; like = @(Get-IconSuggestions $_ $lib.icons) } })
    $names = @(@($script:BaseIcons) + $used | Where-Object { $lib.icons.ContainsKey($_) } | Sort-Object -Unique)
    $text = Get-KitIconsText $AppRoot $used
    $old = if ($exists) { [IO.File]::ReadAllText($file) } else { '' }
    $written = $false
    if ($old -ne $text) {
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $file)
        [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding($false)))
        $written = $true
    }
    @{ written = $written; created = (-not $exists -and $written); count = $names.Count; unknown = $unknown }
}

function Test-ReactProject([string]$ProjectRoot) {
    <# A React project: package.json names react, or the project has .jsx / .tsx files. #>
    $pkg = Join-Path $ProjectRoot 'package.json'
    if ((Test-Path -LiteralPath $pkg) -and ([IO.File]::ReadAllText($pkg) -match '"react"\s*:')) { return $true }
    [bool]@(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -Include *.jsx, *.tsx -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(node_modules|dist|build|styles\\kit|\.streamhub)\\' } | Select-Object -First 1).Count
}

function Test-UiKitInProject([string]$ProjectRoot) {
    Test-Path -LiteralPath (Join-Path $ProjectRoot ((Get-UiKitFolder).Replace('/', '\') + '\tokens.css'))
}

Export-ModuleMember -Function Get-TokenValues, Get-WpfThemeText, Test-PsGuiProject, Update-KitWpf, Get-TailwindInfo, Test-TailwindProject, Update-KitTailwind, Get-UiKitDarkMode, Remove-DarkTokens, Get-KitSettingsCss, Get-KitTextUsage, Get-KitIconsText, Get-KitExamplesIndex, Format-UiKitContext, Update-UiKitCatalog, Get-KitCatalogRevision, Find-UnlinkedKitTokens, Get-UiKitCatalog, Get-KitUsage, Select-KitCss, Update-UiKitProject, Get-LucideIcons, Find-UsedIcons, Get-IconSuggestions, Update-KitIcons, Get-UiKitColors, Get-UiKitParts, Get-KitExamplesText, Test-ReactProject, Install-UiKit, Test-UiKitInProject, Get-UiKitFolder
