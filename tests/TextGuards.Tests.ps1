# Guards for what a page shows: text broken by a wrong encoding (Lint Find-BrokenEncoding,
# Test-TextEncoding; AutoFix), PowerShell 5.1 file commands without -Encoding, tables a change adds
# that cannot be sorted (Guardrails Find-UnsortedTables), kit progress bars and late tables (kit.js),
# and the page-side check (lib/page-content-check.js).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
foreach ($m in 'Lint', 'AutoFix', 'Guardrails', 'Contrast', 'CheckPolicy') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

$utf8 = New-Object Text.UTF8Encoding($false)
$w1252 = [Text.Encoding]::GetEncoding(1252)
function Get-Broken([string]$Text) { $w1252.GetString($utf8.GetBytes($Text)) }
$dash = [string][char]0x2013
$eacute = [string][char]0xE9

Describe 'Find-BrokenEncoding' {
    It 'finds UTF-8 text read as Windows-1252 and gives the real characters' {
        foreach ($real in "14${dash}27 days", "caf$eacute", ("25" + [char]0xB0 + "C"), ("it" + [char]0x2019 + "s"), ([string][char]0x041F + [char]0x0440 + [char]0x0438), ("smile " + [char]0xD83D + [char]0xDE00)) {
            $broken = Get-Broken $real
            $hits = @(Find-BrokenEncoding $broken)
            $hits.Count | Should Be 1
            $broken.Remove($hits[0].index, $hits[0].length).Insert($hits[0].index, $hits[0].fixed) | Should Be $real
        }
    }
    It 'leaves real text with accents and symbols alone' {
        foreach ($real in ("Caf$eacute $dash bar"), ([string][char]0xC9 + [char]0x2026), ("S" + [char]0xC3 + "O PAULO"), ("M" + [char]0xDC + [char]0x201D), ("na" + [char]0xEF + "ve " + [char]0xBF + "Qu$eacute?")) {
            @(Find-BrokenEncoding $real).Count | Should Be 0
        }
    }
}

Describe 'Test-TextEncoding' {
    It 'reports broken characters with the right one, in any text file' {
        $msg = @(Test-TextEncoding 'js/app.js' ("const label = '" + (Get-Broken "14${dash}27 days") + "';"))
        $msg.Count | Should Be 1
        $msg[0] | Should Match '^line 1: broken characters'
        $msg[0] | Should Match ([regex]::Escape("should be '$dash'"))
        (Test-FileContent 'data/notes.md' ("# Notes`n`nAbout " + (Get-Broken "caf$eacute"))) -join ' ' | Should Match 'broken characters'
    }
    It 'asks for <meta charset="utf-8"> at the top of a full page, not of a part' {
        @(Test-TextEncoding 'index.html' '<!doctype html><html><head><title>x</title></head><body></body></html>')[0] | Should Match 'no <meta charset="utf-8">'
        @(Test-TextEncoding 'index.html' '<!doctype html><html><head><meta charset="utf-8"><title>x</title></head></html>').Count | Should Be 0
        @(Test-TextEncoding 'index.html' '<!doctype html><html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1252"></head></html>')[0] | Should Match 'charset=windows-1252'
        @(Test-TextEncoding 'part.html' '<div>part</div>').Count | Should Be 0
        $late = '<!doctype html><html><head><title>x</title>' + ('<!-- filler -->' * 80) + '<meta charset="utf-8"></head></html>'
        @(Test-TextEncoding 'late.html' $late)[0] | Should Match 'no <meta charset'
    }
}

Describe 'Repair-MechanicalIssues: encoding' {
    It 'writes broken sequences as the real characters, in strings and markup too' {
        $r = Repair-MechanicalIssues 'js/app.js' ("const a = '" + (Get-Broken "14${dash}27 days") + "'; // " + (Get-Broken "caf$eacute"))
        $r.text | Should Be "const a = '14${dash}27 days'; // caf$eacute"
        ($r.fixes -join ' ') | Should Match 'broken character'
    }
    It 'adds <meta charset="utf-8"> to a page without one, with its indentation and line endings' {
        $r = Repair-MechanicalIssues 'index.html' "<!doctype html>`r`n<html>`r`n  <head>`r`n    <title>x</title>`r`n  </head>`r`n</html>`r`n"
        $r.text | Should Be "<!doctype html>`r`n<html>`r`n  <head>`r`n    <meta charset=`"utf-8`">`r`n    <title>x</title>`r`n  </head>`r`n</html>`r`n"
        (Repair-MechanicalIssues 'index.html' '<html><head><meta charset="utf-8"></head></html>').fixes.Count | Should Be 0
    }
    It 'leaves the blocks the helper program fills in a one-file page alone' {
        $broken = Get-Broken "14${dash}27 days"
        $page = "<html><head><meta charset=`"utf-8`"></head><body><p>$broken</p><script data-streamhub=`"data`" data-source=`"Source/a.csv`">window.a = [`"$broken`"];</script></body></html>"
        $r = Repair-MechanicalIssues 'index.html' $page
        $r.text | Should Match ([regex]::Escape("<p>14${dash}27 days</p>"))
        $r.text | Should Match ([regex]::Escape("window.a = [`"$broken`"]"))
    }
}

Describe 'PowerShell files without -Encoding' {
    It 'warns about a write without -Encoding, and about reads in a script that writes pages' {
        $w = @(Test-FileContent 'Scripts/Build.ps1' "`$html = 'x'`nSet-Content -Path 'out.html' -Value `$html`n")
        ($w -join ' ') | Should Match 'Set-Content without -Encoding'
        Get-CheckLevel ($w | Where-Object { $_ -match 'without -Encoding' }) 'file' | Should Be 'warning'
        $r = @(Test-FileContent 'Scripts/Build.ps1' "`$t = Get-Content 'template.html' -Raw`n[IO.File]::WriteAllText('out.html', `$t)`n")
        ($r -join ' ') | Should Match 'Get-Content without -Encoding: Windows PowerShell 5.1 reads'
    }
    It 'leaves -Encoding, a set default and plain reads of settings alone' {
        (@(Test-FileContent 'Scripts/Build.ps1' "Set-Content -Path 'out.html' -Value 'x' -Encoding UTF8`n") -join ' ') | Should Not Match 'without -Encoding'
        (@(Test-FileContent 'Scripts/Build.ps1' "`$PSDefaultParameterValues['*:Encoding'] = 'utf8'`nSet-Content -Path 'out.html' -Value 'x'`n") -join ' ') | Should Not Match 'without -Encoding'
        (@(Test-FileContent 'lib/Settings.psm1' "`$c = Get-Content `$file -Raw | ConvertFrom-Json`n") -join ' ') | Should Not Match 'without -Encoding'
    }
}

Describe 'Find-UnsortedTables' {
    It 'reports a kit-table without data-kit-sort, also written from a script' {
        Find-UnsortedTables 'index.html' '' '<table class="kit-table"><thead><tr><th>A</th></tr></thead></table>' | Should Match 'line 1: a table that cannot be sorted.*data-kit-sort'
        Find-UnsortedTables 'js/app.js' '' "el.innerHTML = '<table class=`"kit-table`">' + rows + '</table>';" | Should Match 'data-kit-sort'
        Find-UnsortedTables 'index.html' '' '<table class="kit-table" data-kit-sort></table>' | Should BeNullOrEmpty
    }
    It 'reports a plain table only in a file without any sorting, and never a layout table or one already there' {
        Find-UnsortedTables 'index.html' '' '<table><tr><th>A</th></tr></table>' | Should Match 'every table sorts its rows'
        Find-UnsortedTables 'index.html' '' "<table><tr><th>A</th></tr></table><script>rows.sort(byName)</script>" | Should BeNullOrEmpty
        Find-UnsortedTables 'index.html' '' '<table role="presentation"><tr><td>x</td></tr></table>' | Should BeNullOrEmpty
        Find-UnsortedTables 'index.html' '<table class="kit-table">' '<table class="kit-table"><tr></tr>' | Should BeNullOrEmpty
        Find-UnsortedTables 'styles/kit/kit-examples.html' '' '<table class="kit-table">' | Should BeNullOrEmpty
    }
}

Describe 'The page-side check and the kit' {
    It 'ships an ASCII-only page script with the three checks' {
        $js = Get-PageContentScript
        $js | Should Match 'kind: "encoding"'
        $js | Should Match 'kind: "bar"'
        $js | Should Match 'kind: "sort"'
        [regex]::IsMatch($js, '[^\x00-\x7F]') | Should Be $false
    }
    It 'kit.js fills progress bars from aria-valuenow and sets up tables written later' {
        $kit = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.js'))
        $kit | Should Match 'function fillBar'
        $kit | Should Match 'aria-valuenow'
        $kit | Should Match 'function setupTables'
        $kit | Should Match 'table\.kitTable'
    }
    It 'every table of the kit examples sorts' {
        $ex = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit-examples.html'))
        @([regex]::Matches($ex, '<table\b[^>]*>') | Where-Object { $_.Value -notmatch 'data-kit-sort' }).Count | Should Be 0
    }
}

Describe 'Bars flat at the axis' {
    It 'reports a bar the change rounds at the axis, in canvas, Chart.js and CSS' {
        Find-RoundedBarBase 'js/chart.js' '' 'ctx.roundRect(x, y, w, h, 6); ctx.fill();' | Should Match 'roundRect with one radius'
        Find-RoundedBarBase 'js/chart.js' '' "datasets: [{ data: d, borderRadius: 6, borderSkipped: false }]" | Should Match 'borderSkipped: false'
        Find-RoundedBarBase 'css/app.css' '' ".chart-bar { height: 100%; border-radius: 6px; }" | Should Match 'one corner radius'
    }
    It 'leaves bars flat at the axis, other rounded parts and kit files alone' {
        Find-RoundedBarBase 'js/chart.js' '' 'ctx.roundRect(x, y, w, h, [6, 6, 0, 0]);' | Should BeNullOrEmpty
        Find-RoundedBarBase 'js/chart.js' '' "datasets: [{ data: d, borderRadius: 6 }]" | Should BeNullOrEmpty
        Find-RoundedBarBase 'css/app.css' '' ".chart-bar { border-radius: 0 6px 6px 0; }`n.progress-bar { border-radius: 9px; }`n.toolbar { border-radius: 8px; }" | Should BeNullOrEmpty
        Find-RoundedBarBase 'styles/kit/kit.css' '' ".kit-bar { border-radius: 6px; }" | Should BeNullOrEmpty
        Find-RoundedBarBase 'js/chart.js' 'ctx.roundRect(x, y, w, h, 6);' 'ctx.roundRect(x, y, w, h, 6); // same' | Should BeNullOrEmpty
    }
    It 'the kit draws bar lists flat at their start, and progress and status bars round at both ends' {
        $css = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.css'))
        foreach ($sel in 'kit-barlist__track', 'kit-barlist__fill') {
            [regex]::Match($css, "\.$sel \{[^}]*\}").Value | Should Match 'border-radius: 0 999px 999px 0'
        }
        foreach ($sel in 'kit-progress', 'kit-progress__bar') {
            [regex]::Match($css, "\.$sel \{[^}]*\}").Value | Should Match 'border-radius: 999px;'
        }
    }
}

Describe 'Chart colours from the preset' {
    It 'offers KitCharts.palette for code that needs colour values' {
        $charts = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit-charts.js'))
        $charts | Should Match 'api\.palette = function'
        $charts | Should Match '--kit-chart-'
    }
    It 'reports a palette a script puts together, with the kit' {
        $out = @(Find-QualityIssues -Rel 'js/chart.js' -Old '' -New "var c = 'hsl(' + (i * 40) + ', 70%, 50%)';" -UseKit) -join ' '
        $out | Should Match 'hard-coded colour'
        $out | Should Match 'KitCharts\.palette'
    }
}
