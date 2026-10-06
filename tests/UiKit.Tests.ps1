# The UI kit (templates/ui-kit, lib/UiKit.psm1): added to a project for interface work (setting
# uiKit), never overwritten; its rule goes to Copilot with the UI rules; generated-looking patterns
# are reported (Guardrails Find-UiSlop). Made-up project content.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Config.psm1') -Force
Import-Module (Join-Path $root 'lib\UiKit.psm1') -Force
Import-Module (Join-Path $root 'lib\Guardrails.psm1') -Force
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force
Import-Module (Join-Path $root 'lib\Lint.psm1') -Force

Describe 'Install-UiKit' {
    $p = Join-Path $env:TEMP ('ccb-kit-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    It 'copies the kit into styles/kit once, and never overwrites the project''s own version' {
        @(Install-UiKit $p $root) -join ',' | Should Be 'styles/kit/tokens.css,styles/kit/kit.css,styles/kit/kit-examples.html,styles/kit/kit.js,styles/kit/LICENSE-kokonutui.txt,styles/kit/kit-charts.js,styles/kit/LICENSE-bklit-ui.txt,styles/kit/LICENSE-lucide.txt,styles/kit/kit-icons.js'
        Test-Path (Join-Path $p 'styles\kit\react') | Should Be $false   # not a React project
        Test-UiKitInProject $p | Should Be $true
        [IO.File]::WriteAllText((Join-Path $p 'styles\kit\tokens.css'), ':root { --kit-accent: #224466; }')
        @(Install-UiKit $p $root).Count | Should Be 0
        [IO.File]::ReadAllText((Join-Path $p 'styles\kit\tokens.css')) | Should Match '#224466'
    }
    It 'adds the React versions in a React project' {
        $r = Join-Path $env:TEMP ('ccb-kitr-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $r | Out-Null
        [IO.File]::WriteAllText((Join-Path $r 'package.json'), '{ "dependencies": { "react": "^19.0.0" } }')
        $added = @(Install-UiKit $r $root)
        $added -contains 'styles/kit/react/HoldButton.tsx' | Should Be $true
        $added -contains 'styles/kit/react/Tabs.tsx' | Should Be $true
        $added -contains 'styles/kit/react/Chart.tsx' | Should Be $true
        Remove-Item $r -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'The UI kit rule' {
    It 'goes with the UI rules while the setting is on' {
        $ids = @(& (Get-Module Prompts) { Get-PromptModules -Text 'Build a dashboard page with a table and filters' -Context @{ Paths = @('index.html'); Traits = @('web', 'code') } })
        $ids -contains 'rules:ui' | Should Be $true
        $ids -contains 'rules:uikit' | Should Be $true
    }
    It 'is left out when the setting is off' {
        Mock -ModuleName Prompts Test-UiKitOn { $false }
        $ids = @(& (Get-Module Prompts) { Get-PromptModules -Text 'Build a dashboard page with a table and filters' -Context @{ Paths = @('index.html'); Traits = @('web', 'code') } })
        $ids -contains 'rules:uikit' | Should Be $false
    }
    It 'names only classes the kit has' {
        $rule = [IO.File]::ReadAllText((Join-Path $root 'prompts\rules\uikit.md'))
        $css = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.css'))
        $line = (@($rule.Split("`n") | Where-Object { $_ -like '- Components:*' -or $_ -like '- Interactive parts*' }) -join ' ')
        foreach ($m in [regex]::Matches($line, '(?<![\w-])kit-[a-z0-9_-]+')) { $css | Should Match ([regex]::Escape('.' + $m.Value.TrimEnd('-'))) }
    }
}

Describe 'Find-UiSlop' {
    It 'reports gradient text, thick side stripes and decorative blur that a change adds' {
        $new = ".title { background: linear-gradient(90deg, red, blue); background-clip: text; }`n.note { border-left: 4px solid #c00; }`n.glass { backdrop-filter: blur(12px); }"
        $r = @(Find-UiSlop 'styles/app.css' '' $new)
        $r.Count | Should Be 3
        ($r -join ' ') | Should Match 'gradient text'
        ($r -join ' ') | Should Match 'side stripe'
        ($r -join ' ') | Should Match 'blur'
    }
    It 'reports hard-coded colours only with the kit in the project, and not in the tokens file' {
        $new = '.box { color: #333; }'
        @(Find-UiSlop 'styles/app.css' '' $new).Count | Should Be 0
        @(Find-UiSlop 'styles/app.css' '' $new -UseKit) -join ' ' | Should Match 'hard-coded colour'
        @(Find-UiSlop 'styles/kit/tokens.css' '' ':root { --kit-accent: #10069f; }' -UseKit).Count | Should Be 0
        @(Find-UiSlop 'styles/app.css' '' '.box { color: var(--kit-text); border: 1px solid var(--kit-border); }' -UseKit).Count | Should Be 0
    }
    It 'leaves lines the file already had alone' {
        $old = '.note { border-left: 4px solid #c00; }'
        @(Find-UiSlop 'styles/app.css' $old "$old`n.x { margin: 0; }").Count | Should Be 0
    }
}

Describe 'The kit charts' {
    It 'cover every chart type the rule names, with a hidden data table for screen readers' {
        $js = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit-charts.js'))
        foreach ($k in 'bar', 'line', 'area', 'ring', 'gauge', 'heatmap', 'sparkline') { $js | Should Match ("\b" + $k + "\b") }
        $js | Should Match 'kit-chart__table'
        $js | Should Match 'role: "img"'
        [IO.File]::ReadAllText((Join-Path $root 'prompts\rules\uikit.md')) | Should Match 'data-kit-chart="bar\|line\|area\|ring\|gauge\|heatmap\|sparkline"'
    }
}

Describe 'The kit files themselves' {
    It 'credit kokonutui where its parts are used, with its licence alongside' {
        [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\LICENSE-kokonutui.txt')) | Should Match 'Copyright \(c\) 2025 kokonutUI'
        foreach ($f in @(Get-ChildItem (Join-Path $root 'templates\ui-kit\react') -Filter *.tsx | Where-Object { $_.Name -notin 'Chart.tsx', 'Icon.tsx' }) + @(Get-Item (Join-Path $root 'templates\ui-kit\kit.js'))) {
            [IO.File]::ReadAllText($f.FullName) | Should Match '(?s)kokonutui.*MIT'
        }
        [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\LICENSE-bklit-ui.txt')) | Should Match 'Copyright \(c\) 2026 uixmat'
        foreach ($f in 'kit-charts.js', 'react\Chart.tsx') { [IO.File]::ReadAllText((Join-Path $root "templates\ui-kit\$f")) | Should Match '(?s)bklit-ui.*MIT' }
        [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\react\Icon.tsx')) | Should Match 'Lucide icon \(ISC'
    }
    It 'pass the file checks' {
        foreach ($f in 'tokens.css', 'kit.css', 'kit.js', 'kit-examples.html', 'kit-charts.js', 'react\Chart.tsx', 'react\HoldButton.tsx', 'react\SearchBox.tsx', 'react\DropZone.tsx', 'react\Tabs.tsx', 'react\Loading.tsx', 'react\Composer.tsx', 'react\CommandButton.tsx') {
            $path = Join-Path $root "templates\ui-kit\$f"
            @(Test-FileContent $path ([IO.File]::ReadAllText($path))) | Should BeNullOrEmpty
        }
    }
}

Describe 'UI kit parts switched off (Settings > UI kit)' {
    It 'leaves out the files and example sections of parts that are off' {
        Mock -ModuleName UiKit Test-UiKitPart { $Name -ne 'charts' }
        $p = Join-Path $env:TEMP ('ccb-kitp-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        [IO.File]::WriteAllText((Join-Path $p 'package.json'), '{ "dependencies": { "react": "^19.0.0" } }')
        $added = @(Install-UiKit $p $root)
        $added -contains 'styles/kit/kit-charts.js' | Should Be $false
        $added -contains 'styles/kit/react/Chart.tsx' | Should Be $false
        $added -contains 'styles/kit/kit.js' | Should Be $true
        $added -contains 'styles/kit/react/HoldButton.tsx' | Should Be $true
        $ex = [IO.File]::ReadAllText((Join-Path $p 'styles\kit\kit-examples.html'))
        $ex | Should Not Match 'kit-charts\.js'
        $ex | Should Not Match 'data-kit-chart='
        $ex | Should Match 'data-kit-hold'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'adds no React files when React versions are off' {
        Mock -ModuleName UiKit Test-UiKitPart { $Name -ne 'react' }
        $p = Join-Path $env:TEMP ('ccb-kitq-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        [IO.File]::WriteAllText((Join-Path $p 'package.json'), '{ "dependencies": { "react": "^19.0.0" } }')
        @(Install-UiKit $p $root) | Where-Object { $_ -like '*react/*' } | Should BeNullOrEmpty
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'tells Copilot only about the parts that are on' {
        Mock -ModuleName Prompts Test-UiKitPart { $Name -notin 'interactive', 'react' }
        $t = & (Get-Module Prompts) { param($r) Get-PromptPart $r 'rules:uikit' } $root
        $t | Should Not Match 'Interactive parts'
        $t | Should Not Match 'styles/kit/react'
        $t | Should Match 'Charts:'
    }
    It 'sends the design rules only while they are on' {
        Mock -ModuleName Prompts Test-UiKitPart { $Name -ne 'designRules' }
        $ids = @(& (Get-Module Prompts) { Get-PromptModules -Text 'Build a dashboard page with a table' -Context @{ Paths = @('index.html'); Traits = @('web', 'code') } })
        $ids -contains 'rules:design' | Should Be $false
        $ids -contains 'rules:ui' | Should Be $true
    }
    It 'skips the generated-look warnings while they are off' {
        Mock -ModuleName Guardrails Test-UiKitPart { $false }
        @(Find-UiSlop 'styles/app.css' '' '.t { background-clip: text; }') | Should BeNullOrEmpty
    }
}

Describe 'UI kit colours (Settings > UI kit > Colours)' {
    It 'gives a project the neutral tokens, without the palette section, when Neutral is chosen' {
        Mock -ModuleName UiKit Get-UiKitColors { 'neutral' }
        $p = Join-Path $env:TEMP ('ccb-kitn-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $null = Install-UiKit $p $root
        $t = [IO.File]::ReadAllText((Join-Path $p 'styles\kit\tokens.css'))
        $t | Should Match 'neutral colours'
        $t | Should Not Match '--kit-palette-'
        [IO.File]::ReadAllText((Join-Path $p 'styles\kit\kit-examples.html')) | Should Not Match 'kit-swatch'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'gives the blue palette by default' {
        Mock -ModuleName UiKit Get-UiKitColors { 'blue' }
        $p = Join-Path $env:TEMP ('ccb-kitb-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $null = Install-UiKit $p $root
        [IO.File]::ReadAllText((Join-Path $p 'styles\kit\tokens.css')) | Should Match '--kit-palette-blue: #10069f'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'keeps both colour files readable (WCAG AA in light and dark), and neither says brand' {
        Import-Module (Join-Path $root 'lib\Contrast.psm1') -Force
        foreach ($f in 'tokens.css', 'tokens-neutral.css') {
            $css = [IO.File]::ReadAllText((Join-Path $root "templates\ui-kit\$f"))
            @(Test-TokenContrast $css) | Should BeNullOrEmpty
            $css | Should Not Match '(?i)brand'
        }
        foreach ($f in 'kit.css', 'kit-examples.html') { [IO.File]::ReadAllText((Join-Path $root "templates\ui-kit\$f")) | Should Not Match '(?i)brand' }
    }
}

Describe 'UI kit icons (Lucide)' {
    It 'ships the whole Lucide set with its licence' {
        $l = & (Get-Module UiKit) { param($r) Get-LucideIcons $r } $root
        $l.icons.Count | Should BeGreaterThan 1500
        $l.icons['check'] | Should Match '<path'
        $l.icons.ContainsKey('trash-2') | Should Be $true      # older names (aliases) work too
        [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\LICENSE-lucide.txt')) | Should Match 'ISC License'
    }
    It 'gives a project the common icons, adds the ones its pages use, and names close ones for a wrong name' {
        $p = Join-Path $env:TEMP ('ccb-kiti-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        $added = @(Install-UiKit $p $root)
        $added -contains 'styles/kit/kit-icons.js' | Should Be $true
        $file = Join-Path $p 'styles\kit\kit-icons.js'
        [IO.File]::ReadAllText($file) | Should Match '"settings":'
        [IO.File]::ReadAllText($file) | Should Not Match '"rocket":'
        [IO.File]::WriteAllText((Join-Path $p 'index.html'), '<span data-kit-icon="rocket"></span><span data-kit-icon="calender-plus"></span>')
        $r = Update-KitIcons $p $root
        $r.written | Should Be $true
        [IO.File]::ReadAllText($file) | Should Match '"rocket":'
        @($r.unknown).Count | Should Be 1
        @($r.unknown)[0].like[0] | Should Be 'calendar-plus'
        (Update-KitIcons $p $root).written | Should Be $false   # nothing new: the file stays as it is
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'adds no icons while the Icons part is off' {
        Mock -ModuleName UiKit Test-UiKitPart { $Name -ne 'icons' }
        $p = Join-Path $env:TEMP ('ccb-kitj-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
        @(Install-UiKit $p $root) | Where-Object { $_ -match 'icon|lucide' } | Should BeNullOrEmpty
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}
