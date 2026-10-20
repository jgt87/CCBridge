# How the UI kit reaches a project: one pruned file walk, runtime-only classes of the kit's scripts only
# for the parts a page has, icons chosen in code, keyframes by prefix, the colour guardrails, the
# contrast rules for the band and for neighbouring chart colours, and the one-file wording.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'Config', 'UiKit', 'Guardrails', 'Contrast', 'Prompts', 'ProjectSetup', 'CheckPolicy') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

function New-KitProject {
    $p = Join-Path $env:TEMP ('ccb-kitd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'node_modules\big\deep'), (Join-Path $p 'styles\kit\react'), (Join-Path $p 'src') | Out-Null
    $p
}
function Add-File($p, $rel, $text) { $full = Join-Path $p $rel; New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null; [IO.File]::WriteAllText($full, $text) }

Describe 'One pruned walk' {
    It 'never enters node_modules, build output or Source, and shares one walk while an update holds it' {
        $p = New-KitProject
        try {
            Add-File $p 'index.html' '<div class="kit-page"></div>'
            Add-File $p 'node_modules\big\deep\a.html' '<div class="kit-x"></div>'
            Add-File $p 'dist\b.html' '<div class="kit-x"></div>'
            Add-File $p 'Source\c.html' '<div class="kit-x"></div>'
            Add-File $p 'src\app.ts' 'const a = 1;'
            Clear-KitScanCache
            @(Get-KitScanFiles $p @('.html') | ForEach-Object { $_.Name }) | Should Be @('index.html')
            @(Get-KitScanFiles $p @('.ts')).Count | Should Be 1
            Add-File $p 'late.html' '<p></p>'
            @(Get-KitScanFiles $p @('.html')).Count | Should Be 2   # every call walks: a file written a moment ago counts
            Set-KitScanHold $true
            $null = Get-KitScanFiles $p @('.html')
            Add-File $p 'later.html' '<p></p>'
            @(Get-KitScanFiles $p @('.html')).Count | Should Be 2   # held during an update: one walk is shared
            Set-KitScanHold $false
            @(Get-KitScanFiles $p @('.html')).Count | Should Be 3
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'Only the rules of the parts a page has' {
    It 'counts a class the kit script writes only when the page has its part' {
        $p = New-KitProject
        try {
            Copy-Item (Join-Path $root 'templates\ui-kit\kit.js') (Join-Path $p 'styles\kit\kit.js')
            Copy-Item (Join-Path $root 'templates\ui-kit\kit-charts.js') (Join-Path $p 'styles\kit\kit-charts.js')
            Add-File $p 'index.html' '<table class="kit-table" data-kit-sort data-kit-pages="10"><tr><td class="kit-badge">x</td></tr></table><script src="styles/kit/kit.js"></script>'
            Clear-KitScanCache
            $u = Get-KitUsage $p
            foreach ($c in 'kit-table', 'kit-badge', 'kit-pager', 'kit-pager__info', 'kit-table__sort') { $u.classes.Contains($c) | Should Be $true }
            foreach ($c in 'kit-toast', 'kit-toasts', 'kit-tip__bubble', 'kit-multi__panel', 'kit-calendar__day', 'kit-chart__legend') { $u.classes.Contains($c) | Should Be $false }
            Add-File $p 'index.html' '<button data-kit-tip="Why">?</button><div data-kit-chart="bar"></div><script>KitUI.toast("hi")</script>'
            Clear-KitScanCache
            $u = Get-KitUsage $p
            foreach ($c in 'kit-tip__bubble', 'kit-toast', 'kit-chart__legend', 'kit-chart__svg') { $u.classes.Contains($c) | Should Be $true }
            $u.classes.Contains('kit-pager') | Should Be $false
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'counts the classes of a React part only when a page imports it' {
        $p = New-KitProject
        try {
            Add-File $p 'styles\kit\react\Drawer.tsx' 'export const Drawer = () => <dialog className="kit-drawer"><div className="kit-drawer__head" /></dialog>;'
            Add-File $p 'styles\kit\react\Toast.tsx' 'export const Toast = () => <div className="kit-toast" />;'
            Add-File $p 'src\App.tsx' 'import { Drawer } from "../styles/kit/react/Drawer"; export default () => <Drawer />;'
            Clear-KitScanCache
            $u = Get-KitUsage $p
            $u.classes.Contains('kit-drawer__head') | Should Be $true
            $u.classes.Contains('kit-toast') | Should Be $false
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'keeps the chart animations a page with a chart gets from kit-charts.js (keyframes named in full by the script)' {
        $p = New-KitProject
        try {
            Copy-Item (Join-Path $root 'templates\ui-kit\kit-charts.js') (Join-Path $p 'styles\kit\kit-charts.js')
            Add-File $p 'index.html' '<div class="kit-panel"><div data-kit-chart="bar"></div></div><script src="styles/kit/kit-charts.js"></script>'
            Clear-KitScanCache
            $u = Get-KitUsage $p
            foreach ($c in 'kit-grow-y', 'kit-grow-x', 'kit-draw') { $u.classes.Contains($c) | Should Be $true }
            $css = Select-KitCss ([IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.css'))) $u
            $css | Should Match '@keyframes kit-grow-y'
            $css | Should Match '@keyframes kit-draw'
            # Without a chart on the page: not kept.
            Add-File $p 'index.html' '<div class="kit-panel">x</div><script src="styles/kit/kit-charts.js"></script>'
            Clear-KitScanCache
            (Get-KitUsage $p).classes.Contains('kit-grow-y') | Should Be $false
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'keeps keyframes a script names by a prefix' {
        $css = ".kit-a { color: red; }`n@keyframes kit-grow-x { from { transform: scaleX(0); } }`n@keyframes kit-other { to { opacity: 0; } }"
        $out = Select-KitCss $css @{ classes = (New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList (, [string[]]@('kit-a'))); prefixes = @('kit-grow-') }
        $out | Should Match 'kit-grow-x'
        $out | Should Not Match 'kit-other'
    }
}

Describe 'Icons chosen in code' {
    It 'finds names set with setAttribute, dataset, data keys and JSX conditions' {
        $p = New-KitProject
        try {
            Add-File $p 'src\app.js' 'el.setAttribute("data-kit-icon", "rocket"); el.dataset.kitIcon = "anchor"; var rows = [{ icon: "bell", n: 1 }];'
            Add-File $p 'src\App.tsx' '<Icon name={ok ? "check" : "flame"} />'
            Clear-KitScanCache
            $names = @(Find-UsedIcons $p)
            foreach ($n in 'rocket', 'anchor', 'bell', 'check', 'flame') { $names -contains $n | Should Be $true }
            $known = @{ 'rocket' = 1; 'home' = 1 }
            Add-File $p 'src\more.js' 'var tabs = ["home", "settings"]; // data-kit-icon elsewhere'
            Clear-KitScanCache
            @(Find-UsedIcons $p $known) -contains 'home' | Should Be $true
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'Colour guardrails' {
    It 'leaves hex-looking ids and selectors alone, and reports colours set from code' {
        @(Find-UiSlop 'a.css' '' '#add { margin: 0; }' -UseKit | Where-Object { $_ -match 'colour' }).Count | Should Be 0
        @(Find-UiSlop 'a.js' '' 'document.querySelector("#fab").focus();' -UseKit | Where-Object { $_ -match 'colour' }).Count | Should Be 0
        @(Find-UiSlop 'a.css' '' 'h1 { color: #ff0000; }' -UseKit | Where-Object { $_ -match 'colour' }).Count | Should Be 1
        @(Find-UiSlop 'index.html' '' '<script>ctx.fillStyle = "#00ff00";</script>' -UseKit | Where-Object { $_ -match 'colour' }).Count | Should Be 1
        @(Find-UiSlop 'theme.ts' '' 'const B = styled.button`color: #ff0000;`;' -UseKit | Where-Object { $_ -match 'colour' }).Count | Should Be 1
        @(Find-UiSlop 'a.css' '' 'h1 { box-shadow: 0 2px 8px rgba(0,0,0,.2); }' -UseKit | Where-Object { $_ -match 'colour' }).Count | Should Be 0   # the shadow finding says it
    }
}

Describe 'Contrast rules of the kit' {
    It 'passes both presets, and would catch a light band or two alike chart colours' {
        foreach ($f in 'tokens.css', 'tokens-neutral.css') { @(Test-TokenContrast ([IO.File]::ReadAllText((Join-Path $root "templates\ui-kit\$f")))) | Should BeNullOrEmpty }
        $bad = ":root { --kit-on-gradient: #ffffff; --kit-gradient-from: #00a3e0; --kit-gradient-to: #10069f; --kit-chart-1: #0089b7; --kit-chart-2: #119d97; }"
        $r = @(Test-TokenContrast $bad)
        ($r -join "`n") | Should Match 'text on the band header'
        ($r -join "`n") | Should Match 'chart colours \(light\): --kit-chart-1 .* look alike'
    }
}

Describe 'The kit rule for one-file and light-only projects' {
    It 'says nothing about script tags in a one-file project, nor about dark in a light-only one' {
        Mock -ModuleName Prompts Get-UiKitDarkMode { 'light-only' }
        $r = & (Get-Module Prompts) { param($a) Get-PromptPart $a 'rules:uikit' @{ Build = 'single' } } $root
        $r | Should Not Match 'styles/kit/kit\.js after the markup'
        $r | Should Not Match '<script src="styles/kit/'
        $r | Should Not Match 'light and dark'
        $r | Should Match 'kit block'
    }
}

Describe 'One-file pages get kit.js for every hook' {
    It 'lists every data-kit hook kit.js handles' {
        $kit = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.js'))
        $hooks = @([regex]::Matches($kit, '\[data-kit-([a-z-]+)[\]=]') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $want = [IO.File]::ReadAllText((Join-Path $root 'lib\ProjectSetup.psm1'))
        $m = [regex]::Match($want, "'kit\.js'\s*=\s*\(\`$page -match 'data-kit-\(([^)]+)\)")
        $m.Success | Should Be $true
        $listed = @($m.Groups[1].Value -split '\|')
        foreach ($h in $hooks) {
            if ($h -in 'icon', 'empty', 'nosort', 'total', 'page', 'icon-drawn') { continue }
            # A listed name also covers a longer hook that starts with it (stamp covers stamp-of).
            $covered = @($listed | Where-Object { $h -eq $_ -or $h.StartsWith("$_-") }).Count -gt 0
            "${h}: $covered" | Should Be "${h}: True"
        }
    }
}

Describe 'Table header rows are one piece' {
    It 'reports a numeric column whose header and cells do not match, and a header cell styled by hand' {
        $ok = '<table class="kit-table" data-kit-sort><thead><tr><th>Name</th><th class="kit-num">Amount</th></tr></thead><tbody><tr><td>A</td><td class="kit-num">1</td></tr></tbody></table>'
        @(Find-TableHeaderIssues 'index.html' '' $ok).Count | Should Be 0
        $mixed = '<table class="kit-table" data-kit-sort><thead><tr><th>Name</th><th class="kit-num">Amount</th></tr></thead><tbody><tr><td>A</td><td>1</td></tr></tbody></table>'
        $r = @(Find-TableHeaderIssues 'index.html' '' $mixed)
        $r.Count | Should Be 1
        $r[0] | Should Match "^line 1: column 2 \('Amount'\): the header and the cells do not align the same way \(kit-num on the header but not the cells\)"
        $styled = '<table class="kit-table"><thead><tr><th style="text-align:right">Total</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>'
        @(Find-TableHeaderIssues 'app.js' '' ('el.innerHTML = `' + $styled + '`;'))[0] | Should Match 'a header cell of this table has a style of its own'
        # Markup in a script string with escaped quotes: the cells do carry kit-num.
        $escaped = 'el.innerHTML = "<table class=\"kit-table\"><thead><tr><th>Name</th><th class=\"kit-num\">Prompts</th></tr></thead><tbody>" + rows.map(function (p) { return "<tr><td>" + p.name + "</td><td class=\"kit-num\">" + p.n + "</td></tr>"; }).join("") + "</tbody></table>";'
        @(Find-TableHeaderIssues 'dashboard.js' '' $escaped).Count | Should Be 0
        @(Find-TableHeaderIssues 'index.html' $mixed $mixed).Count | Should Be 0   # already there: not the change's doing
        Get-CheckLevel $r[0] 'quality' | Should Be 'warning'
    }
}

Describe 'A project from an older kit gets the new tokens' {
    It 'adds missing tokens, updates untouched defaults and keeps the project''s own values, block by block' {
        $old = ":root {`n  --kit-accent: #10069f;`n  --kit-focus: 0 0 0 3px rgba(0, 163, 224, 0.45);`n  --kit-chart-1: #10069f;`n}`n@media (prefers-color-scheme: dark) {`n  :root:not([data-theme=`"light`"]) {`n    --kit-accent: #00a3e0;`n    --kit-focus: 0 0 0 3px rgba(0, 163, 224, 0.5);`n  }`n}`n:root[data-theme=`"dark`"] {`n  --kit-accent: #00a3e0;`n}`n"
        $new = ":root {`n  --kit-accent: #10069f;`n  --kit-title: #10069f;`n  --kit-focus: 0 0 0 2px var(--kit-surface), 0 0 0 4px var(--kit-accent);`n  --kit-chart-1: #019adc;`n}`n@media (prefers-color-scheme: dark) {`n  :root:not([data-theme=`"light`"]) {`n    --kit-accent: #00a3e0;`n    --kit-title: #ffffff;`n    --kit-focus: 0 0 0 2px var(--kit-surface), 0 0 0 4px var(--kit-accent);`n  }`n}`n:root[data-theme=`"dark`"] {`n  --kit-accent: #00a3e0;`n  --kit-title: #ffffff;`n}`n"
        $mine = $old.Replace('--kit-accent: #10069f;', '--kit-accent: #224466;')   # the project chose its own accent
        $r = Update-KitTokens $mine $old $new
        $r | Should Match '(?m)^  --kit-accent: #224466;'                                                # kept
        $r | Should Match '(?m)^  --kit-focus: 0 0 0 2px var\(--kit-surface\), 0 0 0 4px var\(--kit-accent\);'   # the untouched default follows
        $r | Should Match '(?m)^  --kit-chart-1: #019adc;'
        $r | Should Match '(?m)^  --kit-title: #10069f;'                                                # added to the light block
        $r | Should Match '(?m)^    --kit-title: #ffffff;'                                              # and to the dark media block
        @([regex]::Matches($r, '--kit-title:')).Count | Should Be 3
        (Update-KitTokens $r $old $new) | Should Be $r                                                    # nothing left to do
        # Light only: a file without dark blocks gets no dark block.
        $lightOnly = ":root {`n  --kit-accent: #10069f;`n}`n"
        $l = Update-KitTokens $lightOnly $old $new
        $l | Should Match '--kit-title: #10069f;'
        $l | Should Not Match 'prefers-color-scheme'
        # A CRLF file (a git checkout, Notepad) gets its new lines with CRLF too, never mixed endings.
        $crlf = Update-KitTokens $lightOnly.Replace("`n", "`r`n") $old $new
        $crlf | Should Match "`r`n  --kit-title: #10069f;`r`n"
        ([regex]::Matches($crlf, "(?<!`r)`n")).Count | Should Be 0
    }
    It 'brings tokens.css up at a catalogue update, and keeps a value the project set' {
        $p = New-KitProject
        try {
            $null = Install-UiKit $p $root
            $cat = Join-Path $p '.streamhub\ui-kit'
            $tokens = Join-Path $p 'styles\kit\tokens.css'
            # Pretend the project came from the kit before --kit-title existed, with its own accent.
            $oldTemplate = [IO.File]::ReadAllText($tokens) -replace '(?m)^\s*--kit-title: [^;]+;\r?\n', '' -replace '(?m)^\s*--kit-icon: [^;]+;\r?\n', ''
            [IO.File]::WriteAllText((Join-Path $cat 'tokens.css'), $oldTemplate)
            [IO.File]::WriteAllText((Join-Path $p '.streamhub\kit-tokens-base.css'), $oldTemplate)   # what the project took its tokens from
            [IO.File]::WriteAllText($tokens, $oldTemplate.Replace('--kit-accent: #10069f;', '--kit-accent: #224466;'))
            [IO.File]::WriteAllText((Join-Path $cat 'VERSION.txt'), 'Kit revision 9')
            $r = @(Update-UiKitCatalog $p $root)
            $r -contains 'styles/kit/tokens.css' | Should Be $true
            $now = [IO.File]::ReadAllText($tokens)
            $now | Should Match '--kit-title: #10069f;'
            $now | Should Match '--kit-accent: #224466;'
            [IO.File]::ReadAllText((Join-Path $cat 'tokens.css')) | Should Match '--kit-title:'
            @(Update-UiKitCatalog $p $root).Count | Should Be 0   # up to date now
        } finally { Remove-Item $p -Recurse -Force }
    }
}

Describe 'Kit icons on a page (UI kit on)' {
    It 'reports a page that uses icons without loading kit-icons.js, once, and not a one-file page' {
        $page = "<html><body class=`"kit-page`">`n<button class=`"kit-btn`"><span data-kit-icon=`"plus`" aria-hidden=`"true`"></span>New</button>`n</body></html>"
        @(Find-KitIconScript 'index.html' '' $page)[0] | Should Match 'does not load the kit''s icon script.*styles/kit/kit-icons\.js'
        @(Find-KitIconScript 'index.html' $page $page).Count | Should Be 0   # already so: not the change's doing
        @(Find-KitIconScript 'index.html' '' ($page.Replace('</body>', '<script src="styles/kit/kit-icons.js"></script></body>'))).Count | Should Be 0
        @(Find-KitIconScript 'index.html' '' ($page.Replace('</body>', '<script data-streamhub="kit"></script></body>'))).Count | Should Be 0   # one-file: the kit block
        @(Find-KitIconScript 'src/App.tsx' '' '<span data-kit-icon="plus" />').Count | Should Be 0
        (@(Find-QualityIssues 'index.html' '' $page -UseKit) -join "`n") | Should Match 'icon script'
        (@(Find-QualityIssues 'index.html' '' $page) -join "`n") | Should Not Match 'icon script'
    }
    It 'reports kit action buttons a change adds without an icon, with the icon for each action' {
        $new = "<div class=`"kit-toolbar`">`n<button class=`"kit-btn kit-btn--primary`" type=`"button`">New expense</button>`n<button class=`"kit-btn`">Export</button>`n<button class=`"kit-btn`"><span data-kit-icon=`"trash-2`" aria-hidden=`"true`"></span>Delete</button>`n<button class=`"kit-btn`">Verwijderen</button>`n<button class=`"kit-btn`">Monthly view</button>`n<button>Add</button>`n</div>"
        $r = @(Find-IconlessActions 'index.html' '' $new)
        $r.Count | Should Be 1
        $r[0] | Should Match "^line 2: action buttons without an icon: 'New expense' \(plus\), 'Export' \(download\), 'Verwijderen' \(trash-2\)\."
        $r[0] | Should Not Match "Delete|Monthly|'Add'"
        @(Find-IconlessActions 'index.html' $new $new).Count | Should Be 0   # already there
        @(Find-IconlessActions 'src/Toolbar.tsx' '' '<button className="kit-btn" onClick={add}>Add {kind}</button>')[0] | Should Match "'Add' \(plus\)"
        @(Find-IconlessActions 'src/Toolbar.tsx' '' '<button className="kit-btn"><Icon name="plus" />Add</button>').Count | Should Be 0
        @(Find-IconlessActions 'styles/kit/kit-examples.html' '' $new).Count | Should Be 0
        (@(Find-QualityIssues 'index.html' '' $new -UseKit) -join "`n") | Should Match 'without an icon'
        (@(Find-QualityIssues 'index.html' '' $new -UseKit -UserLook) -join "`n") | Should Not Match 'without an icon'
        (@(Find-QualityIssues 'index.html' '' $new) -join "`n") | Should Not Match 'without an icon'
        Get-CheckLevel 'line 2: action buttons without an icon' 'quality' | Should Be 'warning'
    }
}

Describe 'kit-page belongs on the body (UI kit on)' {
    It 'reports kit-page on another tag and a kit page whose body lacks it, only what the change adds' {
        $onMain = "<!doctype html>`n<html><head><title>x</title></head>`n<body>`n<header class=`"kit-header`"></header>`n<main class=`"kit-page kit-container`"></main>`n</body></html>"
        $r = @(Find-KitPageIssues 'index.html' '' $onMain)
        $r.Count | Should Be 2
        $r[0] | Should Match '^line 5: kit-page is on a <main>: it belongs on <body>'
        $r[1] | Should Match '^line 3: the page uses the UI kit but its <body> has no kit-page class'
        $ok = "<!doctype html>`n<html><body class=`"kit-page`">`n<main class=`"kit-container`"></main>`n</body></html>"
        @(Find-KitPageIssues 'index.html' '' $ok).Count | Should Be 0
        @(Find-KitPageIssues 'index.html' $onMain $onMain).Count | Should Be 0   # already there: not the change's doing
        @(Find-KitPageIssues 'src/App.tsx' '' 'return <div className="kit-page"><Header /></div>;')[0] | Should Match 'kit-page is on a <div>.*index\.html'
        @(Find-KitPageIssues 'index.html' '' "<html><body>`n<p>No kit here</p></body></html>").Count | Should Be 0
        @(Find-KitPageIssues 'styles/kit/kit-examples.html' '' $onMain).Count | Should Be 0
    }
    It 'runs only with the UI kit on' {
        $onMain = "<html><body>`n<main class=`"kit-page`"></main></body></html>"
        (@(Find-QualityIssues 'index.html' '' $onMain -UseKit) -join "`n") | Should Match 'kit-page is on a <main>'
        (@(Find-QualityIssues 'index.html' '' $onMain) -join "`n") | Should Not Match 'kit-page'
    }
}
