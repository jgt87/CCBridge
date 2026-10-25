# Check this page in full (on request only: the command menu). The page check during tasks
# (Agent Test-WebPageCore) runs the same page-side scripts but passes on only part of what they find,
# some of it once. This runs every one of them on one page, in the light and in the dark colour
# scheme at 1280 x 800 and at 375 px wide: lib/contrast-check.js (contrast, sizes, alignment, names),
# lib/page-content-check.js (what the page shows), lib/narrow-check.js (sideways scrolling), plus the
# errors the page itself reports while it loads. The findings are merged (the same finding in several
# views once, with the views named), grouped by kind and written as one Markdown report in
# .streamhub/Reports/, with the screenshots beside it; Get-PageReportFixRequest turns them into one
# request the person can send to Copilot as a fix list. Edge is driven over CDP
# (Invoke-PageCheckCapture); Invoke-PageReport takes -Run to stand it in (tests).
# ASCII only (Windows PowerShell 5.1).

Import-Module (Join-Path $PSScriptRoot 'Cdp.psm1')
Import-Module (Join-Path $PSScriptRoot 'Contrast.psm1')

# The kinds of findings in report order: the group title and the short word for the summary line.
$script:Kinds = [ordered]@{
    errors   = @{ title = 'Page and console errors'; short = 'page errors' }
    leak     = @{ title = 'Markup or code shown as text'; short = 'shown as text' }
    encoding = @{ title = 'Broken characters'; short = 'broken characters' }
    error    = @{ title = 'Error messages on the page'; short = 'error messages' }
    empty    = @{ title = 'Charts and tables that show nothing'; short = 'empty' }
    contrast = @{ title = 'Contrast (WCAG AA)'; short = 'contrast' }
    name     = @{ title = 'Parts without a name for screen readers'; short = 'no name' }
    keyboard = @{ title = 'Parts a keyboard cannot reach'; short = 'keyboard' }
    size     = @{ title = 'Sizes'; short = 'size' }
    align    = @{ title = 'Alignment'; short = 'alignment' }
    escape   = @{ title = 'Parts sticking out of their box'; short = 'sticking out' }
    sideways = @{ title = 'Sideways scrolling at 375 px'; short = 'sideways scrolling' }
    sort     = @{ title = 'Tables that cannot be sorted'; short = 'sorting' }
    bar      = @{ title = 'Bars and their percentages'; short = 'bars' }
    date     = @{ title = 'Dates'; short = 'dates' }
    number   = @{ title = 'Numbers'; short = 'numbers' }
    icons    = @{ title = 'Icons'; short = 'icons' }
    kitcss   = @{ title = 'UI kit classes without a style'; short = 'kit classes' }
    other    = @{ title = 'Other'; short = 'other' }
}

# Views, in the order they are named.
$script:Views = @('light', 'dark', '375 px')

function Get-ReportName([string]$Page) {
    # A file-name part for a page: dist/index.html -> dist-index.
    $n = ($Page.Replace('\', '/').TrimStart('/') -replace '(?i)\.html?$', '') -replace '[^\w.-]+', '-'
    $n = $n.Trim('-', '.')
    if ($n) { $n } else { 'page' }
}

function Get-ReportEntryPage([string]$ProjectRoot) {
    <# The page a project's app starts from, as Open app picks it (ui-src lib/app-entry.ts): a build's
       output before a plain index.html; else the first page at the root. '' when there is none. #>
    foreach ($p in 'dist/index.html', 'build/index.html', 'out/index.html', 'index.html') {
        if (Test-Path -LiteralPath (Join-Path $ProjectRoot $p.Replace('/', '\')) -PathType Leaf) { return $p }
    }
    $first = @(Get-ChildItem -LiteralPath $ProjectRoot -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.html?$' } | Sort-Object Name | Select-Object -First 1)
    if ($first.Count) { return $first[0].Name }
    ''
}

function Open-ReportEdge {
    <# An Edge to drive: StreamHub's own on $Port when it listens, else a headless one of its own on a
       free port with $ProfileDir. Returns @{ Port; Stop } (Stop ends only an Edge started here). #>
    param([int]$Port, [Parameter(Mandatory)][string]$ProfileDir)
    if ($Port -and (Test-CdpEndpoint $Port)) { return @{ Port = $Port; Stop = {} } }
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $free = $l.LocalEndpoint.Port; $l.Stop()
    $null = Start-CdpEdge -Port $free -ProfileDir $ProfileDir -Headless
    $prof = $ProfileDir
    $stop = {
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)" -like "*$prof*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }.GetNewClosure()
    @{ Port = $free; Stop = $stop }
}

function Get-PageEventProblem {
    <# One CDP event of the page as a problem @{ kind = 'errors'; text } (the same rules as the page
       check: failed loads but the browser's own favicon request, script errors, console and browser
       errors), or $null. $Seen: @{ base (the page's folder address); urls (request id -> address,
       filled here) }. #>
    param($M, $Seen)
    $rel = { param([string]$u) if ($u.StartsWith($Seen.base)) { [Uri]::UnescapeDataString($u.Substring($Seen.base.Length)) } else { ($u -replace '\?.*$', '') } }
    $p = $M.params
    switch ("$($M.method)") {
        'Network.requestWillBeSent' { $Seen.urls["$($p.requestId)"] = "$($p.request.url)"; return $null }
        'Network.responseReceived' {
            if ([int]$p.response.status -lt 400 -or "$($p.response.url)" -match '/favicon\.ico(\?|$)') { return $null }
            return @{ kind = 'errors'; text = "loads $(& $rel "$($p.response.url)"): HTTP $($p.response.status)$(if ($p.response.status -eq 404) { ' (file not found)' }): fix the path or add the file" }
        }
        'Network.loadingFailed' {
            $u = "$($Seen.urls["$($p.requestId)"])"
            if ($p.canceled -or $u -match '/favicon\.ico(\?|$)') { return $null }
            return @{ kind = 'errors'; text = "could not load $(& $rel $u): $($p.errorText)" }
        }
        'Runtime.exceptionThrown' {
            $d = $p.exceptionDetails
            $msg = if ($d.exception.description) { ($d.exception.description -split "`n")[0] } else { "$($d.text)" }
            $where = if ($d.url) { " ($(& $rel "$($d.url)"):$([int]$d.lineNumber + 1))" } else { '' }
            # The preview serves the page in a sandbox without storage (as a private window has none).
            if ($msg -match "Failed to read the '(local|session)Storage' property") { return @{ kind = 'errors'; text = "reads $($Matches[1])Storage$where, and storage is not available here (nor in a private window): wrap it in try/catch so the page works without it" } }
            return @{ kind = 'errors'; text = "JavaScript error$where`: $msg" }
        }
        'Runtime.consoleAPICalled' {
            if ($p.type -notin 'error', 'assert') { return $null }
            $text = (@($p.args) | ForEach-Object { if ($null -ne $_.value) { "$($_.value)" } elseif ($_.description) { $_.description } }) -join ' '
            return @{ kind = 'errors'; text = "console error: $($text.Substring(0, [Math]::Min(300, $text.Length)))" }
        }
        'Log.entryAdded' {
            if ($p.entry.level -ne 'error' -or $p.entry.source -eq 'network') { return $null }
            return @{ kind = 'errors'; text = "browser error: $($p.entry.text)" }
        }
    }
    $null
}

function Wait-CdpQuiet($Session, [int]$Ms, $Seen) {
    # Lets the page settle for $Ms, keeping the problems it reports meanwhile ($Seen.problems).
    $until = (Get-Date).AddMilliseconds($Ms)
    while ((Get-Date) -lt $until) {
        $m = Receive-CdpEvent $Session 50
        if (-not $m) { continue }
        $prob = Get-PageEventProblem $m $Seen
        if ($prob) { $Seen.problems.Add($prob) }
    }
}

function ConvertTo-CaptureResult($Raw) {
    # The capture's lists as plain arrays (@() around a List of hashtables throws in 5.1).
    @{ loaded = [bool]$Raw.loaded; problems = $Raw.problems.ToArray(); runs = $Raw.runs.ToArray(); shots = $Raw.shots.ToArray() }
}

function Add-PageViewRun($Session, $Raw, [string]$Check, [string]$View, [string]$Js, [switch]$Await) {
    # Runs one page-side check script in the tab and keeps its text; a check that fails is said.
    try {
        $p = @{ expression = $Js; returnByValue = $true }
        if ($Await) { $p.awaitPromise = $true }
        $Raw.runs.Add(@{ check = $Check; view = $View; value = "$((Invoke-Cdp $Session 'Runtime.evaluate' $p -TimeoutMs 30000).result.value)" })
    } catch { $Raw.problems.Add(@{ kind = 'other'; text = "the $Check check could not run in the $View view: $($_.Exception.Message)" }) }
}

function Add-PageViewShot($Session, $Raw, [string]$View) {
    # A screenshot of what the tab shows now (none when Edge cannot take one).
    try { $Raw.shots.Add(@{ view = $View; png = [Convert]::FromBase64String((Invoke-Cdp $Session 'Page.captureScreenshot' @{ format = 'png' } -TimeoutMs 15000).data) }) } catch { }
}

function Invoke-PageViewChecks($Session, $Raw) {
    <# Every check in every view of a loaded page: light and dark at 1280 x 800 (screenshot,
       contrast, what the page shows), then 375 px wide (screenshot, sideways scrolling, what the
       page shows there). #>
    # Fading colours would be measured halfway: no transitions or animations in this throwaway tab.
    $null = Invoke-Cdp $Session 'Runtime.evaluate' @{ expression = "(() => { const st = document.createElement('style'); st.textContent = '*, *::before, *::after { transition: none !important; animation: none !important; }'; document.head.appendChild(st); return ''; })()" }
    foreach ($view in 'light', 'dark') {
        $null = Invoke-Cdp $Session 'Emulation.setEmulatedMedia' @{ features = @(@{ name = 'prefers-color-scheme'; value = $view }) }
        Wait-CdpQuiet $Session 400 $Raw
        Add-PageViewShot $Session $Raw $view
        Add-PageViewRun $Session $Raw 'contrast' $view (Get-ContrastScript)
        # It clicks column headers to see whether tables sort, so it runs after the screenshot.
        Add-PageViewRun $Session $Raw 'content' $view (Get-PageContentScript) -Await
        Wait-CdpQuiet $Session 300 $Raw
    }
    # At phone width: sideways scrolling, and what sticks out of its box there.
    $null = Invoke-Cdp $Session 'Emulation.setEmulatedMedia' @{ features = @(@{ name = 'prefers-color-scheme'; value = 'light' }) }
    $null = Invoke-Cdp $Session 'Emulation.setDeviceMetricsOverride' @{ width = 375; height = 800; deviceScaleFactor = 1; mobile = $false }
    Wait-CdpQuiet $Session 600 $Raw
    Add-PageViewShot $Session $Raw '375 px'
    Add-PageViewRun $Session $Raw 'narrow' '375 px' (Get-NarrowScreenScript)
    Add-PageViewRun $Session $Raw 'content' '375 px' (Get-PageContentScript) -Await
    Wait-CdpQuiet $Session 300 $Raw
}

function Invoke-PageCheckCapture {
    <# Opens $Url in a new tab of the Edge on $Port and runs every page-side check in every view.
       Returns the raw results for ConvertTo-PageFindings: @{ loaded; problems = @(@{ kind; text });
       runs = @(@{ check = contrast|content|narrow; view; value (the script's text) });
       shots = @(@{ view; png (bytes) }) }. #>
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Url, [int]$WaitSec = 8)
    # One table for what the capture keeps: the problems, the check results, the screenshots, and
    # what Get-PageEventProblem needs to name addresses.
    $raw = @{
        loaded = $false; base = $Url.Substring(0, $Url.LastIndexOf('/') + 1); urls = @{}
        problems = (New-Object System.Collections.Generic.List[object]); runs = (New-Object System.Collections.Generic.List[object]); shots = (New-Object System.Collections.Generic.List[object])
    }
    $target = Invoke-RestMethod -Method Put "http://127.0.0.1:$Port/json/new?about:blank"
    $s = $null
    try {
        $s = Connect-Cdp $target.webSocketDebuggerUrl
        foreach ($m in 'Runtime.enable', 'Log.enable', 'Network.enable', 'Page.enable') { $null = Invoke-Cdp $s $m }
        $null = Invoke-Cdp $s 'Emulation.setDeviceMetricsOverride' @{ width = 1280; height = 800; deviceScaleFactor = 1; mobile = $false }
        $null = Invoke-Cdp $s 'Emulation.setEmulatedMedia' @{ features = @(@{ name = 'prefers-color-scheme'; value = 'light' }) }
        $null = Invoke-Cdp $s 'Page.navigate' @{ url = $Url }
        $loaded = $null
        $until = (Get-Date).AddSeconds($WaitSec)
        while ((Get-Date) -lt $until) {
            $m = Receive-CdpEvent $s 200
            if (-not $m) { if ($loaded -and ((Get-Date) - $loaded).TotalMilliseconds -gt 1500) { break }; continue }
            if ($m.method -eq 'Page.loadEventFired') { $loaded = Get-Date }
            $prob = Get-PageEventProblem $m $raw
            if ($prob) { $raw.problems.Add($prob) }
        }
        if ($loaded) { $raw.loaded = $true; Invoke-PageViewChecks $s $raw }
        else { $raw.problems.Add(@{ kind = 'errors'; text = "did not finish loading within $WaitSec seconds" }) }
        ConvertTo-CaptureResult $raw
    } finally {
        if ($s) { try { Disconnect-Cdp $s } catch { } }
        try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/json/close/$($target.id)" } catch { }
    }
}

function Format-ContrastFinding($F) {
    <# One contrast-check result (lib/contrast-check.js) as @{ kind; text }, with what to do. #>
    $times = if ([int]$F.count -gt 1) { " ($($F.count) places)" } else { '' }
    switch ("$($F.kind)") {
        'size' {
            $which = "$($F.where)$(if ($F.text) { " '$($F.text)'" })"; $other = "$($F.other)$(if ($F.otherText) { " '$($F.otherText)'" })"
            if ($F.scope -eq 'row') { return @{ kind = 'size'; text = "$which is $($F.h) px tall beside $other at $($F.otherH) px: controls side by side share one height, so remove the height, padding or font size that sets one apart$times" } }
            return @{ kind = 'size'; text = "$which is $($F.h) px tall while the same control elsewhere ($other) is $($F.otherH) px: give the same control one size everywhere$times" }
        }
        'align' { return @{ kind = 'align'; text = "$($F.where)$(if ($F.text) { " ('$($F.text)')" }) has its $($F.side) edge at $($F.at) px, $($F.off) px from the edge most of the page uses ($($F.main) px): line it up (same page width and side padding)$times" } }
        'name' { return @{ kind = 'name'; text = "$($F.where)$(if ($F.text) { " ($($F.text))" }) has no name for screen readers: add visible text, aria-label or alt$times" } }
        'border' { return @{ kind = 'contrast'; text = "the edge of the field $(if ($F.text) { "'$($F.text)' " })($($F.where)) is $($F.ratio):1, $($F.fg) on $($F.bg); WCAG AA needs $($F.need):1: give the field a stronger border colour$times" } }
        default { return @{ kind = 'contrast'; text = "text '$($F.text)' ($($F.where)) is $($F.ratio):1, $($F.fg) on $($F.bg); WCAG AA needs $($F.need):1: darken the text or change its background (with the UI kit, its text and surface tokens pass)$times" } }
    }
}

function ConvertTo-PageFindings {
    <# The raw results of a capture as findings: @(@{ kind; text; view }) (view '' for what the page
       reported while loading). #>
    param([Parameter(Mandatory)]$Raw)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Raw.problems)) { if ($p -and "$($p.text)") { $out.Add(@{ kind = $(if ($script:Kinds.Contains("$($p.kind)")) { "$($p.kind)" } else { 'other' }); text = "$($p.text)"; view = '' }) } }
    foreach ($r in @($Raw.runs)) {
        if (-not $r) { continue }
        $value = "$($r.value)"
        if ($r.check -eq 'narrow') {
            if ($value.Trim()) { $out.Add(@{ kind = 'sideways'; text = $value.Trim(); view = "$($r.view)" }) }
            continue
        }
        if (-not $value.Trim()) { continue }
        # ConvertFrom-Json passes a JSON list on as one object in a pipeline (5.1): assign first.
        $list = try { ConvertFrom-Json $value } catch { $null }
        foreach ($f in $list) {
            if (-not $f) { continue }
            if ($r.check -eq 'contrast') {
                $c = Format-ContrastFinding $f
                $out.Add(@{ kind = $c.kind; text = $c.text; view = "$($r.view)" })
                continue
            }
            if ("$($f.kind)" -eq 'kitcss') {
                $classes = @($f.classes | Where-Object { $_ } | Select-Object -First 12)
                if ($classes.Count) { $out.Add(@{ kind = 'kitcss'; text = "uses UI kit class(es) with no style rule in any stylesheet it loads: $($classes -join ', '): link the kit's stylesheet (styles/kit/kit.css), or use a class from the kit's examples (a misspelt or invented kit class has no style)"; view = "$($r.view)" }) }
                continue
            }
            if (-not "$($f.text)") { continue }
            $kind = if ($script:Kinds.Contains("$($f.kind)")) { "$($f.kind)" } else { 'other' }
            $out.Add(@{ kind = $kind; text = "$($f.text)"; view = "$($r.view)" })
        }
    }
    $out.ToArray()
}

function Merge-PageFindings {
    <# One finding per kind and text, with every view it showed up in (light, dark, 375 px), in report
       order: @(@{ kind; text; views = @() }). #>
    param($Findings)
    $byKey = [ordered]@{}
    foreach ($f in @($Findings)) {
        if (-not $f) { continue }
        $key = "$($f.kind)|$($f.text)"
        if (-not $byKey.Contains($key)) { $byKey[$key] = @{ kind = "$($f.kind)"; text = "$($f.text)"; views = (New-Object System.Collections.Generic.List[string]) } }
        if ("$($f.view)" -and -not $byKey[$key].views.Contains("$($f.view)")) { $byKey[$key].views.Add("$($f.view)") }
    }
    $all = @($byKey.Values)
    @(foreach ($k in @($script:Kinds.Keys)) {
        foreach ($f in $all) {
            if ($f.kind -ne $k) { continue }
            $views = @($f.views)
            @{ kind = $f.kind; text = $f.text; views = @($script:Views | Where-Object { $views -contains $_ }) }
        }
    })
}

function Get-ViewNote($Finding) {
    <# The views worth naming for a finding: '' when it showed in both colour schemes (it does not
       depend on the scheme) or the kind says the view already (sideways scrolling at 375 px). #>
    $views = @($Finding.views | Where-Object { $_ })
    if (-not $views.Count -or $Finding.kind -eq 'sideways' -or ($views -contains 'light' -and $views -contains 'dark')) { return '' }
    $views -join ', '
}

function Get-PageFindingCounts($Findings) {
    # Findings per kind, in report order (kinds with none left out).
    $counts = [ordered]@{}
    foreach ($k in $script:Kinds.Keys) {
        $n = @($Findings | Where-Object { $_ -and $_.kind -eq $k }).Count
        if ($n) { $counts[$k] = $n }
    }
    $counts
}

function Format-PageReportSummary([string]$Page, $Findings) {
    # "PAGE: 5 findings (2 contrast, 1 keyboard, ...)" or "PAGE: nothing found".
    $list = @($Findings | Where-Object { $_ })
    if (-not $list.Count) { return "${Page}: nothing found in light, dark or at 375 px wide" }
    $counts = Get-PageFindingCounts $list
    $parts = @(foreach ($k in $counts.Keys) { "$($counts[$k]) $($script:Kinds[$k].short)" })
    "${Page}: $($list.Count) finding$(if ($list.Count -ne 1) { 's' }) ($($parts -join ', '))"
}

function Format-PageReport {
    <# The report as Markdown: a summary line with counts, the findings grouped by kind (each with
       the views it showed in), and the screenshots. $Shots: @(@{ view; path }). #>
    param([Parameter(Mandatory)][string]$Page, $Findings = @(), $Shots = @(), [string]$Url = '', [datetime]$When = (Get-Date), [bool]$Loaded = $true)
    $list = @($Findings | Where-Object { $_ })
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("# Page check: $Page")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("Checked $($When.ToString('yyyy-MM-dd HH:mm')) in the light and the dark colour scheme at 1280 x 800, and at 375 px wide$(if ($Url) { ", from $($Url -replace '/preview/[^/]+/', '/preview/.../')" }).")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("**$(Format-PageReportSummary $Page $list)**")
    if (-not $Loaded) {
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('The page did not finish loading, so only what it reported while loading is here.')
    }
    foreach ($k in $script:Kinds.Keys) {
        $group = @($list | Where-Object { $_.kind -eq $k })
        if (-not $group.Count) { continue }
        $null = $sb.AppendLine()
        $null = $sb.AppendLine("## $($script:Kinds[$k].title) ($($group.Count))")
        $null = $sb.AppendLine()
        foreach ($f in $group) {
            $views = Get-ViewNote $f
            $tag = if ($views) { " _($views)_" } else { '' }
            $null = $sb.AppendLine("- $($f.text -replace "`r?`n", ' ')$tag")
        }
    }
    $shotList = @($Shots | Where-Object { $_ })
    if ($shotList.Count) {
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('## Screenshots')
        $null = $sb.AppendLine()
        foreach ($s in $shotList) {
            $label = switch ("$($s.view)") { 'light' { 'Light, 1280 x 800' } 'dark' { 'Dark, 1280 x 800' } '375 px' { 'Light, 375 px wide' } default { "$($s.view)" } }
            $null = $sb.AppendLine("- ${label}: $($s.path)")
        }
    }
    $sb.ToString()
}

function Get-PageReportFixRequest {
    <# The findings as one request for Copilot (a fix list), or '' when there is nothing to fix.
       At most $Max items; the rest are counted. #>
    param([Parameter(Mandatory)][string]$Page, $Findings = @(), [int]$Max = 30)
    $list = @($Findings | Where-Object { $_ })
    if (-not $list.Count) { return '' }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("A full check of $Page (in the light and the dark colour scheme, and at 375 px wide) found the problems below. Fix each one in the project's own files, then say per item what you changed or why it needs no change.")
    $lines.Add('')
    $i = 0
    foreach ($f in ($list | Select-Object -First $Max)) {
        $i++
        $views = Get-ViewNote $f
        $where = if ($views) { ", $views" } else { '' }
        $lines.Add("$i. [$($script:Kinds[$f.kind].title)$where] $($f.text -replace "`r?`n", ' ')")
    }
    if ($list.Count -gt $Max) { $lines.Add(''); $lines.Add("($($list.Count - $Max) more of the same kinds; after these are fixed the check can be run again.)") }
    $lines -join "`n"
}

function Invoke-PageReport {
    <# Checks $Page in full and writes .streamhub/Reports/page-check-NAME-STAMP.md with the
       screenshots beside it. $Run stands in for Edge: & $Run $Port $Url $Page returns what
       Invoke-PageCheckCapture returns. Returns @{ path; summary; findings; counts; fixRequest;
       shots (project-relative paths) }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Page, [Parameter(Mandatory)][string]$Url, [int]$Port, [scriptblock]$Run, [datetime]$Now = (Get-Date))
    $page = $Page.Replace('\', '/').TrimStart('/')
    $raw = if ($Run) { & $Run $Port $Url $page } else { Invoke-PageCheckCapture -Port $Port -Url $Url }
    $stem = "page-check-$(Get-ReportName $page)-$($Now.ToString('yyyyMMdd-HHmmss'))"
    $dir = Join-Path $ProjectRoot '.streamhub\Reports'
    $null = New-Item -ItemType Directory -Force -Path $dir
    $shots = @(foreach ($s in @($raw.shots)) {
        if (-not $s -or -not $s.png) { continue }
        $file = "$stem-$(("$($s.view)" -replace '[^\w]+', '').ToLowerInvariant()).png"
        [IO.File]::WriteAllBytes((Join-Path $dir $file), [byte[]]$s.png)
        @{ view = "$($s.view)"; path = ".streamhub/Reports/$file" }
    })
    $findings = @(Merge-PageFindings (ConvertTo-PageFindings $raw))
    $md = Format-PageReport -Page $page -Findings $findings -Shots $shots -Url $Url -When $Now -Loaded ([bool]$raw.loaded)
    $rel = ".streamhub/Reports/$stem.md"
    [IO.File]::WriteAllText((Join-Path $dir "$stem.md"), $md, (New-Object Text.UTF8Encoding($false)))
    @{
        path = $rel; summary = (Format-PageReportSummary $page $findings); findings = $findings
        counts = (Get-PageFindingCounts $findings); fixRequest = (Get-PageReportFixRequest $page $findings)
        shots = @($shots | ForEach-Object { $_.path })
    }
}

Export-ModuleMember -Function Get-ReportName, Get-ReportEntryPage, Open-ReportEdge, Get-PageEventProblem, Invoke-PageCheckCapture, Format-ContrastFinding, ConvertTo-PageFindings, Merge-PageFindings, Get-ViewNote, Get-PageFindingCounts, Format-PageReportSummary, Format-PageReport, Get-PageReportFixRequest, Invoke-PageReport
