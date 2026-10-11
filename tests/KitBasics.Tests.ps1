# The kit's basics (revision 11): every control and content element in the kit's look (radios and check
# box groups, fieldsets, field types, input groups, form actions, lists, trees, popovers, confirm and alert
# boxes, content pieces), named in the rule, shown in the examples and counted by the kit usage.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'UiKit') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }
$kitCss = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.css'))
$kitJs = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.js'))
$examples = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit-examples.html'))
$rule = [IO.File]::ReadAllText((Join-Path $root 'prompts\rules\uikit.md'))

Describe 'Every control and content element has a kit form' {
    It 'styles radios, check box groups, fieldsets, field types, input groups and form actions' {
        foreach ($c in 'kit-choices', 'kit-choices--row', 'kit-fieldset', 'kit-fieldset--plain', 'kit-legend', 'kit-label--required', 'kit-input-group', 'kit-input-group__addon', 'kit-input-icon', 'kit-form__actions', 'kit-form__actions--sticky') { $kitCss | Should Match ('\.' + [regex]::Escape($c) + '\b') }
        $kitCss | Should Match '\.kit-check input\[type="radio"\]:focus-visible'
        $kitCss | Should Match '\.kit-input::file-selector-button'
        $kitCss | Should Match '\.kit-input\[type="color"\]'
        $kitCss | Should Match '\.kit-select\[multiple\]'
        $kitCss | Should Match '\.kit-page progress, \.kit-page meter \{ accent-color: var\(--kit-accent\)'
        $kitCss | Should Match '\.kit-page ::selection'
    }
    It 'styles lists, trees, popovers and the content pieces' {
        foreach ($c in 'kit-list', 'kit-list__item', 'kit-list__body', 'kit-list__title', 'kit-list__meta', 'kit-list__actions', 'kit-list--plain', 'kit-tree', 'kit-tree__row', 'kit-tree__toggle', 'kit-tree__spacer', 'kit-popover-wrap', 'kit-popover', 'kit-popover--right', 'kit-popover__head', 'kit-popover__actions',
            'kit-code', 'kit-mark', 'kit-media', 'kit-caption', 'kit-quote', 'kit-dot', 'kit-dot--ok', 'kit-dot--warn', 'kit-dot--error', 'kit-dot--accent', 'kit-truncate', 'kit-sr-only', 'kit-skip', 'kit-footer') { $kitCss | Should Match ('\.' + [regex]::Escape($c) + '\b') }
        $kitCss | Should Match '\.kit-tree li\[aria-expanded="false"\] > ul \{ display: none; \}'
        $kitCss | Should Match '\.kit-table caption'
        # Every value is a token: no colour, size or shadow of its own in the new block.
        $block = [regex]::Match($kitCss, '(?s)/\* Basics \(kit revision 11\).*?/\*\s+Interactive components adapted from kokonutui').Value
        $block.Length | Should BeGreaterThan 3000
        ([regex]::Matches($block, '(?<![-\w])#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(')).Count | Should Be 0
    }
    It 'adds the behaviour of trees, popovers, confirm and alert in kit.js, ASCII only' {
        $kitJs | Should Match 'function setupTree\('
        $kitJs | Should Match '\["\[data-kit-tree\]", setupTree\]'
        $kitJs | Should Match 'data-kit-popover'
        $kitJs | Should Match 'confirm: confirmBox'
        $kitJs | Should Match 'alert: alertBox'
        $kitJs | Should Match 'd\.className = DIALOG'   # the dialog class put together, so a page gets its styles through the hook, not the token
        [regex]::IsMatch($kitJs, '[^\x00-\x7F]') | Should Be $false
    }
    It 'shows them in the examples page, in sections the index finds, and names them in the rule' {
        foreach ($id in 'forms', 'boxes', 'lists', 'content') { $examples | Should Match ('<section id="' + $id + '"') }
        foreach ($s in 'type="radio"', 'kit-fieldset', 'kit-label--required', 'type="file"', 'type="color"', 'kit-input-group__addon', 'kit-input-icon', 'kit-form__actions', 'data-kit-tree', 'data-kit-popover', 'KitUI.confirm', 'KitUI.alert', 'kit-list__item', 'kit-code', 'kit-mark', 'kit-dot--ok', 'kit-truncate', 'kit-sr-only', 'kit-footer', '<caption>') { $examples | Should Match ([regex]::Escape($s)) }
        $index = @(Get-KitExamplesIndex $examples)
        @($index | Where-Object { $_.title -match 'Lists and trees' }).Count | Should Be 1
        @($index | Where-Object { $_.title -match 'Confirm, alert and popover' }).Count | Should Be 1
        $line = @($rule.Split("`n") | Where-Object { $_ -like '- Every control and content element*' })
        $line.Count | Should Be 1
        foreach ($m in [regex]::Matches($line[0], '(?<![\w-])kit-[a-z0-9]+(?:__[a-z0-9-]+|--[a-z0-9-]+|-[a-z0-9]+)*')) { $kitCss | Should Match ('\.' + [regex]::Escape($m.Value) + '\b') }
        $line[0] | Should Match 'Never call the browser''s alert\(\), confirm\(\) or prompt\(\): KitUI\.confirm'
        $rule.Length | Should BeLessThan 40000
    }
    It 'is kit revision 11, with the React basics in every React kit' {
        & (Get-Module UiKit) { $script:KitRevision } | Should Be 11
        foreach ($f in 'Popover.tsx', 'Tree.tsx', 'Confirm.tsx') { Test-Path (Join-Path $root "templates\ui-kit\react\$f") | Should Be $true }
        $files = @(& (Get-Module UiKit) { param($r) Get-UiKitFiles $r } $root)
        $files -contains 'react/Tree.tsx' | Should Be $true
        $files -contains 'react/Popover.tsx' | Should Be $true
    }
}

Describe 'A page that uses the basics gets their CSS' {
    $p = Join-Path $env:TEMP ('ccb-basics-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory (Join-Path $p 'js') -Force | Out-Null
    It 'keeps the list, tree, popover and the confirm dialog rules a page needs, not the others' {
        [IO.File]::WriteAllText((Join-Path $p 'index.html'), "<!doctype html><html><head><link rel=`"stylesheet`" href=`"styles/kit/tokens.css`"><link rel=`"stylesheet`" href=`"styles/kit/kit.css`"></head><body class=`"kit-page`"><ul class=`"kit-list`"><li class=`"kit-list__item`">A</li></ul><ul class=`"kit-tree`" data-kit-tree><li><div class=`"kit-tree__row`">R</div></li></ul><button class=`"kit-btn`" data-kit-popover=`"p`">P</button><div class=`"kit-popover`" id=`"p`" hidden>x</div><script src=`"styles/kit/kit.js`"></script><script src=`"js/app.js`"></script></body></html>")
        [IO.File]::WriteAllText((Join-Path $p 'js\app.js'), "document.querySelector('button').addEventListener('click', function () { KitUI.confirm('Delete?', { danger: true }).then(function (yes) { if (yes) KitUI.toast('Deleted'); }); });")
        $null = Install-UiKit $p $root
        $u = Update-UiKitProject $p $root
        $css = [IO.File]::ReadAllText((Join-Path $p 'styles\kit\kit.css'))
        $css | Should Match '\.kit-list__item \{'
        $css | Should Match '\.kit-tree__toggle \{'          # written by kit.js for a page with a kit-tree
        $css | Should Match '\.kit-popover \{'
        $css | Should Match '\.kit-dialog \{'               # built by KitUI.confirm (the hook), not written in the page
        $css | Should Match '\.kit-dialog__actions \{'
        $css | Should Match '\.kit-toast \{'
        $css | Should Not Match '\.kit-calendar \{'
        $css | Should Not Match '\.kit-footer \{'
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
