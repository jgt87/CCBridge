# The UI kit's dashboard parts and print styles (templates/ui-kit), their settings (uiKitParts.dashboard,
# uiKitParts.print, uiKitPrintOrientation, uiKitWeekStart) and how they reach a project and Copilot.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'UiKit', 'Prompts', 'ProjectSetup') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

$kitCss = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.css'))
$kitJs = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.js'))
$charts = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit-charts.js'))
$examples = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit-examples.html'))
$rule = [IO.File]::ReadAllText((Join-Path $root 'prompts\rules\uikit.md'))

Describe 'The dashboard parts in the kit' {
    It 'has the styles, the behaviour and an example of every part' {
        foreach ($c in 'kit-drawer', 'kit-drawer__head', 'kit-drawer__title', 'kit-drawer__body', 'kit-drawer__actions', 'kit-toasts', 'kit-toast', 'kit-tip', 'kit-tip__bubble', 'kit-skeleton', 'kit-skeleton--chart',
            'kit-trend', 'kit-trend--up', 'kit-trend--good', 'kit-trend--bad', 'kit-figure__spark', 'kit-multi', 'kit-multi__panel', 'kit-range', 'kit-range__custom', 'kit-table-search', 'kit-table__total', 'kit-table--sticky-first',
            'kit-stamp', 'kit-chart__target', 'kit-print-only') {
            $kitCss | Should Match ('\.' + [regex]::Escape($c) + '\b')
        }
        foreach ($f in 'function openPanel', 'function toast', 'function setupTip', 'function setupMulti', 'function setupRange', 'data-kit-filter', 'function showStamp', 'beforeprint', 'window.KitUI') { $kitJs | Should Match ([regex]::Escape($f)) }
        foreach ($f in 'function targets', 'data.stacked === "percent"', 'targetMax(data)') { $charts | Should Match ([regex]::Escape($f)) }
        $examples | Should Match '<!-- kit-part:dashboard -->'
        $examples | Should Match '<!-- kit-part:print -->'
        $examples | Should Match 'data-kit-multi'
        $examples | Should Match '"targets":\[\{"value":3000'
        $examples | Should Match '"stacked":"percent"'
    }
    It 'names in the rule only classes the kit has' {
        foreach ($line in @($rule.Split("`n") | Where-Object { $_ -like '- Dashboard parts*' -or $_ -like '- Printing:*' })) {
            foreach ($m in [regex]::Matches($line, '(?<![\w-])kit-[a-z0-9]+(?:__[a-z0-9-]+|--[a-z0-9-]+|-[a-z0-9]+)*')) {
                $kitCss | Should Match ('\.' + [regex]::Escape($m.Value) + '\b')
            }
        }
    }
    It 'loads kit.js with every kit (tables, bars and dashboard parts need it), also with the interactive parts off' {
        Mock -ModuleName UiKit Test-UiKitPart { $Name -ne 'interactive' }
        @(& (Get-Module UiKit) { param($r) Get-UiKitFiles $r } $root) -contains 'kit.js' | Should Be $true
        $examples | Should Match '(?m)^<script src="kit.js"></script>'
    }
}

Describe 'Settings for the dashboard parts and printing' {
    It 'drops the dashboard and print lines for Copilot when the parts are off' {
        $t = & (Get-Module Prompts) { param($r) Get-PromptPart $r 'rules:uikit' } $root
        $t | Should Match '- Dashboard parts'
        $t | Should Match '- Printing:'
        Mock -ModuleName Prompts Test-UiKitPart { $Name -notin 'dashboard', 'print' }
        $t = & (Get-Module Prompts) { param($r) Get-PromptPart $r 'rules:uikit' } $root
        $t | Should Not Match '- Dashboard parts'
        $t | Should Not Match '- Printing:'
        $t | Should Match '- Tables \(styles/kit/kit\.js'
    }
    It 'leaves the examples of parts that are off out' {
        $ex = Get-KitExamplesText $examples @('base', 'charts')
        $ex | Should Not Match 'kit-part:dashboard'
        $ex | Should Not Match 'data-kit-print'
        $ex | Should Match 'kit-part:charts|data-kit-chart'
    }
    It 'puts the week start and the paper orientation into kit.css, only where they apply' {
        Mock -ModuleName UiKit Get-CCBridgeConfig { [pscustomobject]@{ uiKitWeekStart = 'sunday'; uiKitPrintOrientation = 'landscape' } }
        Mock -ModuleName UiKit Test-UiKitPart { $true }
        $usage = Get-KitTextUsage @('<div class="kit-range" data-kit-range></div>')
        $css = Get-KitSettingsCss $root $usage
        $css | Should Match ':root \{ --kit-week-start: 0; \}'
        $css | Should Match '@page \{ size: landscape; margin: 12mm; \}'
        $plain = Get-KitSettingsCss $root (Get-KitTextUsage @('<div class="kit-panel"></div>'))
        $plain | Should Not Match 'kit-week-start'
        Mock -ModuleName UiKit Get-CCBridgeConfig { [pscustomobject]@{ uiKitWeekStart = 'monday'; uiKitPrintOrientation = 'auto' } }
        $css = Get-KitSettingsCss $root $usage
        $css | Should Match '--kit-week-start: 1;'
        $css | Should Not Match '@page'
    }
    It 'leaves print styles out of a project''s kit.css when they are off' {
        $usage = Get-KitTextUsage @('<main class="kit-page"><div class="kit-panel kit-toolbar"><button class="kit-btn" data-kit-print>Print</button></div></main>')
        Select-KitCss $kitCss $usage | Should Match '@media print'
        Select-KitCss $kitCss $usage -NoPrint | Should Not Match '@media print'
    }
}

Describe 'The data stamp of a one-file page' {
    It 'gives the time of the data block''s source file to the page' {
        $p = Join-Path $env:TEMP ('ccb-stamp-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory (Join-Path $p 'data') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $p 'data\sales.json'), '[{"a":1}]')
        try {
            $ticks = (New-Object DateTime 2026, 10, 9, 8, 30, 0, ([DateTimeKind]::Utc)).Ticks
            $manifest = @{ 'data/sales.json' = [pscustomobject]@{ source = 'Source/sales.csv'; global = 'salesData'; stamp = "120|$ticks" } }
            $r = Get-DataBlockText $p @{ source = 'Source/sales.csv'; global = '' } $manifest
            $r.text | Should Match 'window\.salesData = \[\{"a":1\}\];'
            $r.text | Should Match '\(window\.kitDataAsOf = window\.kitDataAsOf \|\| \{\}\)\["salesData"\] = "2026-10-09T08:30:00Z";'
        } finally { Remove-Item $p -Recurse -Force }
    }
}
Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
