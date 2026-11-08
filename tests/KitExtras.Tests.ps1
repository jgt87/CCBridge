# More components in the UI kit (uiKitParts.extras), Tailwind CSS (uiKitParts.tailwind), dark mode
# (uiKitDarkMode) and a look the person asks for (Test-LookRequest, rules/userlook.md).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'UiKit', 'Prompts', 'Guardrails') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

$kitCss = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.css'))
$kitJs = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.js'))
$examples = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit-examples.html'))
$rule = [IO.File]::ReadAllText((Join-Path $root 'prompts\rules\uikit.md'))
function New-TempProject { $p = Join-Path $env:TEMP ('ccb-kitx-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p -Force | Out-Null; $p }
function Add-File($p, $rel, $text) { $full = Join-Path $p $rel; New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null; [IO.File]::WriteAllText($full, $text) }

Describe 'More components' {
    It 'has the styles, the behaviour and an example of every component' {
        foreach ($c in 'kit-switch', 'kit-switch__track', 'kit-menu', 'kit-menu__list', 'kit-menu__item', 'kit-menu__item--danger', 'kit-iconbar', 'kit-iconbar__item', 'kit-avatar', 'kit-avatars', 'kit-avatars__more',
            'kit-breadcrumbs', 'kit-stepper', 'kit-stepper__step', 'kit-dl', 'kit-timeline', 'kit-timeline__item--ok', 'kit-accordion', 'kit-accordion__body', 'kit-slider', 'kit-slider-range', 'kit-tags', 'kit-tags__tag',
            'kit-board', 'kit-board__card', 'kit-calendar', 'kit-calendar__day', 'kit-bento', 'kit-bento__item--wide', 'kit-success', 'kit-success__check') {
            $kitCss | Should Match ('\.' + [regex]::Escape($c) + '\b')
        }
        foreach ($f in 'data-kit-menu', 'function setupIconbar', 'function setupAvatar', 'function setupSliderRange', 'function setupTags', 'function setupBoardCard', 'function setupCalendar', 'function setupCycle', 'calendar: function') {
            $kitJs | Should Match ([regex]::Escape($f))
        }
        $examples | Should Match '<!-- kit-part:extras -->'
        $examples | Should Match 'data-kit-calendar'
    }
    It 'keeps the kokonutui licence with the components adapted from it, and not with the kit''s own' {
        $kok = $kitCss.IndexOf('Interactive components adapted from kokonutui')
        $bk = $kitCss.IndexOf('Charts (kit-charts.js): design adapted from bklit-ui')
        foreach ($c in '.kit-switch {', '.kit-menu {', '.kit-iconbar {', '.kit-avatar {', '.kit-bento {', '.kit-success {') { $i = $kitCss.IndexOf($c); ($i -gt $kok -and $i -lt $bk) | Should Be $true }
        foreach ($c in '.kit-accordion {', '.kit-board {', '.kit-calendar__grid {', '.kit-drawer {') { $kitCss.IndexOf($c) -lt $kok | Should Be $true }
    }
    It 'names in the rule only classes the kit has, and drops the line with the part off' {
        $line = @($rule.Split("`n") | Where-Object { $_ -like '- More components*' })[0]
        foreach ($m in [regex]::Matches($line, '(?<![\w-])kit-[a-z0-9]+(?:__[a-z0-9-]+|--[a-z0-9-]+|-[a-z0-9]+)*')) { $kitCss | Should Match ('\.' + [regex]::Escape($m.Value) + '\b') }
        Mock -ModuleName Prompts Test-UiKitPart { $Name -ne 'extras' }
        (& (Get-Module Prompts) { param($r) Get-PromptPart $r 'rules:uikit' @{} } $root) | Should Not Match '- More components'
    }
    It 'gives React projects the React versions by part' {
        foreach ($f in 'Drawer', 'Toast', 'Tip', 'MultiSelect', 'PeriodFilter', 'Stamp', 'Menu', 'IconBar', 'Avatar', 'SliderRange', 'TagInput', 'Board', 'Calendar', 'Switch') {
            Test-Path (Join-Path $root "templates\ui-kit\react\$f.tsx") | Should Be $true
        }
        $files = @(& (Get-Module UiKit) { param($r) Get-UiKitFiles $r } $root)
        $files -contains 'react/Calendar.tsx' | Should Be $true
        $files -contains 'react/Drawer.tsx' | Should Be $true
    }
}

Describe 'Status bars and chart bars' {
    It 'rounds a progress or status bar at both ends' {
        [regex]::Match($kitCss, '\.kit-progress \{[^}]*\}').Value | Should Match 'border-radius: 999px;'
        $rule | Should Match 'Bars in a track \(progress and status bars, bar lists'
    }
}

Describe 'Tailwind CSS' {
    It 'finds a project that uses Tailwind, and its version' {
        $p = New-TempProject
        try {
            (Get-TailwindInfo $p).on | Should Be $false
            Add-File $p 'package.json' '{ "devDependencies": { "tailwindcss": "^3.4.1" } }'
            $script:x = & (Get-Module UiKit) { $script:TailwindCache = @{ root = ''; at = [datetime]::MinValue; on = $false; version = 0 } }
            $i = Get-TailwindInfo $p
            $i.on | Should Be $true
            $i.version | Should Be 3
            Add-File $p 'src\index.css' '@import "tailwindcss";'
            & (Get-Module UiKit) { $script:TailwindCache = @{ root = ''; at = [datetime]::MinValue; on = $false; version = 0 } }
            (Get-TailwindInfo $p).version | Should Be 4
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'writes the kit''s names for Tailwind into styles/kit/tailwind, and leaves a project''s own file alone' {
        $p = New-TempProject
        try {
            Add-File $p 'src\app.css' '@import "tailwindcss";'
            & (Get-Module UiKit) { $script:TailwindCache = @{ root = ''; at = [datetime]::MinValue; on = $false; version = 0 } }
            @(Update-KitTailwind $p $root) | Should Be 'styles/kit/tailwind/kit-tailwind.css'
            [IO.File]::ReadAllText((Join-Path $p 'styles\kit\tailwind\kit-tailwind.css')) | Should Match '--color-kit-accent: var\(--kit-accent\);'
            @(Update-KitTailwind $p $root).Count | Should Be 0
            [IO.File]::WriteAllText((Join-Path $p 'styles\kit\tailwind\kit-tailwind.css'), '@theme { --color-kit-accent: red; }')
            @(Update-KitTailwind $p $root).Count | Should Be 0
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'sends the Tailwind line only to a Tailwind project' {
        (& (Get-Module Prompts) { param($r) Get-PromptPart $r 'rules:uikit' @{ Tailwind = $true } } $root) | Should Match '- Tailwind: this project uses Tailwind CSS'
        (& (Get-Module Prompts) { param($r) Get-PromptPart $r 'rules:uikit' @{ Tailwind = $false } } $root) | Should Not Match '- Tailwind:'
    }
    It 'reports Tailwind classes that leave the kit''s look, only what is new' {
        Find-TailwindSlop 'src/App.tsx' '' '<div className="bg-blue-500 p-4">' | Should Match "Tailwind's own colours.*bg-blue-500"
        Find-TailwindSlop 'src/App.tsx' '' '<div className="hover:bg-[#123456]">' | Should Match 'made-up colour'
        Find-TailwindSlop 'src/App.tsx' '' '<p className="text-[13px]">' | Should Match 'made-up size'
        Find-TailwindSlop 'src/App.tsx' '' '<h1 className="bg-gradient-to-r from-kit-accent bg-clip-text text-transparent">' | Should Match 'gradient text'
        Find-TailwindSlop 'src/App.tsx' '' '<div className="backdrop-blur-md">' | Should Match 'decorative blur'
        Find-TailwindSlop 'src/App.tsx' '' '<div className="bg-kit-surface text-kit-muted rounded-kit p-kit-4">' | Should BeNullOrEmpty
        Find-TailwindSlop 'src/App.tsx' '<div className="bg-blue-500">' '<div className="bg-blue-500 p-kit-2">' | Should BeNullOrEmpty
    }
}

Describe 'Dark mode in apps' {
    It 'gives a new project light-only tokens by default, with the dark values left in the catalogue' {
        Get-UiKitDarkMode $root | Should Be 'light-only'
        $t = Remove-DarkTokens ([IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\tokens.css')))
        $t | Should Not Match 'prefers-color-scheme: dark'
        $t | Should Not Match 'data-theme="dark"'
        $t | Should Match 'Light only \(Settings > UI kit > Dark mode\)'
        $t | Should Match '--kit-accent:'
    }
    It 'tells Copilot: no dark mode and no switch unless asked, and drops the switch from the header rule' {
        $u = & (Get-Module Prompts) { param($r) Get-PromptPart $r 'rules:uikit' @{} } $root
        $u | Should Match '- Light only: pages are light'
        $u | Should Not Match 'A light/dark switch is'
        (& (Get-Module Prompts) { param($r) Get-PromptPart $r 'rules:design' @{} } $root) | Should Match 'Pages are light only unless the person asks'
        $ex = Get-KitExamplesText $examples @('base', 'interactive')
        $ex | Should Not Match 'data-kit-theme aria-label'
    }
    It 'keeps the switch with the switch setting' {
        Mock -ModuleName Prompts Get-UiKitDarkMode { 'switch' }
        $u = & (Get-Module Prompts) { param($r) Get-PromptPart $r 'rules:uikit' @{} } $root
        $u | Should Match 'A light/dark switch is'
        $u | Should Not Match '- Light only'
    }
}

Describe 'A look the person asks for' {
    It 'recognises a request to change a look' {
        foreach ($t in 'Make the header blue', 'Change the buttons to rounded corners', 'Use a bigger font for the totals', 'Maak de knoppen groen', 'The table should be more compact with less padding', 'Use #ff6600 for the bars instead') { Test-LookRequest $t | Should Be $true }
        foreach ($t in 'Add a chart of sales per month', 'Fix the error in the filter', 'Why is the total wrong?', 'Show the colour field in the table') { Test-LookRequest $t | Should Be $false }
        foreach ($t in 'Change the look of the header', 'Adjust the GUI of the settings page', 'Improve the user interface of the dashboard', 'Tweak the layout of the filters', 'Pas de opmaak van de tabel aan', 'Restyle the figures') { Test-LookRequest $t | Should Be $true }
        foreach ($t in 'Update the data of the dashboard', 'Improve the performance of the filter') { Test-LookRequest $t | Should Be $false }
        # "look" as a verb (look into, look at, look up) is not a look request; the noun and "look better" are.
        foreach ($t in 'Please look into why the totals are wrong and use the new rates', 'Can you look at the export? I want it to use semicolons', 'Look up the latest rates and use them') { Test-LookRequest $t | Should Be $false }
        foreach ($t in 'Make it look more modern', 'The new look should use the kit colours') { Test-LookRequest $t | Should Be $true }
        # A plan build: only the request counts, not the plan Copilot wrote (run 7: more graphs, plan naming layout and colours).
        $plan = "Build this now, following the approved plan below. Change files with action blocks.`n`nRequest: any additional graphs you can include?`n`nApproved plan:`n1. Licence use by sector: a bar chart; adjust the layout of the chart grid and improve the colours of the legend."
        Test-LookRequest $plan | Should Be $false
        Test-LookRequest ($plan -replace 'any additional graphs you can include\?', 'Change the look of the header') | Should Be $true
        Test-LookRequest "Continue and make the change now: read what you still need.`n`nRequest: add a sector filter`n`nWhat you said you would do:`nRestyle the filter bar." | Should Be $false
    }
    It 'sends the look rule in a project with the kit, and lets the kit''s look checks rest' {
        $ids = @(Get-PromptModules 'Make the header blue' @{ Traits = @('web', 'code'); Paths = @('index.html', 'styles/kit/tokens.css') })
        $ids -contains 'rules:userlook' | Should Be $true
        @(Get-PromptModules 'Make the header blue' @{ Traits = @('web', 'code'); Paths = @('index.html') }) -contains 'rules:userlook' | Should Be $false
        $new = ".hdr { background: #ff6600; }   /* Look asked for: an orange header */"
        @(Find-QualityIssues 'css/app.css' '' $new -UseKit) -join ' ' | Should Match 'hard-coded colour'
        @(Find-QualityIssues 'css/app.css' '' $new -UseKit -UserLook) -join ' ' | Should Not Match 'hard-coded colour'
        $rule | Should Match 'Look asked for'
    }
}
Describe 'Tooltips, error states, toast buttons, context menus and the command palette' {
    It 'styles them only from the kit''s tokens, in the look of the parts they copy' {
        foreach ($c in 'kit-tooltip', 'kit-notice__actions', 'kit-toast__close', 'kit-palette') { $kitCss | Should Match ('\.' + [regex]::Escape($c) + '\b') }
        # The tooltip bubble is the info tip's bubble: the same padding, corners, border, colours, shadow and type.
        $tip = [regex]::Match($kitCss, '(?s)\.kit-tip__bubble \{(.*?)\}').Groups[1].Value
        $tooltip = [regex]::Match($kitCss, '(?s)\.kit-tooltip \{(.*?)\}').Groups[1].Value
        foreach ($d in @([regex]::Matches($tip, '(?:padding|border-radius|border|background|color|box-shadow|font-size|font-weight|line-height|max-width|z-index): [^;]+;') | ForEach-Object { $_.Value })) { $tooltip | Should Match ([regex]::Escape($d)) }
        $new = (@([regex]::Matches($kitCss, '(?s)\.(kit-tooltip|kit-notice__actions|kit-toast__close|kit-palette)\b[^{]*\{[^}]*\}') | ForEach-Object { $_.Value }) -join "`n")
        ([regex]::Matches($new, '(?<![-\w])#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(|\d+(\.\d+)?(rem|em)\b')).Count | Should Be 0
    }
    It 'adds their behaviour to kit.js, ASCII only' {
        foreach ($f in 'function setupTooltip(', 'function showTooltip(', '["[data-kit-tooltip]", setupTooltip]', 'function openContextMenu(', '"[data-kit-context]"', 'function setupPalette(', '["dialog[data-kit-palette]", setupPalette]', '"kit:command"', 'kit-toast__close', 'aria-label", "Dismiss"') {
            $kitJs | Should Match ([regex]::Escape($f))
        }
        $kitJs | Should Not Match 'btn\.setAttribute\("title"'   # the theme switch uses the kit's tooltip
        [regex]::IsMatch($kitJs, '[^\x00-\x7F]') | Should Be $false
    }
    It 'shows each in the examples page, in a section the index finds, and names them in the rule' {
        $index = @(Get-KitExamplesIndex $examples)
        foreach ($t in 'Error state', 'Tooltips', 'Toasts', 'Context menu', 'Command palette') { @($index | Where-Object { $_.title -eq $t }).Count | Should Be 1 }
        $examples | Should Match '(?s)<!-- kit-part:extras -->.*<section id="context-menu">.*<!-- /kit-part:extras -->'
        $examples | Should Match '(?s)<!-- kit-part:interactive -->.*<section id="command-palette">.*?<!-- /kit-part:interactive -->'
        $examples | Should Not Match 'class="kit-truncate"[^>]*title='
        foreach ($s in 'data-kit-tooltip="TEXT", never title', 'data-kit-context', 'data-kit-palette', 'kit-notice__actions', 'a Dismiss button', 'React: AppShell', 'React: ThemeToggle', 'CommandPalette', 'React: Tooltip') { $rule | Should Match ([regex]::Escape($s)) }
        $rule | Should Not Match 'title holds the whole'
    }
    It 'counts the classes kit.js writes for them once a page has the hook' {
        $p = New-TempProject
        try {
            Add-File $p 'styles\kit\kit.js' $kitJs
            Add-File $p 'index.html' '<button aria-label="Edit" data-kit-tooltip="Edit"></button><script src="styles/kit/kit.js"></script><script>KitUI.toast("Saved")</script>'
            Clear-KitScanCache
            $u = Get-KitUsage $p
            foreach ($c in 'kit-tooltip', 'kit-toast__close', 'kit-btn--ghost', 'kit-btn--icon', 'kit-btn--sm') { "${c}: $($u.classes.Contains($c))" | Should Be "${c}: True" }
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'gives React projects Tooltip with the basics, and ThemeToggle, AppShell and CommandPalette with the icons' {
        $files = @(& (Get-Module UiKit) { param($r) Get-UiKitFiles $r } $root)
        foreach ($f in 'Tooltip', 'ThemeToggle', 'AppShell', 'CommandPalette') {
            Test-Path (Join-Path $root "templates\ui-kit\react\$f.tsx") | Should Be $true
            $files -contains "react/$f.tsx" | Should Be $true
        }
        $react = & (Get-Module UiKit) { $script:ReactFiles }
        $react.base -contains 'Tooltip.tsx' | Should Be $true
        foreach ($f in 'ThemeToggle.tsx', 'AppShell.tsx', 'CommandPalette.tsx') { $react.icons -contains $f | Should Be $true }   # they draw with Icon
    }
    It 'gives window apps the badge, notice and switch, and themes the other Windows Forms controls' {
        $tokens = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\tokens.css'))
        $x = Get-WpfThemeText $root $tokens
        $x | Should Not Match '\{\{'
        foreach ($k in 'KitBadge', 'KitBadgeOk', 'KitBadgeWarn', 'KitBadgeError', 'KitBadgeAccent', 'KitNotice', 'KitNoticeOk', 'KitNoticeWarn', 'KitNoticeError', 'KitSwitch') { $x | Should Match ('x:Key="' + $k + '"') }
        $x | Should Match 'x:Key="KitErrorSoft" Color="#fde8e8"'
        ([xml]$x).ResourceDictionary | Should Not BeNullOrEmpty
        $f = Get-WpfThemeText $root $tokens -Template 'winforms\KitTheme.template.ps1'
        $f | Should Not Match '\{\{'
        $f | Should Match "AccentSoft = '#e5f6fc'; Ok = '#187623'; Warn = '#a63b17'; Error = '#c50e16'"
        foreach ($c in 'TreeView|ListView', 'TabControl', 'ProgressBar', 'TrackBar', 'MenuStrip|ToolStrip', 'StatusStrip', 'function Set-KitToolTipStyle', 'ContextMenuStrip') { $f | Should Match ([regex]::Escape($c)) }
        $errs = $null; $null = [Management.Automation.Language.Parser]::ParseInput($f, [ref]$null, [ref]$errs)
        @($errs).Count | Should Be 0
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
