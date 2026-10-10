# When the person reports that a page shows its markup or script as text (Prompts Test-LeakReport),
# the helper program checks the pages itself (Agent Get-LeakReport): fixes what has one right answer
# and names the lines for Copilot.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-state-' + [guid]::NewGuid().ToString('N'))
foreach ($m in 'Prompts', 'Executor', 'Lint', 'AutoFix', 'Agent', 'Config') { Import-Module (Join-Path $root "lib\$m.psm1") -Force }

Describe 'Test-LeakReport' {
    It 'recognises a report of markup or script shown as text, in English and Dutch' {
        foreach ($t in @('script leaked into the page', 'the html is shown as plain text on the dashboard', 'I see raw html on the page', 'the page shows the javascript as text',
                'the code of the chart is visible on the screen', 'the tags appear as text in the panel', 'de html wordt als tekst getoond', 'het script is zichtbaar op de pagina',
                'Why does the page print the script instead of running it?')) {
            Test-LeakReport $t | Should Be $true
        }
    }
    It 'does not take a request to add, show or export code for one' {
        foreach ($t in @('add a script that exports the table', 'show me the code for the chart', 'make the text larger', 'write the html for a settings page',
                'print the report as text', 'can you add tags to the posts', 'fix the sort on the table', '')) {
            Test-LeakReport $t | Should Be $false
        }
    }
}

Describe 'Get-LeakReport' {
    $mk = {
        $p = Join-Path $env:TEMP ('ccb-leak-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory (Join-Path $p 'js') -Force | Out-Null
        $s = New-AgentState -Config (Get-CCBridgeConfig harness $root) -AppRoot $root
        $s.ProjectRoot = $p; $s.Headless = $true; $s.PreviewPort = 0
        @{ p = $p; s = $s }
    }
    It 'fixes tags written with entities itself, names the textContent line for Copilot, and tells the person' {
        $x = & $mk; $p = $x.p; $s = $x.s
        [IO.File]::WriteAllText((Join-Path $p 'index.html'), "<!doctype html>`n<html><head><meta charset=""utf-8""><title>T</title></head>`n<body>`n<div id=""app"">`n&lt;div class=""kit-panel""&gt;`n  &lt;h2&gt;Users&lt;/h2&gt;`n&lt;/div&gt;`n</div>`n<script src=""js/app.js""></script>`n</body></html>")
        [IO.File]::WriteAllText((Join-Path $p 'js\app.js'), "const el = document.getElementById('app');`nel.textContent = '<p class=""note"">' + name + '</p>';`n")
        $r = Get-LeakReport $s
        $r | Should Match '^THE HELPER PROGRAM CHECKED FOR MARKUP OR SCRIPT SHOWN AS TEXT'
        $r | Should Match 'Fixed already \(read a file again before you edit it\):\n- index\.html: 4 tag\(s\) written with &lt; and &gt;'
        $r | Should Match 'Still to fix, at these lines:\n- js/app\.js line 2: markup given to textContent'
        $r | Should Not Match 'CCBridge|StreamHub'
        [IO.File]::ReadAllText((Join-Path $p 'index.html')) | Should Match "(?m)^<div class=""kit-panel"">`n  <h2>Users</h2>`n</div>$"
        $ev = @($s.Events | Where-Object { $_.type -eq 'action' -and $_.by -eq 'streamhub' })
        $ev.Count | Should Be 1
        $ev[0].target | Should Be 'index.html'
        @($s.Events | Where-Object { $_.type -eq 'status' })[-1].text | Should Match 'StreamHub checked 2 page and script file\(s\) for markup or script shown as text: 1 file\(s\) fixed, 1 place\(s\) left for Copilot\.'
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'says so when the files hold nothing, pointing at scripts that write the page at run time' {
        $x = & $mk; $p = $x.p; $s = $x.s
        [IO.File]::WriteAllText((Join-Path $p 'index.html'), "<!doctype html>`n<html><head><meta charset=""utf-8""><title>T</title></head><body><div id=""app""></div><script src=""js/app.js""></script></body></html>")
        [IO.File]::WriteAllText((Join-Path $p 'js\app.js'), "document.getElementById('app').innerHTML = rows.map((r) => '<p>' + r + '</p>').join('');`n")
        $r = Get-LeakReport $s
        $r | Should Match 'found no tag written with entities, no script outside a script block and no markup given to textContent'
        $r | Should Match 'read the script that fills that part of the page'
        @($s.Events | Where-Object { $_.type -eq 'action' }).Count | Should Be 0
        Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'traces a sample the page shows to the file and line that writes it, as written or escaped' {
        $texts = @{ 'index.html' = "<html>`n<body>`n&lt;div class=""a""&gt;Users&lt;/div&gt;`n</body></html>"; 'js/app.js' = "x = 1;`nel.textContent = ""<p class=\""note\"">"" + n;`n" }
        Find-TextInFiles $texts '<div class="a">Users</div>' | Should Be 'index.html line 3'
        Find-TextInFiles $texts '<p class="note">Sam' | Should Be 'js/app.js line 2'
        Find-TextInFiles $texts 'nothing like this' | Should Be $null
    }
}

Remove-Item $env:CCBRIDGE_STATE_ROOT -Recurse -Force -ErrorAction SilentlyContinue
