# Downloads for chains: a file from SharePoint or OneDrive saved into the project by StreamHub's
# own Edge, which is signed in to Microsoft 365, so the company sign-in works and nothing has to be
# synced. Chain step: "download: LINK to Downloads/NAME.csv" (without "to", Downloads/ and the
# file's own name). Only Microsoft 365 file addresses, only into the project, never into Source/
# (the person's own files, which StreamHub never changes). A scheduled chain gets the latest
# version each run; the data conversion (DataImport.psm1) follows after the task.

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Workspace', 'Executor', 'Cdp') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:Hosts = '(?i)^(([\w-]+\.)*sharepoint\.(com|us|de|cn)|([\w-]+\.)*sharepoint-df\.com|onedrive\.live\.com|1drv\.ms)$'
$script:Types = @('.csv', '.tsv', '.txt', '.json', '.xml', '.xlsx', '.xlsm', '.xls', '.docx', '.pptx', '.pdf')
$script:DefaultFolder = 'Downloads'

function Read-DownloadStep([string]$Rest) {
    <# "LINK to PATH" (the link may be in quotes or backticks): @{ url; to }. #>
    $r = "$Rest".Trim()
    $m = [regex]::Match($r, '^[`"''<]?(\S+?)[`"''>]?(?:\s+to\s+[`"'']?(.+?)[`"'']?)?\s*$', 'IgnoreCase')
    if (-not $m.Success) { return @{ url = ''; to = '' } }
    @{ url = $m.Groups[1].Value; to = $(if ($m.Groups[2].Success) { $m.Groups[2].Value.Trim().Replace('\', '/') } else { '' }) }
}

function Test-DownloadAddress([string]$Url) {
    <# Why a link cannot be downloaded, or $null: https and a SharePoint or OneDrive address only. #>
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return "'$Url' is not a web address" }
    if ($u.Scheme -ne 'https') { return "$Url does not start with https://" }
    if ($u.Host -notmatch $script:Hosts) { return "$($u.Host) is not SharePoint or OneDrive: a download step takes a link to a file in Microsoft 365" }
    $null
}

function Get-DownloadName([string]$Url) {
    <# The file name in a link (the last part of its path, when it has a file type), else ''. #>
    $u = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u)) { return '' }
    $last = [Uri]::UnescapeDataString(($u.AbsolutePath.TrimEnd('/') -split '/')[-1])
    if ($last -match '\.[A-Za-z0-9]{2,5}$' -and $last -notmatch '(?i)\.aspx$') { $last } else { '' }
}

function Get-DownloadTarget {
    <# Where a download goes in the project: @{ rel; full } or @{ error }. #>
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Url, [string]$To = '')
    $name = Get-DownloadName $Url
    $rel = $To.Trim().TrimStart('/')
    if (-not $rel) { $rel = "$($script:DefaultFolder)/" }
    if ($rel.EndsWith('/')) {
        if (-not $name) { return @{ error = "the link does not show the file name: write the step as `"download: LINK to $($script:DefaultFolder)/NAME.csv`"" } }
        $rel += $name
    }
    $ext = [IO.Path]::GetExtension($rel).ToLowerInvariant()
    if ($script:Types -notcontains $ext) { return @{ error = "$rel is not a data or document file ($($script:Types -join ' '))" } }
    try { $full = Resolve-ProjectPath $ProjectRoot $rel } catch { return @{ error = "$rel is not a path inside the project" } }
    $relNow = ConvertTo-RelativePath $ProjectRoot $full
    if ($relNow -match '(?i)^Source(/|$)') { return @{ error = "$relNow is in Source/, which holds your own files and is never changed by StreamHub; download to $($script:DefaultFolder)/ instead" } }
    # StreamHub writes it itself (Office files too), but not into its own folder, build output or protected files.
    if ($relNow -match '(?i)^\.streamhub(/|$)') { return @{ error = "$relNow is in .streamhub/, StreamHub's own records; download to $($script:DefaultFolder)/ instead" } }
    if ($relNow -match '(?i)(^|/)(node_modules|dist|\.git)(/|$)') { return @{ error = "$relNow is in a build or tool folder; download to $($script:DefaultFolder)/ instead" } }
    $guard = Test-ProtectedPath $relNow
    if ($guard) { return @{ error = "$relNow is protected (Settings > Protected files: $guard)" } }
    @{ rel = $relNow; full = $full }
}

function Add-DownloadParam([string]$Url) {
    # SharePoint and OneDrive send the file itself (not the viewer) for download=1.
    if ($Url -match '(?i)[?&]download=1(&|$)') { return $Url }
    $Url + $(if ($Url.Contains('?')) { '&' } else { '?' }) + 'download=1'
}

function Test-DownloadContent([string]$Path, [string]$Rel) {
    <# Why a downloaded file is not the file asked for (a sign-in or error page instead), or $null. #>
    $len = (Get-Item -LiteralPath $Path).Length
    if (-not $len) { return 'the download was empty' }
    $fs = [IO.File]::OpenRead($Path)
    try { $buf = New-Object byte[] ([Math]::Min(512, $len)); $null = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
    $head = [Text.Encoding]::UTF8.GetString($buf).TrimStart([char]0xFEFF)
    $ext = [IO.Path]::GetExtension($Rel).ToLowerInvariant()
    if ($ext -in '.xlsx', '.xlsm', '.docx', '.pptx' -and -not $head.StartsWith('PK')) { return "the download is not a $ext file (a web page or an error came back instead)" }
    if ($ext -eq '.pdf' -and -not $head.StartsWith('%PDF')) { return 'the download is not a PDF (a web page or an error came back instead)' }
    if ($ext -notin '.xml' -and $head -match '(?is)^\s*<(!doctype\s+html|html\b)') { return 'a web page came back instead of the file (a sign-in page, or a link to a folder or a viewer)' }
    $null
}

function Invoke-EdgeDownload {
    <# Opens the link in a background tab of StreamHub's Edge with downloads going to $Folder and
       waits for the download to finish: @{ path; name } or @{ error }. The tab is closed again
       and Edge's download setting put back. #>
    param([Parameter(Mandatory)][int]$Port, [Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Folder, [int]$TimeoutSec = 180, [scriptblock]$CancelCheck)
    $ver = Invoke-RestMethod "http://127.0.0.1:$Port/json/version"
    $b = Connect-Cdp $ver.webSocketDebuggerUrl
    $tab = $null
    try {
        $null = Invoke-Cdp $b 'Browser.setDownloadBehavior' @{ behavior = 'allowAndName'; downloadPath = $Folder; eventsEnabled = $true }
        $tab = (Invoke-Cdp $b 'Target.createTarget' @{ url = $Url; background = $true }).targetId
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $guid = $null; $name = ''
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            if ($CancelCheck -and (& $CancelCheck)) { return @{ error = 'stopped by the user' } }
            $ev = Receive-CdpEvent $b 500
            if ($ev -and $ev.method -eq 'Browser.downloadWillBegin') { $guid = $ev.params.guid; $name = "$($ev.params.suggestedFilename)" }
            elseif ($ev -and $ev.method -eq 'Browser.downloadProgress' -and $ev.params.guid -eq $guid) {
                if ($ev.params.state -eq 'completed') { return @{ path = (Join-Path $Folder $guid); name = $name } }
                if ($ev.params.state -eq 'canceled') { return @{ error = 'Edge cancelled the download' } }
            }
            # No download after a while: say where the tab ended up (a sign-in page, a viewer).
            if (-not $guid -and $sw.Elapsed.TotalSeconds -ge 30) {
                $at = @((Invoke-Cdp $b 'Target.getTargets').targetInfos | Where-Object { $_.targetId -eq $tab }) | Select-Object -First 1
                $where = "$($at.url)"
                if ($where -match '(?i)login\.microsoftonline\.com|login\.live\.com|/_forms/|signin') { return @{ error = 'StreamHub''s Edge is not signed in to that SharePoint site: open the link once in StreamHub''s Edge and sign in, then run the chain again' } }
                return @{ error = "no download started: the link opened a page instead of a file$(if ($where) { " ($(($where -split '\?')[0]))" }). Use the file's own link (in SharePoint: the file's ... menu > Copy link, or Details > Path)" }
            }
        }
        @{ error = "the download did not finish within $TimeoutSec s" }
    } finally {
        if ($tab) { try { $null = Invoke-Cdp $b 'Target.closeTarget' @{ targetId = $tab } } catch { } }
        try { $null = Invoke-Cdp $b 'Browser.setDownloadBehavior' @{ behavior = 'default' } } catch { }
        Disconnect-Cdp $b
    }
}

Export-ModuleMember -Function Read-DownloadStep, Test-DownloadAddress, Get-DownloadName, Get-DownloadTarget, Add-DownloadParam, Test-DownloadContent, Invoke-EdgeDownload
