# SharePoint from the person's own sign-in in StreamHub's Edge, for SharePoint HTML pages (see
# SharePointPage.psm1): what a page's LiveData manifest needs for a file or list the person links,
# and publishing the finished page to a site's Site Pages library after the person confirms. A
# background tab on the SharePoint host runs SharePoint's own APIs with the person's access; never
# started by Copilot, a schedule or another program (Server: the StreamHub page's Origin only), and
# publishing only with the person's confirmation each time (human in the loop).
#   Resolve-SharePointSource  - a file link -> { spItemUrl, fileName }; a list link -> { kind list, webUrl, listId }
#   Get-SharePointLinks / Add-SharePointLink / Remove-SharePointLink - .streamhub/sharepoint.json
#   Format-SharePointLinksContext - the project-context lines (exact manifest entries)
#   Publish-SharePointPage    - check first (-WhatIf: where it goes, whether it exists), then upload
# ASCII only (Windows PowerShell 5.1).

Import-Module (Join-Path $PSScriptRoot 'Cdp.psm1')
Import-Module (Join-Path $PSScriptRoot 'Sso.psm1')   # Open-BackgroundTab, Close-BackgroundTab

function ConvertTo-SharesToken([Parameter(Mandatory)][string]$Url) {
    # SharePoint's shares API key for a link: u! + unpadded base64url of the link.
    'u!' + ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Url.Trim())).TrimEnd('=').Replace('/', '_').Replace('+', '-'))
}

function Test-SharePointLink([string]$Url) {
    # A SharePoint or OneDrive for work address (https, *.sharepoint.com and the like).
    [bool]("$Url" -match '^(?i)https://[\w-]+(-my)?\.sharepoint\.(com|us|de|cn)/\S*$')
}

function Get-SiteFromLink([string]$Url) {
    # The site address in a link: https://HOST/sites/NAME or /teams/NAME, else the root site.
    $m = [regex]::Match($Url, '^(?i)(https://[^/]+)(/(sites|teams|personal)/[^/?#]+)?')
    $m.Value
}

function Invoke-OnSharePoint {
    <# Runs $Script (a JavaScript expression that resolves to a string) in a background tab on the
       link's SharePoint host, with the person's sign-in. Throws a clear message when Edge is not
       running or the host asks for a sign-in. #>
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$HostUrl, [Parameter(Mandatory)][string]$Script, [string[]]$Chunks = @(), [int]$TimeoutMs = 120000)
    try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/json/version" -TimeoutSec 3 } catch { throw "StreamHub's Edge is not running; connect to Copilot first." }
    $tab = Open-BackgroundTab $Port "$HostUrl/_api/web/title"
    try {
        $want = ([Uri]$HostUrl).Host
        $state = $null
        for ($i = 0; $i -lt 60; $i++) {
            $state = try { Invoke-CdpEval $tab.Session '(() => location.host + "|" + document.readyState)()' -TimeoutMs 5000 } catch { '' }
            if ("$state" -match '\|complete$') { break }
            Start-Sleep -Milliseconds 300
        }
        if ("$state" -notlike "$want|*") { throw "SharePoint asked for a sign-in ($(("$state" -split '\|')[0])). Open $HostUrl once in StreamHub's Edge, sign in, and try again." }
        if ($Chunks.Count) {
            $null = Invoke-CdpEval $tab.Session 'window.__ccbParts = []; true'
            foreach ($c in $Chunks) { $null = Invoke-CdpEval $tab.Session "window.__ccbParts.push($(ConvertTo-Json -InputObject $c -Compress)); true" -TimeoutMs 30000 }
        }
        "$(Invoke-CdpEval $tab.Session $Script -TimeoutMs $TimeoutMs)"
    } finally { Close-BackgroundTab $tab }
}

function Resolve-SharePointSource {
    <# A SharePoint file or list link -> what a LiveData manifest needs: a file @{ kind = 'file';
       spItemUrl; fileName; label; size } (shares API: the drive and item id), a list @{ kind = 'list';
       spItemUrl = 'list:WEB/ID'; webUrl; listId; label } (the list's id from its site). #>
    param([Parameter(Mandatory)][string]$Url, [int]$Port = 9333, [scriptblock]$Run = $null)
    if (-not (Test-SharePointLink $Url)) { throw 'This is not a SharePoint or OneDrive for work link (https://...sharepoint.com/...).' }
    $hostUrl = ([regex]::Match($Url, '^(?i)https://[^/]+')).Value
    $listPath = [regex]::Match([Uri]::UnescapeDataString($Url), '^(?i)https://[^/]+(/(?:sites|teams)/[^/]+)?(/Lists/[^/?#]+)')
    if ($listPath.Success) {
        $web = $hostUrl + $listPath.Groups[1].Value
        $rel = "$($listPath.Groups[1].Value)$($listPath.Groups[2].Value)"
        $js = "(async () => { const r = await fetch($(ConvertTo-Json -InputObject ($web + "/_api/web/GetList('" + $rel.Replace("'", "''") + "')?`$select=Id,Title") -Compress), { headers: { accept: 'application/json;odata=nometadata' }, credentials: 'include' }); if (!r.ok) return JSON.stringify({ error: r.status + ' ' + r.statusText }); const j = await r.json(); return JSON.stringify({ id: j.Id, title: j.Title }); })()"
        $raw = if ($Run) { & $Run $hostUrl $js } else { Invoke-OnSharePoint $Port $hostUrl $js }
        $o = $raw | ConvertFrom-Json
        if ($o.error) { throw "SharePoint could not find the list ($($o.error)): check the link and that you can open it." }
        return [pscustomobject]@{ kind = 'list'; spItemUrl = "list:$web/$($o.id)"; webUrl = $web; listId = "$($o.id)"; label = "$($o.title)"; fileName = '' }
    }
    $token = ConvertTo-SharesToken $Url
    $js = "(async () => { const r = await fetch('/_api/v2.0/shares/$token/driveItem?`$select=id,name,size,parentReference', { headers: { accept: 'application/json' }, credentials: 'include' }); if (!r.ok) return JSON.stringify({ error: r.status + ' ' + r.statusText }); const j = await r.json(); return JSON.stringify({ id: j.id, name: j.name, size: j.size, driveId: j.parentReference && j.parentReference.driveId }); })()"
    $raw = if ($Run) { & $Run $hostUrl $js } else { Invoke-OnSharePoint $Port $hostUrl $js }
    $o = $raw | ConvertFrom-Json
    if ($o.error -or -not $o.driveId -or -not $o.id) { throw "SharePoint could not resolve the file ($(if ($o.error) { $o.error } else { 'no drive or item id' })): check the link and that you can open it." }
    [pscustomobject]@{ kind = 'file'; spItemUrl = "$hostUrl/_api/v2.0/drives/$($o.driveId)/items/$($o.id)"; fileName = "$($o.name)"; label = "$($o.name)"; size = [long]$o.size; webUrl = ''; listId = '' }
}

function Get-SharePointLinksPath([string]$ProjectRoot) { Join-Path $ProjectRoot '.streamhub\sharepoint.json' }

function Get-SharePointLinks([string]$ProjectRoot) {
    # @{ sources = @(...); site = ''; page = '' } from .streamhub/sharepoint.json.
    $f = Get-SharePointLinksPath $ProjectRoot
    $o = $null
    if (Test-Path -LiteralPath $f) { try { $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { } }
    @{ sources = @(if ($o -and $o.sources) { @($o.sources | ForEach-Object { $_ }) }); site = "$(if ($o) { $o.site })"; page = "$(if ($o) { $o.page })" }
}

function Save-SharePointLinks([string]$ProjectRoot, $Links) {
    $f = Get-SharePointLinksPath $ProjectRoot
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f)
    [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject ([pscustomobject]@{ sources = @($Links.sources); site = $Links.site; page = $Links.page }) -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

function Add-SharePointLink([string]$ProjectRoot, $Source) {
    $l = Get-SharePointLinks $ProjectRoot
    $l.sources = @(@($l.sources | Where-Object { $_.spItemUrl -ne $Source.spItemUrl }) + @($Source))
    Save-SharePointLinks $ProjectRoot $l
    $l
}

function Remove-SharePointLink([string]$ProjectRoot, [string]$SpItemUrl) {
    $l = Get-SharePointLinks $ProjectRoot
    $l.sources = @($l.sources | Where-Object { $_.spItemUrl -ne $SpItemUrl })
    Save-SharePointLinks $ProjectRoot $l
    $l
}

function Format-SharePointLinksContext([string]$ProjectRoot) {
    # The project-context lines: the LiveData sources the user linked, as the exact manifest entries.
    $l = Get-SharePointLinks $ProjectRoot
    if (-not @($l.sources).Count) { return '' }
    $lines = @('- SharePoint data the user linked for this page (put exactly these entries in the LiveData manifest; never other ids):')
    foreach ($s in @($l.sources)) {
        $entry = if ($s.kind -eq 'list') { [ordered]@{ kind = 'list'; spItemUrl = $s.spItemUrl; webUrl = $s.webUrl; listId = $s.listId; label = $s.label } } else { [ordered]@{ spItemUrl = $s.spItemUrl; fileName = $s.fileName } }
        $lines += "  - $(if ($s.label) { $s.label } else { $s.fileName }): $(ConvertTo-Json -InputObject $entry -Compress)"
    }
    $lines -join "`n"
}

function Publish-SharePointPage {
    <# Uploads a page to a site's Site Pages library with the person's sign-in. -WhatIf only looks:
       @{ target; exists } (the address it gets and whether a page of that name is there). Without it
       the page is uploaded (replacing one of the same name only with -Replace): @{ target; replaced }.
       Only after the person confirmed in the app (Server); never from Copilot or automation. #>
    param([Parameter(Mandatory)][string]$Site, [Parameter(Mandatory)][string]$FileName, [string]$Html = '', [switch]$WhatIf, [switch]$Replace, [int]$Port = 9333, [scriptblock]$Run = $null)
    if (-not (Test-SharePointLink $Site)) { throw 'The site must be a SharePoint address (https://...sharepoint.com/sites/NAME).' }
    if ($FileName -notmatch '^[\w][\w .-]{0,120}\.html?$') { throw "The page name '$FileName' must be a plain .html file name." }
    $site = (Get-SiteFromLink $Site).TrimEnd('/')
    $hostUrl = ([regex]::Match($site, '^(?i)https://[^/]+')).Value
    $folder = ([Uri]$site).AbsolutePath.TrimEnd('/') + '/SitePages'
    $fileRel = "$folder/$FileName"
    $q = { param($s) $s.Replace("'", "''") }
    $exists = "fetch($(ConvertTo-Json -InputObject ("$site/_api/web/GetFileByServerRelativeUrl('" + (& $q $fileRel) + "')?`$select=Exists") -Compress), { headers: { accept: 'application/json;odata=nometadata' }, credentials: 'include' }).then(r => r.ok ? r.json().then(j => !!j.Exists) : false)"
    if ($WhatIf) {
        $js = "(async () => JSON.stringify({ exists: await $exists }))()"
        $raw = if ($Run) { & $Run $hostUrl $js @() } else { Invoke-OnSharePoint $Port $hostUrl $js }
        $o = $raw | ConvertFrom-Json
        return [pscustomobject]@{ target = "$hostUrl$fileRel"; exists = [bool]$o.exists }
    }
    if ([Text.Encoding]::UTF8.GetByteCount($Html) -gt 10MB) { throw 'The page is over 10 MB: SharePoint HTML pages hold at most 10 MB.' }
    $chunks = @(for ($i = 0; $i -lt $Html.Length; $i += 400000) { $Html.Substring($i, [Math]::Min(400000, $Html.Length - $i)) })
    $add = "$site/_api/web/GetFolderByServerRelativeUrl('" + (& $q $folder) + "')/Files/add(url='" + (& $q $FileName) + "',overwrite=$(if ($Replace) { 'true' } else { 'false' }))"
    $js = "(async () => { const had = await $exists; if (had && !$(if ($Replace) { 'true' } else { 'false' })) return JSON.stringify({ error: 'exists' }); const d = await (await fetch($(ConvertTo-Json -InputObject "$site/_api/contextinfo" -Compress), { method: 'POST', headers: { accept: 'application/json;odata=nometadata' }, credentials: 'include' })).json(); const body = new Blob([window.__ccbParts.join('')], { type: 'text/html' }); const r = await fetch($(ConvertTo-Json -InputObject $add -Compress), { method: 'POST', headers: { accept: 'application/json;odata=nometadata', 'X-RequestDigest': d.FormDigestValue }, body, credentials: 'include' }); if (!r.ok) return JSON.stringify({ error: r.status + ' ' + (await r.text()).slice(0, 300) }); const j = await r.json(); return JSON.stringify({ url: j.ServerRelativeUrl, replaced: had }); })()"
    $raw = if ($Run) { & $Run $hostUrl $js $chunks } else { Invoke-OnSharePoint $Port $hostUrl $js -Chunks $chunks }
    $o = $raw | ConvertFrom-Json
    if ($o.error -eq 'exists') { throw "A page named $FileName is already in Site Pages; confirm replacing it." }
    if ($o.error) { throw "SharePoint did not take the page ($($o.error))." }
    [pscustomobject]@{ target = "$hostUrl$($o.url)"; replaced = [bool]$o.replaced }
}

Export-ModuleMember -Function ConvertTo-SharesToken, Test-SharePointLink, Get-SiteFromLink, Resolve-SharePointSource, Get-SharePointLinks, Save-SharePointLinks, Add-SharePointLink, Remove-SharePointLink, Format-SharePointLinksContext, Publish-SharePointPage
