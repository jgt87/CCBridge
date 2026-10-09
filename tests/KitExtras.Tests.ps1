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
        $rule | Should Match 'Progress and status bars that are not part of a chart \(kit-progress\) are round at both ends'
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
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
