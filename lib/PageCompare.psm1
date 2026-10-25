# Compare a page with an earlier version (on request only: a change set's card in History). The
# "before" view is a temporary copy of the project under %TEMP% in which every file that change set
# or a later one touched is put back as the earliest of those sets kept it (a file the set created is
# left out), so the styles and scripts the page loads match that moment too; the real project is never
# touched. Both the copy and the project are served by a small read-only server of their own
# (Start-PageServer, localhost only, GET only) so module scripts and data loads work as they do on
# the preview, photographed at 1280 x 800 in the light colour scheme (Save-PageShot), compared with
# ShotDiff (Compare-Screenshots, Format-ShotComparison, New-ShotCrop) and written to
# .streamhub/Reports/compare-NAME-STAMP.md with the pictures beside it. Invoke-PageCompare takes
# -Shoot to stand Edge in (tests). ASCII only (Windows PowerShell 5.1).

Import-Module (Join-Path $PSScriptRoot 'Cdp.psm1')
Import-Module (Join-Path $PSScriptRoot 'Workspace.psm1')
Import-Module (Join-Path $PSScriptRoot 'ShotDiff.psm1')
Import-Module (Join-Path $PSScriptRoot 'PageReport.psm1')

# Folders the before copy leaves out: packages, version control and StreamHub's own records.
$script:CopySkip = @('node_modules', '.git', '.streamhub', '.svn', '.hg')
$script:CopyMaxFileBytes = 100MB
$script:CopyMaxTotalBytes = 1GB
$script:CopyPrefix = 'streamhub-compare-'

$script:ServedTypes = @{
    '.html' = 'text/html; charset=utf-8'; '.htm' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.mjs' = 'text/javascript; charset=utf-8'
    '.cjs' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.json' = 'application/json; charset=utf-8'; '.map' = 'application/json; charset=utf-8'
    '.csv' = 'text/csv; charset=utf-8'; '.tsv' = 'text/tab-separated-values; charset=utf-8'; '.txt' = 'text/plain; charset=utf-8'; '.md' = 'text/plain; charset=utf-8'
    '.xml' = 'application/xml'; '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'
    '.webp' = 'image/webp'; '.ico' = 'image/x-icon'; '.woff2' = 'font/woff2'; '.woff' = 'font/woff'; '.ttf' = 'font/ttf'; '.otf' = 'font/otf'
    '.wasm' = 'application/wasm'; '.pdf' = 'application/pdf'; '.mp4' = 'video/mp4'; '.webm' = 'video/webm'
}

function Get-ChangeSetIds([string]$ProjectRoot) {
    # The change sets kept for the project (backups with a manifest), oldest first.
    $base = Join-Path (Get-ProjectStateDir $ProjectRoot) 'backups'
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    @(Get-ChildItem -LiteralPath $base -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}-\d{3}$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.json')) } | Sort-Object Name | ForEach-Object { $_.Name })
}

function Get-BeforeFiles {
    <# What to put back to see the project as it was before $ChangeSet: per file the earliest state
       kept by that change set or a later one. Ordered rel -> @{ state = existed|new; backup; from }.
       Throws when the change set is not kept. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$ChangeSet)
    if ($ChangeSet -notmatch '^\d{8}-\d{6}-\d{3}$') { throw "not a change set: $ChangeSet" }
    $base = Join-Path (Get-ProjectStateDir $ProjectRoot) 'backups'
    $ids = @(Get-ChangeSetIds $ProjectRoot)
    if ($ids -notcontains $ChangeSet) { throw "change set $ChangeSet is no longer kept (undone, or removed by Settings > Retention)" }
    $map = [ordered]@{}
    foreach ($id in ($ids | Where-Object { $_ -ge $ChangeSet })) {
        $dir = Join-Path $base $id
        $manifest = try { ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $dir 'manifest.json'))) } catch { $null }
        if (-not $manifest) { continue }
        foreach ($prop in $manifest.PSObject.Properties) {
            $rel = $prop.Name.Replace('\', '/')
            if ($map.Contains($rel)) { continue }   # an earlier set already kept its older state
            $map[$rel] = @{ state = "$($prop.Value)"; backup = (Join-Path $dir $rel.Replace('/', '\')); from = $id }
        }
    }
    $map
}

function Test-CopyLink([IO.FileSystemInfo]$Item) {
    # A junction or symbolic link (OneDrive marks every item as a reparse point: only LinkType counts).
    if (-not ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $lt = try { (Get-Item -LiteralPath $Item.FullName -Force).LinkType } catch { 'unknown' }
    $lt -in 'Junction', 'SymbolicLink', 'unknown'
}

function Copy-ProjectTree {
    <# Copies the project's files into $Dest (packages, version control, .streamhub/ and links left
       out; files over 100 MB and anything past 1 GB in all skipped). Returns the skipped paths. #>
    param([Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$Dest)
    $skipped = New-Object System.Collections.Generic.List[string]
    $total = 0L
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push('')
    while ($stack.Count) {
        $rel = $stack.Pop()
        $dir = if ($rel) { Join-Path $From $rel } else { $From }
        $null = New-Item -ItemType Directory -Force -Path $(if ($rel) { Join-Path $Dest $rel } else { $Dest })
        foreach ($item in @((New-Object IO.DirectoryInfo $dir).GetFileSystemInfos())) {
            $childRel = if ($rel) { "$rel\$($item.Name)" } else { $item.Name }
            if (Test-CopyLink $item) { $skipped.Add($childRel.Replace('\', '/')); continue }
            if ($item -is [IO.DirectoryInfo]) {
                if ($script:CopySkip -contains $item.Name.ToLowerInvariant()) { continue }
                $stack.Push($childRel); continue
            }
            if ($item.Length -gt $script:CopyMaxFileBytes -or $total + $item.Length -gt $script:CopyMaxTotalBytes) { $skipped.Add($childRel.Replace('\', '/')); continue }
            [IO.File]::Copy($item.FullName, (Join-Path $Dest $childRel), $true)
            $total += $item.Length
        }
    }
    $skipped.ToArray()
}

function New-BeforeCopy {
    <# A temporary copy of the project (under %TEMP%) as it was before $ChangeSet: the project's files,
       then every file that set or a later one touched put back from its earliest backup, and the
       files the set created removed. Returns @{ root; restored; removed; missing (no backup kept);
       skipped; sets (the change sets used) }. Remove it with Remove-BeforeCopy. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$ChangeSet, [string]$Dest)
    $files = Get-BeforeFiles $ProjectRoot $ChangeSet
    if (-not $Dest) { $Dest = Join-Path ([IO.Path]::GetTempPath()) ($script:CopyPrefix + [guid]::NewGuid().ToString('N').Substring(0, 12)) }
    $destFull = [IO.Path]::GetFullPath($Dest).TrimEnd('\')
    $restored = New-Object System.Collections.Generic.List[string]
    $removed = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    $skipped = @()
    try {
        $skipped = @(Copy-ProjectTree $ProjectRoot $destFull)
        foreach ($rel in @($files.Keys)) {
            $e = $files[$rel]
            $target = [IO.Path]::GetFullPath((Join-Path $destFull $rel.Replace('/', '\')))
            if (-not $target.StartsWith($destFull + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }   # never outside the copy
            if ($e.state -eq 'new') {
                if (Test-Path -LiteralPath $target -PathType Leaf) { [IO.File]::Delete($target) }
                $removed.Add($rel); continue
            }
            if (-not (Test-Path -LiteralPath $e.backup -PathType Leaf)) { $missing.Add($rel); continue }
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target)
            [IO.File]::Copy($e.backup, $target, $true)
            $restored.Add($rel)
        }
    } catch { Remove-BeforeCopy $destFull; throw }
    @{
        root = $destFull; restored = $restored.ToArray(); removed = $removed.ToArray(); missing = $missing.ToArray()
        skipped = $skipped; sets = @($files.Values | ForEach-Object { $_.from } | Sort-Object -Unique)
    }
}

function Remove-BeforeCopy([string]$Root) {
    # Removes a copy New-BeforeCopy made; refuses any other folder.
    if (-not $Root) { return }
    $full = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $tmp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not $full.StartsWith($tmp + '\', [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $full) -notlike "$($script:CopyPrefix)*") { throw "not a comparison copy: $Root" }
    if (Test-Path -LiteralPath $full) { [IO.Directory]::Delete($full, $true) }
}

function Resolve-ServedFile([string]$Root, [string]$UrlPath) {
    <# The file under $Root an address path asks for ('' or a folder: its index.html), or $null when
       it is not there or would lie outside $Root. Used by Start-PageServer (also in its runspace). #>
    $rel = [Uri]::UnescapeDataString(("$UrlPath" -replace '\?.*$', '')).TrimStart('/')
    if (-not $rel -or $rel.EndsWith('/')) { $rel += 'index.html' }
    if ($rel.IndexOf([char]0) -ge 0 -or $rel -match '(^|/)\.\.(/|$)' -or $rel -match '^[a-zA-Z]:' -or $rel.Contains('\')) { return $null }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = try { [IO.Path]::GetFullPath((Join-Path $base $rel.Replace('/', '\'))) } catch { return $null }
    if (-not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (Test-Path -LiteralPath $full -PathType Container) { $full = Join-Path $full 'index.html' }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
    $full
}

function Start-PageServer {
    <# Serves $Root read-only on http://localhost:PORT/ (GET only) from a runspace, so a page loads
       its module scripts and data as on the preview. Returns @{ Port; Url; Stop }. #>
    param([Parameter(Mandatory)][string]$Root)
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$port/")
    $listener.Start()
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $loop = {
        param($Listener, [string]$Root, [string]$ResolveText, $Types)
        $resolve = [scriptblock]::Create($ResolveText)
        while ($Listener.IsListening) {
            $ctx = try { $Listener.GetContext() } catch { break }
            try {
                $file = if ($ctx.Request.HttpMethod -eq 'GET') { & $resolve $Root $ctx.Request.Url.AbsolutePath } else { $null }
                if (-not $file) { $ctx.Response.StatusCode = 404 }
                else {
                    $bytes = [IO.File]::ReadAllBytes($file)
                    $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
                    $ctx.Response.ContentType = if ($Types[$ext]) { $Types[$ext] } else { 'application/octet-stream' }
                    $ctx.Response.Headers['Cache-Control'] = 'no-store'
                    $ctx.Response.ContentLength64 = $bytes.Length
                    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                }
            } catch { try { $ctx.Response.StatusCode = 500 } catch { } } finally { try { $ctx.Response.Close() } catch { } }
        }
    }
    $null = $ps.AddScript($loop.ToString()).AddArgument($listener).AddArgument($Root).AddArgument(${function:Resolve-ServedFile}.ToString()).AddArgument($script:ServedTypes)
    $handle = $ps.BeginInvoke()
    $stop = {
        try { $listener.Stop(); $listener.Close() } catch { }
        try { $null = $handle.AsyncWaitHandle.WaitOne(3000) } catch { }
        try { $ps.Dispose() } catch { }
        try { $rs.Close(); $rs.Dispose() } catch { }
    }.GetNewClosure()
    @{ Port = $port; Url = "http://localhost:$port/"; Stop = $stop }
}

function Save-PageShot {
    <# A screenshot of $Url at 1280 x 800 in the light colour scheme, after the page has loaded and
       settled (transitions and animations off), written to $OutPath. Returns the page's layout
       (lib/page-layout.js, as JSON text) to name the changed areas, or ''. #>
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutPath, [int]$SettleMs = 2000)
    $target = Invoke-RestMethod -Method Put "http://127.0.0.1:$Port/json/new?about:blank"
    $s = $null
    try {
        $s = Connect-Cdp $target.webSocketDebuggerUrl
        $null = Invoke-Cdp $s 'Emulation.setDeviceMetricsOverride' @{ width = 1280; height = 800; deviceScaleFactor = 1; mobile = $false }
        $null = Invoke-Cdp $s 'Emulation.setEmulatedMedia' @{ features = @(@{ name = 'prefers-color-scheme'; value = 'light' }) }
        $null = Invoke-Cdp $s 'Page.navigate' @{ url = $Url }
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 250
            $st = try { (Invoke-Cdp $s 'Runtime.evaluate' @{ expression = 'document.readyState'; returnByValue = $true }).result.value } catch { '' }
            if ($st -eq 'complete') { break }
        }
        Start-Sleep -Milliseconds $SettleMs   # data loads and charts draw after the page
        $null = Invoke-Cdp $s 'Runtime.evaluate' @{ expression = "(() => { const st = document.createElement('style'); st.textContent = '*, *::before, *::after { transition: none !important; animation: none !important; caret-color: transparent !important; }'; document.head.appendChild(st); return ''; })()" }
        Start-Sleep -Milliseconds 300
        $shot = Invoke-Cdp $s 'Page.captureScreenshot' @{ format = 'png' } -TimeoutMs 15000
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutPath)
        [IO.File]::WriteAllBytes($OutPath, [Convert]::FromBase64String($shot.data))
        try { "$((Invoke-Cdp $s 'Runtime.evaluate' @{ expression = (Get-PageLayoutScript); returnByValue = $true } -TimeoutMs 10000).result.value)" } catch { '' }
    } finally {
        if ($s) { try { Disconnect-Cdp $s } catch { } }
        try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/json/close/$($target.id)" } catch { }
    }
}

function Format-ChangeSetTime([string]$Id) {
    # 20261025-140305-123 -> 2026-10-25 14:03
    try { [datetime]::ParseExact($Id.Substring(0, 15), 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture).ToString('yyyy-MM-dd HH:mm') } catch { $Id }
}

function Format-PageCompareReport {
    <# The comparison report as Markdown. $Info: @{ page; changeSet; line; same; before; after; crop;
       copy (New-BeforeCopy's result); note }. #>
    param([Parameter(Mandatory)]$Info, [datetime]$When = (Get-Date))
    $c = $Info.copy
    $later = @($c.sets | Where-Object { $_ -ne $Info.changeSet }).Count
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("# Page comparison: $($Info.page)")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("Before change set $($Info.changeSet) ($(Format-ChangeSetTime $Info.changeSet)) next to now, compared $($When.ToString('yyyy-MM-dd HH:mm')) at 1280 x 800 in the light colour scheme.")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("**$($Info.line)**")
    if ($Info.note) { $null = $sb.AppendLine(); $null = $sb.AppendLine($Info.note) }
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('## Screenshots')
    $null = $sb.AppendLine()
    if ($Info.before) { $null = $sb.AppendLine("- Before change set $($Info.changeSet): $($Info.before)") }
    if ($Info.after) { $null = $sb.AppendLine("- Now: $($Info.after)") }
    if ($Info.crop) { $null = $sb.AppendLine("- The changed areas close up, before on the left and now on the right: $($Info.crop)") }
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('## How the before view was made')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine("A temporary copy of the project with every file that change set$(if ($later) { " or one of the $later later one(s)" }) touched put back as it was before it; the project itself was not changed, and the copy is gone.")
    $list = { param($title, $items) $items = @($items | Where-Object { $_ }); if ($items.Count) { $null = $sb.AppendLine(); $null = $sb.AppendLine("${title}:"); foreach ($x in ($items | Select-Object -First 40)) { $null = $sb.AppendLine("- $x") }; if ($items.Count -gt 40) { $null = $sb.AppendLine("- ... and $($items.Count - 40) more") } } }
    & $list 'Put back' $c.restored
    & $list 'Left out (they did not exist yet)' $c.removed
    & $list 'Shown as they are now (no earlier copy was kept: too large when a command changed them)' $c.missing
    $sb.ToString()
}

function Invoke-PageCompare {
    <# Compares $Page as it was before $ChangeSet with how it looks now and writes
       .streamhub/Reports/compare-NAME-STAMP.md with the screenshots (-before, -after, -changes).
       $Shoot stands in for the server and Edge: & $Shoot @{ side = before|now; root; page; out; port }
       writes the PNG and returns the layout JSON text (or ''). Returns @{ path; summary; same;
       before; after; crop }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$ChangeSet, [Parameter(Mandatory)][string]$Page, [int]$Port, [scriptblock]$Shoot, [datetime]$Now = (Get-Date))
    $page = $Page.Replace('\', '/').TrimStart('/')
    if (-not $Shoot) {
        $Shoot = {
            param($o)
            $srv = Start-PageServer $o.root
            try { Save-PageShot -Port $o.port -Url ($srv.Url + (($o.page.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')) -OutPath $o.out } finally { & $srv.Stop }
        }
    }
    $stem = "compare-$(Get-ReportName $page)-$($Now.ToString('yyyyMMdd-HHmmss'))"
    $dir = Join-Path $ProjectRoot '.streamhub\Reports'
    $null = New-Item -ItemType Directory -Force -Path $dir
    $copy = New-BeforeCopy $ProjectRoot $ChangeSet
    $info = @{ page = $page; changeSet = $ChangeSet; copy = $copy; before = ''; after = ''; crop = ''; same = $false; line = ''; note = '' }
    try {
        $hadBefore = Test-Path -LiteralPath (Join-Path $copy.root $page.Replace('/', '\')) -PathType Leaf
        $hasNow = Test-Path -LiteralPath (Join-Path $ProjectRoot $page.Replace('/', '\')) -PathType Leaf
        $beforeFull = Join-Path $dir "$stem-before.png"; $afterFull = Join-Path $dir "$stem-after.png"
        if ($hadBefore) { $null = & $Shoot @{ side = 'before'; root = $copy.root; page = $page; out = $beforeFull; port = $Port }; if (Test-Path -LiteralPath $beforeFull) { $info.before = ".streamhub/Reports/$stem-before.png" } }
        $layoutText = ''
        if ($hasNow) { $layoutText = "$(& $Shoot @{ side = 'now'; root = $ProjectRoot; page = $page; out = $afterFull; port = $Port })"; if (Test-Path -LiteralPath $afterFull) { $info.after = ".streamhub/Reports/$stem-after.png" } }
        if (-not $hadBefore -and -not $hasNow) { $info.line = "$page did not exist before change set $ChangeSet and does not exist now." }
        elseif (-not $hadBefore) { $info.line = "$page did not exist before change set ${ChangeSet}: that change set or a later one created it, so there is nothing to compare it with." }
        elseif (-not $hasNow) { $info.line = "$page no longer exists; only how it looked before change set $ChangeSet is shown." }
        elseif (-not $info.before -or -not $info.after) { $info.line = "A screenshot could not be taken, so $page could not be compared." }
        else {
            $r = Compare-Screenshots $beforeFull $afterFull
            $layout = if ($layoutText.Trim()) { try { $l = ConvertFrom-Json $layoutText; @($l) } catch { $null } } else { $null }
            $info.same = [bool]$r.same
            $info.line = (Format-ShotComparison $page $r $layout).Replace('before your changes', "before change set $ChangeSet")
            if ($r.same) { $info.line = "$page looks exactly the same now as before change set $ChangeSet (pixel for pixel)." }
            elseif (@($r.regions).Count) {
                $cropFull = Join-Path $dir "$stem-changes.png"
                if (New-ShotCrop $beforeFull $afterFull $r.regions $cropFull) { $info.crop = ".streamhub/Reports/$stem-changes.png" }
            }
        }
        if (@($copy.missing).Count) { $info.note = "$(@($copy.missing).Count) file(s) had no earlier copy kept, so the before view shows them as they are now (listed below)." }
    } finally { Remove-BeforeCopy $copy.root }
    $rel = ".streamhub/Reports/$stem.md"
    [IO.File]::WriteAllText((Join-Path $dir "$stem.md"), (Format-PageCompareReport $info $Now), (New-Object Text.UTF8Encoding($false)))
    @{ path = $rel; summary = $info.line; same = $info.same; before = $info.before; after = $info.after; crop = $info.crop }
}

Export-ModuleMember -Function Get-ChangeSetIds, Get-BeforeFiles, Copy-ProjectTree, New-BeforeCopy, Remove-BeforeCopy, Resolve-ServedFile, Start-PageServer, Save-PageShot, Format-ChangeSetTime, Format-PageCompareReport, Invoke-PageCompare
