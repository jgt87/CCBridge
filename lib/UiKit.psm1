# The UI kit (templates/ui-kit): colour and size tokens, components and an examples page, added to a
# project the first time Copilot builds an interface there (setting uiKit). Copied, not linked: the
# files are then the project's own, and nothing in them is overwritten later.

Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

# The files of each part (Settings > UI kit). The base is always there with the kit.
$script:KitParts = [ordered]@{
    base        = @('tokens.css', 'kit.css', 'kit-examples.html')
    interactive = @('kit.js', 'LICENSE-kokonutui.txt')
    charts      = @('kit-charts.js', 'LICENSE-bklit-ui.txt')
    icons       = @('LICENSE-lucide.txt')       # kit-icons.js is written by Update-KitIcons
}
$script:ReactFiles = @{ icons = @('Icon.tsx'); interactive = @('HoldButton.tsx', 'SearchBox.tsx', 'DropZone.tsx', 'Tabs.tsx', 'Loading.tsx', 'Composer.tsx', 'CommandButton.tsx'); charts = @('Chart.tsx') }

function Get-UiKitColors([string]$AppRoot) {
    <# Setting uiKitColors: blue (default) or neutral. #>
    try { $v = "$((Get-CCBridgeConfig harness $AppRoot).uiKitColors)" } catch { $v = '' }
    if ($v -eq 'neutral') { 'neutral' } else { 'blue' }
}

function Get-UiKitParts([string]$AppRoot) {
    <# The kit parts switched on: base plus interactive / charts / react as set. #>
    @('base') + @(foreach ($p in 'interactive', 'charts', 'icons', 'react') { if (Test-UiKitPart $p $AppRoot) { $p } }) + @(if ((Get-UiKitColors $AppRoot) -eq 'blue') { 'palette' })
}

function Get-KitExamplesText([string]$Text, [string[]]$Parts) {
    <# The examples page without the sections of parts that are off (<!-- kit-part:NAME --> ... <!-- /kit-part:NAME -->). #>
    foreach ($p in 'interactive', 'charts', 'icons', 'palette') {
        if ($Parts -contains $p) { continue }
        $Text = [regex]::Replace($Text, '(?s)<!-- kit-part:' + $p + ' -->.*?<!-- /kit-part:' + $p + ' -->\r?\n?', '')
    }
    $Text
}

function Get-UiKitFolder { 'styles/kit' }

function Install-UiKit {
    <# Copies the kit files a project does not have yet into styles/kit/. Returns the project paths
       added (empty when the kit was there already). #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$AppRoot)
    $src = Join-Path $AppRoot 'templates\ui-kit'
    $dest = Join-Path $ProjectRoot (Get-UiKitFolder).Replace('/', '\')
    $added = @()
    $parts = @(Get-UiKitParts $AppRoot)
    $files = @(foreach ($p in $parts) { if ($script:KitParts.Contains($p)) { $script:KitParts[$p] } })
    # React projects also get the React versions of the parts that are on (react/).
    if ($parts -contains 'react' -and (Test-ReactProject $ProjectRoot)) {
        foreach ($p in 'interactive', 'charts', 'icons') { if ($parts -contains $p) { $files += @($script:ReactFiles[$p] | ForEach-Object { "react/$_" }) } }
    }
    foreach ($f in $files) {
        $to = Join-Path $dest $f.Replace('/', '\')
        if (Test-Path -LiteralPath $to) { continue }
        $from = Join-Path $src $f.Replace('/', '\')
        # Colours (Settings > UI kit): the neutral palette comes from its own file.
        if ($f -eq 'tokens.css' -and (Get-UiKitColors $AppRoot) -eq 'neutral') { $from = Join-Path $src 'tokens-neutral.css' }
        if (-not (Test-Path -LiteralPath $from)) { continue }
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $to)
        if ($f -eq 'kit-examples.html') { [IO.File]::WriteAllText($to, (Get-KitExamplesText ([IO.File]::ReadAllText($from)) $parts), (New-Object Text.UTF8Encoding($false))) }
        else { Copy-Item -LiteralPath $from -Destination $to }
        $added += "$(Get-UiKitFolder)/$f"
    }
    # Icons: the base set and every icon the project uses (kept up to date by Update-KitIcons).
    if ($parts -contains 'icons') {
        $ic = Update-KitIcons $ProjectRoot $AppRoot -Create
        if ($ic.written -and $ic.created) { $added += "$(Get-UiKitFolder)/kit-icons.js" }
    }
    $added
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
    $data = ($names | ForEach-Object { '  ' + (ConvertTo-Json $_ -Compress) + ': ' + (ConvertTo-Json $lib.icons[$_] -Compress) }) -join (",`n")
    $runtime = [IO.File]::ReadAllText((Join-Path $AppRoot 'templates\ui-kit\kit-icons-runtime.js'))
    $text = "/* Lucide icons $($lib.version) (ISC licence, see LICENSE-lucide.txt) for this project: the common ones and`n   every icon its pages use. Written by the helper program: use an icon (data-kit-icon=`"NAME`") and it is`n   added here; do not edit this file. */`nwindow.KitIconData = {`n$data`n};`n" + $runtime
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
    [bool]@(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -Include *.jsx, *.tsx -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(node_modules|dist|build|styles\\kit)\\' } | Select-Object -First 1).Count
}

function Test-UiKitInProject([string]$ProjectRoot) {
    Test-Path -LiteralPath (Join-Path $ProjectRoot ((Get-UiKitFolder).Replace('/', '\') + '\tokens.css'))
}

Export-ModuleMember -Function Get-LucideIcons, Find-UsedIcons, Get-IconSuggestions, Update-KitIcons, Get-UiKitColors, Get-UiKitParts, Get-KitExamplesText, Test-ReactProject, Install-UiKit, Test-UiKitInProject, Get-UiKitFolder
