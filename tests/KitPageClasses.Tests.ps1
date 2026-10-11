# Kit classes the page check finds on a page without a rule (lib/page-content-check.js, kind kitcss):
# the ones the kit's catalogue has get their rules in the project's kit.css (Repair-KitPageClasses),
# kept for the next kit.css too; a class the kit does not have comes back as unknown.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Config', 'UiKit', 'CheckPolicy') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

Describe 'Kit classes the page shows without a rule' {
    $p = Join-Path $env:TEMP ('ccb-kitpage-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $p | Out-Null
    [IO.File]::WriteAllText((Join-Path $p 'index.html'), '<!doctype html><html lang="en"><head><link rel="stylesheet" href="styles/kit/tokens.css"><link rel="stylesheet" href="styles/kit/kit.css"></head><body class="kit-page"><h1>Report</h1><div id="out"></div><script src="app.js"></script></body></html>')
    [IO.File]::WriteAllText((Join-Path $p 'app.js'), 'document.getElementById("out").innerHTML = "<p>later</p>";')
    It 'adds the catalogue''s rules for those classes to kit.css, keeps them, and reports a class the kit does not have' {
        $null = Install-UiKit $p $root
        $null = Update-UiKitProject $p $root
        $css = Join-Path $p 'styles\kit\kit.css'
        [IO.File]::ReadAllText($css) | Should Not Match '\.kit-table__sort'
        $r = Repair-KitPageClasses $p $root 'index.html' @('kit-table__sort', 'kit-chart__swatch', 'kit-cardz', 'not-kit')
        @($r.added) -contains 'kit-table__sort' | Should Be $true
        @($r.added) -contains 'kit-chart__swatch' | Should Be $true
        @($r.unknown) -join ',' | Should Be 'kit-cardz'
        $r.kitCss.old | Should Not Match '\.kit-table__sort'
        [IO.File]::ReadAllText($css) | Should Match '\.kit-table__sort \{'
        (Read-KitPageClasses $p)['index.html'] -join ',' | Should Be 'kit-table__sort,kit-chart__swatch'
        # The next kit.css keeps them (the classes are counted as used).
        $null = Update-UiKitProject $p $root
        [IO.File]::ReadAllText($css) | Should Match '\.kit-chart__swatch \{'
        # Nothing new: nothing written.
        $again = Repair-KitPageClasses $p $root 'index.html' @('kit-table__sort')
        @($again.added).Count | Should Be 0
        $again.kitCss | Should BeNullOrEmpty
    }
    It 'does not call a class a kit script writes without a rule of its own unknown' {
        $kitJs = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.js'))
        $kitCss = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.css'))
        $hook = @([regex]::Matches($kitJs, '"(kit-[a-z0-9_-]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique | Where-Object { $kitCss -notmatch ('\.' + [regex]::Escape($_) + '(?![\w-])') }) | Select-Object -First 1
        if ($hook) { @((Repair-KitPageClasses $p $root 'index.html' @($hook)).unknown).Count | Should Be 0 }
    }
    It 'knows the classes of kit parts that are off, so they are neither added nor reported' {
        $off = @(Get-KitOffPartClasses $root @('interactive', 'charts', 'icons', 'data', 'dashboard', 'print'))   # extras off
        $off -contains 'kit-switch' | Should Be $true
        $off -contains 'kit-calendar' | Should Be $true
        $off -contains 'kit-btn' | Should Be $false
        $off -contains 'kit-table' | Should Be $false
        @(Get-KitOffPartClasses $root @('interactive', 'charts', 'icons', 'data', 'dashboard', 'extras', 'print', 'palette', 'themeswitch', 'sql', 'pdf', 'python')).Count | Should Be 0
    }
    It 'sends an unknown class to Copilot as a likely mistake, not an error' {
        Get-CheckLevel 'index.html uses class(es) the UI kit does not have: kit-cardz (a misspelling or an invented kit class, so the element has no style)' 'script' | Should Be 'warning'
    }
    Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
