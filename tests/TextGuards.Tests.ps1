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
    }
    It 'leaves bars flat at the axis, other rounded parts and kit files alone' {
        Find-RoundedBarBase 'js/chart.js' '' 'ctx.roundRect(x, y, w, h, [6, 6, 0, 0]);' | Should BeNullOrEmpty
        Find-RoundedBarBase 'js/chart.js' '' "datasets: [{ data: d, borderRadius: 6 }]" | Should BeNullOrEmpty
        Find-RoundedBarBase 'css/app.css' '' ".chart-bar { border-radius: 0 6px 6px 0; }`n.progress-bar { border-radius: 9px; }`n.toolbar { border-radius: 8px; }" | Should BeNullOrEmpty
        Find-RoundedBarBase 'styles/kit/kit.css' '' ".kit-bar { border-radius: 6px; }" | Should BeNullOrEmpty
        Find-RoundedBarBase 'js/chart.js' 'ctx.roundRect(x, y, w, h, 6);' 'ctx.roundRect(x, y, w, h, 6); // same' | Should BeNullOrEmpty
    }
    It 'the kit draws bars in a track (bar lists, progress and status bars) round at both ends' {
        $css = [IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.css'))
        foreach ($sel in 'kit-progress', 'kit-progress__bar', 'kit-barlist__track', 'kit-barlist__fill') {
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

Describe 'Pages written with stand-ins for < and >' {
    It 'reports a page whose tags are stand-ins or escaped, not a normal page' {
        Find-PlaceholderMarkup 'index.html' "[[LT]]!doctype html[[GT]]`n[[LT]]html lang=`"en`"[[GT]]" | Should Match 'line 1: .*stand-in \[\[LT\]\]'
        Find-PlaceholderMarkup 'index.html' "&lt;!doctype html&gt;`n&lt;html&gt;" | Should Match 'escaped'
        Find-PlaceholderMarkup 'index.html' "<!doctype html>`n<p>Use &lt;b&gt; for bold</p>" | Should BeNullOrEmpty
        Find-PlaceholderMarkup 'Work/Write-Index.ps1' "`$html = @'`n[[LT]]div>`n  [[LT]]p class=`"kit-help`">[[LT]]/p>`n'@" | Should Match 'line 2: this script writes markup with the stand-in \[\[LT\]\].*delete this script'
        Find-PlaceholderMarkup 'js/app.js' "const lt = '<';" | Should BeNullOrEmpty
        (Test-FileContent 'index.html' "[[LT]]!doctype html>`n[[LT]]html>") -join ' ' | Should Match 'stand-in'
    }
    It 'repairs them into tags' {
        (Repair-MechanicalIssues 'index.html' "[[LT]]!doctype html>`n[[LT]]html lang=`"en`">`n[[LT]]head>[[LT]]meta charset=`"utf-8`">[[LT]]/head>").text | Should Be "<!doctype html>`n<html lang=`"en`">`n<head><meta charset=`"utf-8`"></head>"
        (Repair-MechanicalIssues 'index.html' "&lt;!doctype html&gt;`n&lt;html&gt;&lt;head&gt;&lt;meta charset=&quot;utf-8&quot;&gt;&lt;/head&gt;&lt;/html&gt;").text | Should Be "<!doctype html>`n<html><head><meta charset=`"utf-8`"></head></html>"
    }
    It 'reports String.Replace with a text and a [char] in PowerShell' {
        $ch = '[ch' + 'ar]'   # put together, so this test file does not hold the pattern itself
        (Test-FileContent 'Work/Write-Index.ps1' "`$html = 'x'`n`$html = `$html.Replace('[[LT]]', ${ch}60)`n") -join ' ' | Should Match "line 2: String\.Replace takes two texts"
        (Test-FileContent 'Work/Write-Index.ps1' "`$html = 'x'`n`$html = `$html.Replace('[[LT]]', [string]${ch}60)`n") -join ' ' | Should Not Match 'String\.Replace'
    }
}

Describe 'A command that ends with exit code 0 but printed PowerShell errors' {
    It 'names the first error' {
        Import-Module (Join-Path $root 'lib\Executor.psm1') -Force
        $ch = '[ch' + 'ar]'   # put together, so this test file does not hold the pattern itself
        $out = "Cannot convert argument `"oldChar`", with value: `"[[LT]]`", for `"Replace`" to type `"System.Char`": `"Cannot convert value`n`"[[LT]]`" to type `"System.Char`". Error: `"String must be exactly one character long.`"`"`nAt C:\p\Work\Write-Index.ps1:164 char:1`n+ `$html = `$html.Replace('[[LT]]', ${ch}60)`n+ ~~~~~`n    + CategoryInfo          : NotSpecified: (:) [], MethodException`n    + FullyQualifiedErrorId : MethodArgumentConversionInvalidCastArgument`n`nGenerated index.html."
        $n = Get-HiddenErrorNote $out
        $n | Should Match 'exit code 0, but PowerShell reported an error'
        $n | Should Match 'Cannot convert argument "oldChar"'
        $n | Should Match 'Write-Index\.ps1:164 char:1'
        Get-HiddenErrorNote "Generated index.html." | Should Be ''
    }
}

Describe 'Markup or script a page shows as text (Find-LeakedMarkup, AutoFix)' {
    $page = "<!doctype html>`n<html><head><meta charset=""utf-8""><title>T</title></head>`n<body class=""kit-page"">`n<div class=""kit-panel"">`n&lt;div class=""kit-panel__head""&gt;`n  &lt;h2 class=""kit-panel__title""&gt;Users&lt;/h2&gt;`n&lt;/div&gt;`n<pre><code>&lt;b&gt;sample&lt;/b&gt;</code></pre>`n<p>a &lt; b</p>`n</div>`n<script src=""x.js""></script>`n</body></html>"
    It 'names the line of a tag written with entities in the page text, not in a code sample, and writes the tag' {
        $f = @(Find-LeakedMarkup 'index.html' $page)
        $f.Count | Should Be 4
        $f[0].kind | Should Be 'entity'
        $f[0].message | Should Match '^line 5: the tag &lt;div class="kit-panel__head"&gt; is written with &lt; and &gt;, so the browser shows it as text'
        @(Test-FileContent 'index.html' $page | Where-Object { $_ -match 'written with &lt;' }).Count | Should Be 3   # the first three per file
        $r = Repair-MechanicalIssues 'index.html' $page
        $r.fixes -join ';' | Should Match '4 tag\(s\) written with &lt; and &gt;'
        $r.text | Should Match '(?m)^<div class="kit-panel__head">$'
        $r.text | Should Match '<pre><code>&lt;b&gt;sample&lt;/b&gt;</code></pre>'   # a code sample stays
        $r.text | Should Match '<p>a &lt; b</p>'                                      # a real entity stays
        @(Find-LeakedMarkup 'index.html' $r.text).Count | Should Be 0
    }
    It 'reports a </script> without its opening tag and puts <script> before the code above it' {
        $p = "<html><body>`n<div id=""app""></div>`n  const el = document.getElementById(""app"");`n  el.addEventListener(""click"", () => { go(); });`n</script>`n</body></html>"
        $f = @(Find-LeakedMarkup 'index.html' $p)
        $f.Count | Should Be 1
        $f[0].message | Should Match '^line 5: </script> without a <script> before it'
        $r = Repair-MechanicalIssues 'index.html' $p
        $r.fixes -join ';' | Should Match '1 <script> tag\(s\) put before code'
        $r.text | Should Match "<div id=""app""></div>`n<script>`n  const el"
        @(Find-LeakedMarkup 'index.html' $r.text).Count | Should Be 0
    }
    It 'reports script code outside any script block, and markup given to textContent in a script' {
        $p = "<html><body>`n<div id=""app""></div>`n<p>Click the button</p>`ndocument.getElementById(""app"").textContent = ""hi"";`n</body></html>"
        @(Find-LeakedMarkup 'index.html' $p)[0].message | Should Match '^line 4: script code outside any <script> block \(1 line\(s\), first: document\.getElementById'
        $js = "const p = document.getElementById(""x"");`np.textContent = ""<div class=\""a\"">"" + name + ""</div>"";`nq.innerHTML = ""<b>"" + n + ""</b>"";`nr.innerText = `"`<span>`${n}</span>`"`;`n"
        $f = @(Find-LeakedMarkup 'app.js' $js)
        $f.Count | Should Be 2
        $f[0].message | Should Match '^line 2: markup given to textContent'
        $f[1].message | Should Match '^line 4: markup given to innerText'
        @(Find-LeakedMarkup 'index.html' "<html><body><script>`nel.innerText = ""<b>x</b>"";`n</script></body></html>")[0].message | Should Match '^line 2: markup given to innerText'
        (Repair-MechanicalIssues 'app.js' $js).text | Should Be $js   # not a mechanical fix: Copilot chooses innerHTML or elements
    }
    It 'decodes code written with entities in JSX/TSX (generics, arrows, comparisons, component tags) and leaves JSX prose' {
        $tsx = "import { useState } from ""react"";`nexport function App() {`n  const [n, setN] = useState&lt;number&gt;(0);`n  const items = list.map((x) =&gt; x.id);`n  if (n &lt; 3) { go(); }`n  return (<div>`n    <p>Use &lt;b&gt; for bold</p>`n    &lt;Card title=""x"" /&gt;`n  </div>);`n}`n"
        $f = @(Find-LeakedMarkup 'App.tsx' $tsx)
        ($f | ForEach-Object { $_.line }) -join ',' | Should Be '3,4,5,8'
        $r = Repair-MechanicalIssues 'App.tsx' $tsx
        $r.text | Should Match 'useState<number>\(0\)'
        $r.text | Should Match '\(x\) => x\.id'
        $r.text | Should Match 'if \(n < 3\)'
        $r.text | Should Match '<Card title="x" />'
        $r.text | Should Match '<p>Use &lt;b&gt; for bold</p>'
    }
    It 'treats a tag written with entities in XAML, SVG, Vue and Svelte the same way, and leaves XML data alone' {
        $xaml = "<Window xmlns=""x""><StackPanel>`n&lt;Button Content=""Go""/&gt;`n<TextBlock Text=""a &lt; b""/>`n</StackPanel></Window>"
        @(Find-LeakedMarkup 'MainWindow.xaml' $xaml)[0].message | Should Match '^line 2: .* so the window shows it as text'
        (Repair-MechanicalIssues 'MainWindow.xaml' $xaml).text | Should Match "`n<Button Content=""Go""/>`n<TextBlock Text=""a &lt; b""/>"
        @(Find-LeakedMarkup 'App.vue' "<template>`n  &lt;Card /&gt;`n</template>`n<script>`nconst a = 1;`n</script>").Count | Should Be 1
        @(Find-LeakedMarkup 'feed.xml' "<rss><item><description>&lt;p&gt;html in data&lt;/p&gt;</description></item></rss>").Count | Should Be 0
    }
    It 'reports nothing for the kit examples page, the kit scripts and the React parts' {
        @(Find-LeakedMarkup 'kit-examples.html' ([IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit-examples.html')))).Count | Should Be 0
        @(Find-LeakedMarkup 'kit.js' ([IO.File]::ReadAllText((Join-Path $root 'templates\ui-kit\kit.js')))).Count | Should Be 0
        foreach ($f in Get-ChildItem (Join-Path $root 'templates\ui-kit\react') -Filter *.tsx) { @(Find-LeakedMarkup $f.Name ([IO.File]::ReadAllText($f.FullName))).Count | Should Be 0 }
    }
    It 'reports a tag that lost its < and puts it back, but not prose with a > in it' {
        $p = "<!doctype html>`n<html><body>`n<div class=""kit-panel"">`ndiv class=""kit-panel__head"">`n  h2 class=""kit-panel__title"">Users /h2>`n/div>`n<p>if a > b then c</p>`n<p>Totals: x > y</p>`nscript src=""js/app.js""></script>`n</div>`n</body></html>"
        $f = @(Find-LeakedMarkup 'index.html' $p)
        ($f | Where-Object { $_.kind -eq 'broken-tag' } | ForEach-Object { $_.line }) -join ',' | Should Be '4,5,5,6,9'
        @($f | Where-Object { $_.kind -eq 'stray-close' }).Count | Should Be 1   # the script's end tag, with its start gone
        $f[0].message | Should Match '^line 4: the tag div class="kit-panel__head"> is missing its <, so the browser shows it as text: write <div class='
        $r = Repair-MechanicalIssues 'index.html' $p
        $r.fixes -join ';' | Should Match '5 tag\(s\) that had lost their <'
        $r.text | Should Match "(?m)^<div class=""kit-panel__head"">`n  <h2 class=""kit-panel__title"">Users </h2>`n</div>$"
        $r.text | Should Match '<script src="js/app.js"></script>'
        $r.text | Should Match '<p>if a > b then c</p>'
        @(Find-LeakedMarkup 'index.html' $r.text).Count | Should Be 0
        @(Find-LeakedMarkup 'MainWindow.xaml' "<Window><StackPanel>`nButton Content=""Go""/>`n</StackPanel></Window>")[0].message | Should Match '^line 2: the tag Button Content="Go"/> is missing its <, so the window shows it as text'
    }
    It 'reports a tag that lost its > with its line and closes it, leaving multi-line tags and prose alone' {
        $p = "<!doctype html>`n<html><head><meta charset=""utf-8""></head><body>`n<div class=""kit-panel"">`n<div class=""kit-panel__head""`n  <h2 class=""kit-panel__title"">Users</h2>`n</div>`n<a`n  href=""x.html""`n  class=""kit-btn"">Open</a>`n<p>if a < b then c</p>`n<input type=""text"" disabled`n<img src=""a.png"" alt=""A""`n<script src=""js/app.js""></script>`n<br/`n<div class=""x""`nUsers</div>`n</div>`n</body></html>"
        $f = @(Find-LeakedMarkup 'index.html' $p)
        ($f | ForEach-Object { "$($_.kind):$($_.line)" }) -join ',' | Should Be 'lost-end:4,lost-end:11,lost-end:12,lost-end:14,lost-end:15'
        $f[0].message | Should Match '^line 4: the tag <div class="kit-panel__head" has no >, so the browser reads what follows, up to the next >, as attributes, and that text or tag is not on the page \(a script tag there never loads\): close it with > after <div class="kit-panel__head"$'
        $r = Repair-MechanicalIssues 'index.html' $p
        $r.fixes -join ';' | Should Match '5 tag\(s\) that had lost their > \(such as <div class="kit-panel__head"\) closed'
        $r.text | Should Match "(?m)^<div class=""kit-panel__head"">`n  <h2 class=""kit-panel__title"">Users</h2>$"
        $r.text | Should Match "(?m)^<input type=""text"" disabled>`n<img src=""a.png"" alt=""A"">`n<script src=""js/app.js""></script>`n<br/>`n<div class=""x"">`nUsers</div>$"
        $r.text | Should Match "(?m)^<a`n  href=""x.html""`n  class=""kit-btn"">Open</a>$"
        $r.text | Should Match '<p>if a < b then c</p>'
        @(Find-LeakedMarkup 'index.html' $r.text).Count | Should Be 0
        @(Test-FileContent 'index.html' $r.text).Count | Should Be 0
        @(Find-LeakedMarkup 'MainWindow.xaml' "<Window><StackPanel>`n<Button Content=""Go""`n<TextBlock Text=""Hi""/>`n</StackPanel></Window>")[0].message | Should Match '^line 2: the tag <Button Content="Go" has no >, so the window does not load \(not valid XML\)'
        @(Find-LeakedMarkup 'App.svelte' "<script>let a = 1;</script>`n{#if a <b}`n<p on:click={() => a < 3} class=""x"">x</p>`n{/if}").Count | Should Be 0
        @(Find-LeakedMarkup 'index.html' "<html><body>`n<p>Use <b>bold</b> and <code>a <b</code></p>`n<script>if (a <b) { x(); }</script>`n</body></html>").Count | Should Be 0
    }
    It 'has the page-side check for markup and script shown as text' {
        $js = Get-PageContentScript
        $js | Should Match 'kind: "leak"'
        $js | Should Match 'shows HTML markup as plain text'
        $js | Should Match 'shows script code as plain text'
        $js | Should Match 'has no >: the browser read what followed it'
    }
}
