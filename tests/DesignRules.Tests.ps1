# Design rules and checks written for StreamHub (prompts/rules/design.md, designreview.md; Guardrails
# Find-UiSlop focus and motion; the page-side target size and names in lib/contrast-check.js).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\Prompts.psm1') -Force
Import-Module (Join-Path $root 'lib\Guardrails.psm1') -Force

Describe 'Design rules for Copilot' {
    It 'go with interface work, and the review rule with a design review request' {
        $ids = @(& (Get-Module Prompts) { Get-PromptModules -Text 'Build a dashboard page with a table' -Context @{ Paths = @('index.html'); Traits = @('web', 'code') } })
        $ids -contains 'rules:design' | Should Be $true
        $ids -contains 'rules:designreview' | Should Be $false
        foreach ($t in 'Can you review the design of the dashboard?', 'Do a design review of index.html', 'Beoordeel het ontwerp van de pagina') {
            $r = @(& (Get-Module Prompts) { param($x) Get-PromptModules -Text $x -Context @{ Paths = @('index.html'); Traits = @('web', 'code') } } $t)
            $r -contains 'rules:designreview' | Should Be $true
        }
    }
    It 'are StreamHub''s own short text' {
        foreach ($f in 'design.md', 'designreview.md') { ([IO.File]::ReadAllText((Join-Path $root "prompts\rules\$f"))).Length | Should BeLessThan 2200 }
    }
    It 'leave the choice of tables, lists and charts to Copilot and only set how they look' {
        $t = [IO.File]::ReadAllText((Join-Path $root 'prompts\rules\design.md'))
        $t | Should Match 'How data is shown \(tables, lists, any kind of chart\) is your choice'
        $t | Should Not Match 'charts only when'
    }
}

Describe 'Focus and motion checks' {
    It 'report a removed focus outline without a replacement, not one with a :focus-visible style' {
        @(Find-UiSlop 'styles/app.css' '' 'button:focus { outline: none; }') -join ' ' | Should Match 'focus outline is removed'
        @(Find-UiSlop 'styles/app.css' '' "button:focus { outline: none; }`nbutton:focus-visible { box-shadow: 0 0 0 3px var(--kit-accent); }") | Where-Object { $_ -match 'focus' } | Should BeNullOrEmpty
    }
    It 'report an animation without a reduced-motion version' {
        @(Find-UiSlop 'styles/app.css' '' '.spin { animation: turn 1s linear infinite; }') -join ' ' | Should Match 'reduced-motion'
        @(Find-UiSlop 'styles/app.css' '' ".spin { animation: turn 1s linear infinite; }`n@media (prefers-reduced-motion: reduce) { .spin { animation: none; } }") | Where-Object { $_ -match 'reduced' } | Should BeNullOrEmpty
        @(Find-UiSlop 'styles/app.css' '' '.x { animation: none; }') | Where-Object { $_ -match 'reduced' } | Should BeNullOrEmpty
    }
}

Describe 'The page-side checks' {
    It 'cover click target size with the WCAG spacing exception, and names' {
        $js = [IO.File]::ReadAllText((Join-Path $root 'lib\contrast-check.js'))
        $js | Should Match 'note\("target"'
        $js | Should Match 'crowded'
        $js | Should Match 'note\("name"'
    }
}

Describe 'The kit gradient and sentence case' {
    It 'reports a gradient other than the kit''s own (with the kit), not the kit gradient' {
        @(Find-UiSlop 'styles/app.css' '' '.hero { background: linear-gradient(90deg, #ff0080, #7928ca); }' -UseKit) -join ' ' | Should Match 'kit''s own'
        @(Find-UiSlop 'styles/app.css' '' '.hero { background: var(--kit-gradient); }' -UseKit) | Where-Object { $_ -match 'gradient' } | Should BeNullOrEmpty
    }
    It 'reports headings and labels in capitals, and text-transform: uppercase' {
        @(Find-UiSlop 'index.html' '' '<th>TOTALS</th>') -join ' ' | Should Match 'sentence case'
        @(Find-UiSlop 'index.html' '' '<h2 class="x">MONTHLY REPORT</h2>') -join ' ' | Should Match 'sentence case'
        @(Find-UiSlop 'styles/app.css' '' 'th { text-transform: uppercase; }') -join ' ' | Should Match 'sentence case'
        @(Find-UiSlop 'index.html' '' '<th>Totals</th><th>ID</th>') | Where-Object { $_ -match 'capitals' } | Should BeNullOrEmpty
    }
    It 'uses Arial first in the kit, and no capitals in its own styles' {
        [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\tokens.css')) | Should Match '--kit-font: Arial,'
        [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.css')) | Should Not Match 'uppercase'
    }
}
