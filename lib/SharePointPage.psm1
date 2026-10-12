# SharePoint HTML pages: a project whose setup says its page is opened as an HTML page in SharePoint
# (ProjectSetup question audience = sharepoint). SharePoint shows such a page in a sandboxed frame
# under a strict Content-Security-Policy, and what breaks it fails silently (a blank or half-drawn
# page): one .html file of at most 10 MB, every script and style inline, images and fonts only as
# data: or blob: addresses, no network (fetch, XHR, WebSocket...), no browser storage, no frames,
# workers, objects or form posts, no history.pushState, alert/confirm/prompt do nothing, links open
# in a new tab. SharePoint data reaches the page only through its LiveData manifest
# (<script type="application/json" class="ka-livedata-manifest">), which SharePoint reads with the
# viewer's access before the page's scripts run and hands over as window.__LD_RESULTS__.
#   Find-SharePointPageIssues  - what a change adds that SharePoint blocks (the round's file check)
#   Get-SharePointPolicy       - the same rules as a CSP for the page check (Server Send-PreviewFile)
#   Get-LiveDataStandIn        - window.__LD_RESULTS__ from project files, for the page check
# ASCII only (Windows PowerShell 5.1).

Import-Module (Join-Path $PSScriptRoot 'OneFile.psm1')
Import-Module (Join-Path $PSScriptRoot 'ProjectSetup.psm1')

$script:MaxPageBytes = 10MB
$script:MaxLiveItems = 32
# SharePoint's policy for HTML pages (its viewer adds frame-src 'none' and sandbox allow-scripts).
$script:Policy = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data: blob:; font-src data: blob:; connect-src 'none'; worker-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'"

function Test-SharePointPageProject([string]$ProjectRoot) {
    # The project's pages are opened as SharePoint HTML pages (its setup answer).
    if (-not $ProjectRoot) { return $false }
    try { "$((Get-ProjectSetup $ProjectRoot).answers['audience'])" -eq 'sharepoint' } catch { $false }
}

function Get-SharePointPolicy { $script:Policy }

function Get-ScriptBlocks([string]$Text) {
    # The inline <script> blocks that hold code (not JSON or templates): @(@{ index; code }).
    @(foreach ($m in [regex]::Matches($Text, '(?is)<script\b([^>]*)>(.*?)</script\s*>')) {
        $attrs = $m.Groups[1].Value
        if ($attrs -match '(?i)\bsrc\s*=' -or $attrs -match '(?i)\btype\s*=\s*["'']?(application/(ld\+)?json|text/(template|html|x-template))') { continue }
        @{ index = $m.Groups[2].Index; code = $m.Groups[2].Value }
    })
}

function Get-LiveDataManifest([string]$Text) {
    <# The LiveData manifest blocks: @(@{ index; json; items; error }), items parsed (an array). #>
    @(foreach ($m in [regex]::Matches($Text, '(?is)<script\b[^>]*\bclass\s*=\s*["''][^"'']*\bka-livedata-manifest\b[^"'']*["''][^>]*>(.*?)</script\s*>')) {
        $json = $m.Groups[1].Value.Trim()
        $items = $null; $err = ''
        # ConvertFrom-Json hands a JSON array over as one object in 5.1: enumerate it.
        try { $parsed = ConvertFrom-Json $json -ErrorAction Stop; $items = @($parsed | ForEach-Object { $_ }) } catch { $err = $_.Exception.Message }
        if (-not $err -and $json -notmatch '^\[') { $err = 'it is not a JSON array' }
        @{ index = $m.Groups[1].Index; json = $json; items = @($items); error = $err }
    })
}

function Get-SharePointPageFindings([AllowEmptyString()][string]$Text) {
    <# What SharePoint's HTML page viewer blocks or loses in a page: "line N: ..." per kind, once each.
       The helper program's filled one-file blocks (the UI kit, the data) are left out: they are
       inline already. #>
    $raw = "$Text"
    $t = Hide-GeneratedBlocks $raw
    $out = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $lineOf = { param($i) ([regex]::Matches($t.Substring(0, [Math]::Min($i, $t.Length)), "`n")).Count + 1 }
    $add = { param($key, $index, $msg) if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $out.Add("line $(& $lineOf $index): $msg") } }
    $remote = '(?i)^\s*(?!data:|blob:|#)'
    # Files and addresses a page loads.
    foreach ($m in [regex]::Matches($t, '(?is)<script\b[^>]*\bsrc\s*=\s*["'']?([^"''\s>]+)')) {
        if ($m.Groups[1].Value -match $remote) { & $add 'script' $m.Index "loads a script from a file or address ($($m.Groups[1].Value)): a SharePoint HTML page blocks every script src and shows nothing of it. Put the code inline in a <script> block (the UI kit and the data come inline through the helper program's blocks)." }
    }
    foreach ($m in [regex]::Matches($t, '(?is)<link\b[^>]*>')) {
        $h = [regex]::Match($m.Value, '(?i)\bhref\s*=\s*["'']?([^"''\s>]+)')
        if ($h.Success -and $h.Groups[1].Value -match $remote -and $m.Value -match '(?i)\brel\s*=\s*["'']?[^"''>]*\b(stylesheet|preload|modulepreload|icon|manifest)\b') { & $add 'link' $m.Index "loads a stylesheet or file with <link> ($($h.Groups[1].Value)): SharePoint HTML pages block it. Put the styles inline in a <style> block; an icon or manifest is not needed." }
    }
    foreach ($m in [regex]::Matches($t, '(?is)<(img|source|video|audio|track|input|image|use)\b[^>]*\b(src|srcset|poster|href|xlink:href)\s*=\s*["'']?([^"''\s>]+)')) {
        if ($m.Groups[3].Value -match $remote) { & $add 'img' $m.Index "shows an image or media file from a file or address ($($m.Groups[3].Value)): SharePoint HTML pages only show images as data: addresses (base64 in the page) or inline SVG and canvas; video and audio are not supported. Embed the image as a data: address or draw it as SVG." }
    }
    foreach ($m in [regex]::Matches($t, '(?is)(@import\b[^;]*|url\(\s*["'']?)(?!data:|blob:|#)([^"''\s\)]+)')) {
        if ($m.Value -match '(?i)^url\(\s*["'']?(data:|blob:|#)') { continue }
        & $add 'cssurl' $m.Index "a stylesheet loads a file or address ($($m.Groups[2].Value)) with @import or url(): SharePoint HTML pages block it (fonts and images only as data: addresses). Embed it as a data: address, use a system font stack, or leave it out."
    }
    foreach ($m in [regex]::Matches($t, '(?is)<(iframe|frame|object|embed|portal)\b')) { & $add 'frame' $m.Index "uses <$($m.Groups[1].Value.ToLowerInvariant())>: SharePoint HTML pages block frames, objects and embeds (Power BI, Forms, video players do not load). Link to it instead; the link opens in a new tab." }
    foreach ($m in [regex]::Matches($t, '(?is)<form\b[^>]*\baction\s*=')) { & $add 'form' $m.Index "a form posts to an address: SharePoint HTML pages cannot submit forms or write anything back. Handle the input in the page's own script (nothing is saved), or leave the form out." }
    foreach ($m in [regex]::Matches($t, '(?i)\bhref\s*=\s*["'']?\s*(javascript|vbscript|data):')) { & $add 'jshref' $m.Index "a link with a $($m.Groups[1].Value): address: SharePoint HTML pages reject it. Use a button with an event listener." }
    # The page's own scripts.
    foreach ($b in @(Get-ScriptBlocks $t)) {
        $c = $b.code
        $at = { param($m) $b.index + $m.Index }
        $m = [regex]::Match($c, '(?<![\w.$])(fetch\s*\(|new\s+XMLHttpRequest\b|new\s+WebSocket\b|new\s+EventSource\b|navigator\.sendBeacon\b|\$\.(ajax|get|getJSON|post)\s*\(|axios\b|DataTools\.load\s*\()')
        $what = $m.Value.Trim() -replace '\s*\($', ''
        if ($m.Success) { & $add 'net' (& $at $m) "reads data over the network ($what): SharePoint HTML pages block every request (fetch, XHR, WebSocket), also to SharePoint and Microsoft Graph. Put the data in the page (the helper program's data block) or read SharePoint files and lists through the LiveData manifest (window.__LD_RESULTS__)." }
        $m = [regex]::Match($c, '(?<![\w.$])(import\s*\(|import\s+[\w{*][^;]*\bfrom\b|new\s+(Shared)?Worker\s*\(|navigator\.serviceWorker\b)')
        $what = $m.Value.Trim() -replace '\s*\($', ''
        if ($m.Success) { & $add 'module' (& $at $m) "loads code at run time ($what): SharePoint HTML pages block module imports and workers. Put all code inline in plain <script> blocks." }
        $m = [regex]::Match($c, '\bhistory\.(pushState|replaceState)\s*\(')
        if ($m.Success) { & $add 'history' (& $at $m) "calls history.$($m.Groups[1].Value): it throws in a SharePoint HTML page and stops the script there. Keep state in location.hash instead (it also survives a refresh)." }
        $m = [regex]::Match($c, '(?<![\w.$])(window\.open\s*\(|(window\.)?location\.(assign|replace)\s*\(|(window\.)?location(\.href)?\s*=(?!=))')
        $what = $m.Value.Trim() -replace '\s*\($', ''
        if ($m.Success) { & $add 'nav' (& $at $m) "navigates from script ($what): a SharePoint HTML page cannot open windows or leave the page. Use a plain <a href> link (SharePoint opens it in a new tab), or location.hash within the page." }
        $m = [regex]::Match($c, '(?<![\w.$])(window\.)?(alert|confirm|prompt)\s*\(')
        if ($m.Success) { & $add 'dialog' (& $at $m) "calls $($m.Groups[2].Value)(): it does nothing in a SharePoint HTML page (a SharePoint page note). Show a message in the page instead (KitUI.confirm, KitUI.alert or a kit-notice with the UI kit)." }
        $m = [regex]::Match($c, '(?<![\w$])(localStorage|sessionStorage|indexedDB|document\.cookie)\b')
        if ($m.Success) { & $add 'storage' (& $at $m) "uses $($m.Groups[1].Value): a SharePoint HTML page has no browser storage, so it is lost (a SharePoint page note). Keep a choice in location.hash, or leave it out." }
    }
    # LiveData: the only way to SharePoint data.
    $items = 0
    foreach ($man in @(Get-LiveDataManifest $t)) {
        if ($man.error) { & $add 'ldjson' $man.index "the LiveData manifest is not valid: $($man.error). It is a JSON array of { ""spItemUrl"": ""https://HOST/_api/v2.0/drives/DRIVE-ID/items/ITEM-ID"", ""fileName"": ""NAME.csv"" } (or a list: ""kind"": ""list"", ""webUrl"", ""listId"")."; continue }
        foreach ($it in @($man.items)) {
            $items++
            $url = "$($it.spItemUrl)"
            if ("$($it.kind)" -eq 'list') {
                if (-not $it.webUrl -or -not $it.listId) { & $add 'ldlist' $man.index 'a LiveData list item needs webUrl (the site address) and listId (the list''s id).' }
                continue
            }
            if ($url -notmatch '/drives/[^/\s]+/items/[^/\s?#]+') { & $add 'ldurl' $man.index "a LiveData item's spItemUrl ($url) has no /drives/DRIVE-ID/items/ITEM-ID part: SharePoint reads only those ids. Ask the user for the file's link and resolve it, or leave the address for the user to fill in." }
            elseif ($url -match '\{|\}|(?i)contoso|DRIVE-ID|ITEM-ID') { & $add 'ldfake' $man.index "a LiveData item's spItemUrl ($url) is a placeholder: the page shows no data until it holds the real file's drive and item id (a SharePoint page note). Tell the user which file to link." }
            if ("$($it.fileName)" -notmatch '\.(csv|tsv|txt|xlsx|xlsm|json|md)$') { & $add 'ldname' $man.index "a LiveData item needs fileName with the file's extension (such as NAME.csv or NAME.xlsx): SharePoint picks the reader (csv, text or the sheets of a workbook) by it." }
        }
    }
    if ($items -gt $script:MaxLiveItems) { & $add 'ldmax' 0 "the LiveData manifest lists $items items: SharePoint allows $script:MaxLiveItems per page and drops all results above that." }
    if ($t -match '__LD_RESULTS__' -and $t -notmatch '\.error\b|\[[''"]error[''"]\]|errorCode') {
        & $add 'lderr' ([regex]::Match($t, '__LD_RESULTS__').Index) "the page reads window.__LD_RESULTS__ without handling an item's error: an item SharePoint could not read (no access, not found) has error and errorCode instead of content (a SharePoint page note). Show that in the page, with an empty state when there are no rows."
    }
    # Size: the whole file as SharePoint stores it, the helper program's blocks included.
    $bytes = [Text.Encoding]::UTF8.GetByteCount($raw)
    if ($bytes -gt $script:MaxPageBytes) { & $add 'size' 0 "the page is $([Math]::Round($bytes / 1MB, 1)) MB: SharePoint HTML pages hold at most 10 MB. Put large data in a SharePoint file read through LiveData, use fewer or smaller embedded images, and only the kit parts the page needs." }
    @($out)
}

function Find-SharePointPageIssues {
    <# The SharePoint findings a change adds to a page (the round's file check, for a project whose
       pages are SharePoint HTML pages). #>
    param([Parameter(Mandatory)][string]$Rel, [AllowEmptyString()][string]$Old, [AllowEmptyString()][string]$New)
    if ($Rel -notmatch '(?i)\.html?$' -or $Rel -match '(?i)(^|/)(styles/kit|\.streamhub|node_modules|Source|Work)/') { return @() }
    $before = @(Get-SharePointPageFindings $Old | ForEach-Object { $_ -replace '^line \d+: ', '' })
    @(Get-SharePointPageFindings $New | Where-Object { $before -notcontains ($_ -replace '^line \d+: ', '') })
}

function ConvertTo-CsvLine([string[]]$Cells) {
    (@($Cells | ForEach-Object { $v = "$_"; if ($v -match '[",\r\n]') { '"' + $v.Replace('"', '""') + '"' } else { $v } })) -join ','
}

function Get-LiveDataStandIn {
    <# For the page check of a SharePoint HTML page: window.__LD_RESULTS__ as SharePoint would hand it
       over, from the project's own files of the manifest's file names (the user's export of the same
       file), so the page draws with real data. A list, or a file the project does not have, gets the
       error SharePoint gives for a file it cannot read. Returns a <script> block, or '' when the page
       has no manifest. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [AllowEmptyString()][string]$Html)
    $mans = @(Get-LiveDataManifest $Html | Where-Object { -not $_.error })
    if (-not $mans.Count) { return '' }
    $files = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(\.streamhub|node_modules|\.git)\\' })
    $results = [ordered]@{}
    foreach ($it in @($mans | ForEach-Object { $_.items })) {
        $key = "$($it.spItemUrl)"
        if (-not $key -or $results.Contains($key)) { continue }
        $name = "$($it.fileName)"
        $ext = [IO.Path]::GetExtension($name).ToLowerInvariant()
        $entry = [ordered]@{ spItemUrl = $key; metadata = [ordered]@{ fileName = $name; extension = $ext.TrimStart('.') } }
        if ("$($it.kind)" -eq 'list') {
            $entry.format = 'rows'; $entry.error = 'a SharePoint list is only read on SharePoint (the helper program''s preview has no copy of it)'; $entry.errorCode = 'not-found'
        } else {
            $f = $files | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
            $entry.format = if ($ext -in '.xlsx', '.xlsm') { 'xlsx-sheets' } elseif ($ext -in '.csv', '.tsv') { 'csv' } else { 'text' }
            if (-not $f) { $entry.error = "the project has no file named $name to stand in for the SharePoint file"; $entry.errorCode = 'not-found' }
            elseif ($f.Length -gt 50MB) { $entry.error = 'the file is over 50 MB'; $entry.errorCode = 'fetch-failed' }
            else {
                try {
                    if ($entry.format -eq 'xlsx-sheets') {
                        Import-Module (Join-Path $PSScriptRoot 'Office.psm1')
                        $blocks = foreach ($sh in @(Read-XlsxSheets $f.FullName 100000 | Where-Object { $_.state -notin 'hidden', 'veryHidden' })) {
                            $csv = if (@($sh.rows).Count) { (@($sh.rows) | ForEach-Object { ConvertTo-CsvLine @($_) }) -join "`n" } else { '(empty sheet)' }
                            "<sheet name=""$($sh.name)"">`n$csv`n</sheet>"
                        }
                        $entry.content = @($blocks) -join "`n`n"
                    } else { $entry.content = [IO.File]::ReadAllText($f.FullName) }
                } catch { $entry.Remove('content'); $entry.error = "the file could not be read: $($_.Exception.Message)"; $entry.errorCode = 'decode-failed' }
            }
        }
        $results[$key] = $entry
    }
    $json = (ConvertTo-Json -InputObject $results -Depth 6 -Compress).Replace('</', '<\/')
    "<script>window.__LD_RESULTS__ = $json;</script>"
}

function Add-LiveDataStandIn([string]$Html, [string]$Script) {
    # The stand-in before the page's first script (SharePoint sets it before the page's scripts run).
    if (-not $Script) { return $Html }
    $m = [regex]::Match($Html, '(?i)<script\b')
    if ($m.Success) { return $Html.Insert($m.Index, $Script) }
    $h = [regex]::Match($Html, '(?i)</head>')
    if ($h.Success) { return $Html.Insert($h.Index, $Script) }
    $Script + $Html
}

Export-ModuleMember -Function Test-SharePointPageProject, Get-SharePointPolicy, Get-LiveDataManifest, Get-SharePointPageFindings, Find-SharePointPageIssues, Get-LiveDataStandIn, Add-LiveDataStandIn
