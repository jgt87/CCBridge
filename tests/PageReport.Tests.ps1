# Check this page in full (lib/PageReport.psm1): the findings of every page-side check in every
# view, merged, grouped and written as one report, plus the fix list for Copilot. Edge is stood in
# for by -Run (what Invoke-PageCheckCapture returns). Made-up pages.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\PageReport.psm1') -Force -DisableNameChecking

$p = Join-Path $env:TEMP ('ccb-pagereport-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path (Join-Path $p 'dist')
[IO.File]::WriteAllText((Join-Path $p 'index.html'), '<!doctype html><title>x</title>')

# A tiny PNG (1x1), as Page.captureScreenshot would give.
$png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
$keyboard = 'has 1 clickable part a keyboard cannot reach (a pointer cursor, a click handler or role="button" on something that is not a button, link or focusable): div.card: make each a <button>'
$fake = {
    param($Port, $Url, $Page)
    @{
        loaded = $true
        problems = @(@{ kind = 'errors'; text = 'JavaScript error (app.js:3): TypeError: x is undefined' }, @{ kind = 'errors'; text = 'loads data.json: HTTP 404 (file not found): fix the path or add the file' })
        runs = @(
            @{ check = 'contrast'; view = 'light'; value = '[{"ratio":2.1,"need":4.5,"kind":"text","fg":"#999999","bg":"#ffffff","text":"Total","where":"td.kit-num","count":3},{"kind":"name","where":"button.kit-btn--icon","count":1}]' }
            @{ check = 'content'; view = 'light'; value = (ConvertTo-Json -Compress @(@{ kind = 'keyboard'; text = $keyboard }, @{ kind = 'kitcss'; classes = @('kit-tabel', 'kit-cardd') })) }
            @{ check = 'contrast'; view = 'dark'; value = '[]' }
            @{ check = 'content'; view = 'dark'; value = (ConvertTo-Json -Compress @(@{ kind = 'keyboard'; text = $keyboard })) }
            @{ check = 'narrow'; view = '375 px'; value = 'at phone width (375 px) the page scrolls sideways by 120 px: table.wide' }
            @{ check = 'content'; view = '375 px'; value = (ConvertTo-Json -Compress @(@{ kind = 'keyboard'; text = $keyboard }, @{ kind = 'escape'; text = 'has 1 part sticking out of their box: img.logo in div.kit-panel' })) }
        )
        shots = @(@{ view = 'light'; png = $png }, @{ view = 'dark'; png = $png }, @{ view = '375 px'; png = $png })
    }
}

Describe 'Page report names and entry page' {
    It 'makes a file-name part of a page' {
        Get-ReportName 'dist/index.html' | Should Be 'dist-index'
        Get-ReportName 'My Page.htm' | Should Be 'My-Page'
        Get-ReportName '' | Should Be 'page'
    }
    It 'picks the app entry as Open app does: a build first, then index.html' {
        Get-ReportEntryPage $p | Should Be 'index.html'
        [IO.File]::WriteAllText((Join-Path $p 'dist\index.html'), '<!doctype html>')
        Get-ReportEntryPage $p | Should Be 'dist/index.html'
        Remove-Item -LiteralPath (Join-Path $p 'dist\index.html')
    }
}

Describe 'What the page reports while it loads' {
    $seen = @{ base = 'http://localhost:9/preview/T/'; urls = @{} }
    $ev = { param($method, $params) [pscustomobject]@{ method = $method; params = [pscustomobject]$params } }
    It 'names failed loads by their path, but not the browser''s own favicon request' {
        $p = Get-PageEventProblem (& $ev 'Network.responseReceived' @{ response = [pscustomobject]@{ status = 404; url = 'http://localhost:9/preview/T/data/x.json' } }) $seen
        $p.text | Should Be 'loads data/x.json: HTTP 404 (file not found): fix the path or add the file'
        Get-PageEventProblem (& $ev 'Network.responseReceived' @{ response = [pscustomobject]@{ status = 404; url = 'http://localhost:9/favicon.ico' } }) $seen | Should BeNullOrEmpty
        $null = Get-PageEventProblem (& $ev 'Network.requestWillBeSent' @{ requestId = '7'; request = [pscustomobject]@{ url = 'http://localhost:9/preview/T/app.js' } }) $seen
        (Get-PageEventProblem (& $ev 'Network.loadingFailed' @{ requestId = '7'; canceled = $false; errorText = 'net::ERR_FAILED' }) $seen).text | Should Be 'could not load app.js: net::ERR_FAILED'
    }
    It 'words script errors, unguarded storage and console errors' {
        $ex = { param($desc) & $ev 'Runtime.exceptionThrown' @{ exceptionDetails = [pscustomobject]@{ exception = [pscustomobject]@{ description = $desc }; url = 'http://localhost:9/preview/T/app.js'; lineNumber = 2 } } }
        (Get-PageEventProblem (& $ex "TypeError: x is undefined`n    at f") $seen).text | Should Be 'JavaScript error (app.js:3): TypeError: x is undefined'
        (Get-PageEventProblem (& $ex "SecurityError: Failed to read the 'localStorage' property from 'Window'") $seen).text | Should Match '^reads localStorage \(app\.js:3\).+try/catch'
        (Get-PageEventProblem (& $ev 'Runtime.consoleAPICalled' @{ type = 'error'; args = @([pscustomobject]@{ value = 'boom' }) }) $seen).text | Should Be 'console error: boom'
        Get-PageEventProblem (& $ev 'Runtime.consoleAPICalled' @{ type = 'log'; args = @() }) $seen | Should BeNullOrEmpty
        Get-PageEventProblem (& $ev 'Log.entryAdded' @{ entry = [pscustomobject]@{ level = 'error'; source = 'network'; text = 'x' } }) $seen | Should BeNullOrEmpty
    }
}

Describe 'Merging the findings of every view' {
    $raw = & $fake 0 '' ''
    $all = @(ConvertTo-PageFindings $raw)
    $merged = @(Merge-PageFindings $all)

    It 'reads every check and keeps the view each finding showed in' {
        @($all | Where-Object { $_.kind -eq 'keyboard' }).Count | Should Be 3
        @($all | Where-Object { $_.kind -eq 'sideways' })[0].view | Should Be '375 px'
        @($all | Where-Object { $_.kind -eq 'errors' })[0].view | Should Be ''
    }
    It 'says the same finding once, with the views it showed in' {
        $kb = @($merged | Where-Object { $_.kind -eq 'keyboard' })
        $kb.Count | Should Be 1
        ($kb[0].views -join ',') | Should Be 'light,dark,375 px'
        @($merged | Where-Object { $_.kind -eq 'contrast' })[0].views -join ',' | Should Be 'light'
    }
    It 'puts page errors first and words contrast and kit classes with what to do' {
        $merged[0].kind | Should Be 'errors'
        $c = @($merged | Where-Object { $_.kind -eq 'contrast' })[0].text
        $c | Should Match "text 'Total' \(td\.kit-num\) is 2\.1:1, #999999 on #ffffff; WCAG AA needs 4\.5:1"
        $c | Should Match '\(3 places\)'
        @($merged | Where-Object { $_.kind -eq 'kitcss' })[0].text | Should Match 'kit-tabel, kit-cardd'
        @($merged | Where-Object { $_.kind -eq 'name' })[0].text | Should Match 'aria-label'
    }
    It 'names a view only when the finding depends on it' {
        Get-ViewNote @{ kind = 'contrast'; views = @('light') } | Should Be 'light'
        Get-ViewNote @{ kind = 'contrast'; views = @('light', 'dark') } | Should Be ''
        Get-ViewNote @{ kind = 'escape'; views = @('375 px') } | Should Be '375 px'
        Get-ViewNote @{ kind = 'sideways'; views = @('375 px') } | Should Be ''
        Get-ViewNote @{ kind = 'errors'; views = @() } | Should Be ''
    }
    It 'counts per kind for the summary line' {
        Format-PageReportSummary 'index.html' $merged | Should Be 'index.html: 8 findings (2 page errors, 1 contrast, 1 no name, 1 keyboard, 1 sticking out, 1 sideways scrolling, 1 kit classes)'
        Format-PageReportSummary 'index.html' @() | Should Match 'nothing found'
    }
}

Describe 'The report and the fix list' {
    $now = Get-Date '2026-10-25 14:03:05'
    $r = Invoke-PageReport -ProjectRoot $p -Page 'index.html' -Url 'http://localhost:1/preview/SECRET/index.html' -Port 0 -Run $fake -Now $now

    It 'writes one Markdown report with the screenshots beside it' {
        $r.path | Should Be '.streamhub/Reports/page-check-index-20261025-140305.md'
        $md = [IO.File]::ReadAllText((Join-Path $p '.streamhub\Reports\page-check-index-20261025-140305.md'))
        $md | Should Match '# Page check: index.html'
        $md | Should Match '\*\*index\.html: 8 findings'
        $md | Should Match '## Contrast \(WCAG AA\) \(1\)'
        $md | Should Match '## Parts a keyboard cannot reach \(1\)'
        $md | Should Match '_\(light\)_'
        $md | Should Not Match 'SECRET'
        $md | Should Match 'Dark, 1280 x 800: \.streamhub/Reports/page-check-index-20261025-140305-dark\.png'
        @($r.shots).Count | Should Be 3
        Test-Path (Join-Path $p '.streamhub\Reports\page-check-index-20261025-140305-375px.png') | Should Be $true
        $r.counts['keyboard'] | Should Be 1
    }
    It 'turns the findings into one numbered request for Copilot' {
        $r.fixRequest | Should Match '^A full check of index\.html'
        $r.fixRequest | Should Match "`n1\. \[Page and console errors\] JavaScript error"
        $r.fixRequest | Should Match '\[Contrast \(WCAG AA\), light\] text'
        $r.fixRequest | Should Match '\[Parts a keyboard cannot reach\] has 1 clickable'
        $r.fixRequest | Should Not Match 'StreamHub|CCBridge'
        $short = Get-PageReportFixRequest 'index.html' $r.findings -Max 2
        $short | Should Match '\(6 more of the same kinds'
    }
    It 'says plainly when nothing was found, and asks Copilot nothing' {
        $clean = Invoke-PageReport -ProjectRoot $p -Page 'index.html' -Url 'file:///x/index.html' -Run { @{ loaded = $true; problems = @(); runs = @(@{ check = 'narrow'; view = '375 px'; value = '' }); shots = @() } } -Now $now.AddSeconds(1)
        $clean.fixRequest | Should Be ''
        $clean.summary | Should Match 'nothing found'
        [IO.File]::ReadAllText((Join-Path $p ($clean.path.Replace('/', '\')))) | Should Match 'nothing found'
    }
    It 'says when the page did not load' {
        $md = Format-PageReport -Page 'a.html' -Findings @(@{ kind = 'errors'; text = 'did not finish loading within 8 seconds'; views = @() }) -Loaded $false
        $md | Should Match 'did not finish loading, so only what it reported'
    }
}

Describe 'PageReport module text' {
    It 'is ASCII only' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $root 'lib\PageReport.psm1'))
        @($bytes | Where-Object { $_ -gt 127 -or $_ -eq 8 }).Count | Should Be 0
    }
}

Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
