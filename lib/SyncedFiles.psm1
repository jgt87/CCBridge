# The web address of a project file in a folder OneDrive syncs (a personal OneDrive or a work
# OneDrive / SharePoint / Teams library), so the person can hand Copilot (with Microsoft 365 access)
# the file by its real address. OneDrive's own records (HKCU\Software\SyncEngines\Providers\OneDrive\
# <id>: MountPoint = the local folder, UrlNamespace = its web address) turn a local path into the
# address. Reads those records and folder names only: never a file's content, never writes the
# registry. Ported from a sibling tool where the personal OneDrive form was checked live; the work
# (SharePoint library) form follows the same rules but is not checked live yet.
#   Get-SyncRoots      - the synced folders @(@{ path; url }), longest path first (cached per process)
#   ConvertTo-SyncRoots - pure: provider records -> roots (tests pass their own records)
#   ConvertTo-SyncedUrl - pure: one root + a full path -> the address, or ''
#   Get-SyncedWebUrl   - a full local path -> the https address, or $null when no synced folder holds it
# ASCII only (Windows PowerShell 5.1).
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Workspace.psm1')   # Get-FullRoot

$script:ProvidersKey = 'HKCU:\Software\SyncEngines\Providers\OneDrive'
$script:PersonalKey = 'HKCU:\Software\Microsoft\OneDrive\Accounts\Personal'
$script:RootsCache = $null
$script:RootsCachedAt = [datetime]::MinValue
$script:RootsCacheSec = 300

function Resolve-SyncRootUrl {
    <# A synced folder's web address. Personal OneDrive stores only "https://d.docs.live.net/" as its
       UrlNamespace; its files live under /<cid>/, the account id in OneDrive\Accounts\Personal.
       Work and SharePoint libraries carry their full address. Pure. #>
    param([Parameter(Mandatory)][string]$Url, [string]$PersonalCid = '')
    $u = [uri]$Url
    if ($u.Host -like '*.docs.live.net' -and $u.AbsolutePath -eq '/') {
        if (-not $PersonalCid) { return '' }
        return "https://$($u.Host)/$([Uri]::EscapeDataString($PersonalCid))/"
    }
    $Url
}

function ConvertTo-EscapedRootUrl {
    <# A synced folder's address with every path part escaped once: OneDrive records a library as
       typed ("https://contoso.sharepoint.com/sites/Team/Shared Documents/"), and an address with a
       space is refused as a link. A part that is escaped already ("%20") is decoded first, so it is
       never escaped twice. Scheme and host stay as they are. Pure. #>
    param([AllowEmptyString()][string]$Url = '')
    $m = [regex]::Match($Url, '^(?i)(https?://[^/?#]*)([^?#]*)(.*)$')
    if (-not $m.Success) { return $Url }
    $path = (@($m.Groups[2].Value.Split('/') | ForEach-Object {
        $seg = $_
        try { $seg = [Uri]::UnescapeDataString($seg) } catch { }
        [Uri]::EscapeDataString($seg)
    }) -join '/')
    $m.Groups[1].Value + $path + $m.Groups[3].Value
}

function ConvertTo-SyncedUrl {
    <# The web address of $Path under the synced folder $Root (@{ path; url }): the root's address plus
       the relative path, each part escaped. '' when $Path is not under $Root. Pure. #>
    param([Parameter(Mandatory)][hashtable]$Root, [Parameter(Mandatory)][string]$Path)
    $base = ([string]$Root.path).TrimEnd('\') + '\'
    if (-not $Path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    $rel = $Path.Substring($base.Length)
    $parts = @($rel.Split('\') | Where-Object { $_ } | ForEach-Object { [Uri]::EscapeDataString($_) })
    if (-not $parts.Count) { return '' }
    $u = ConvertTo-EscapedRootUrl ([string]$Root.url)
    if (-not $u.EndsWith('/')) { $u += '/' }
    $u + ($parts -join '/')
}

function ConvertTo-SyncRoots {
    <# Provider records (objects or hashtables with MountPoint and UrlNamespace, as the registry keys
       hold them) -> @(@{ path; url }), the longest path first so a library synced inside another
       synced folder wins. A record without a local folder or an https address is left out; each
       folder goes through Get-FullRoot (full, no trailing \, an 8.3 short name expanded). Pure apart
       from that expansion. #>
    param([object[]]$Providers = @(), [string]$PersonalCid = '')
    $out = @()
    foreach ($p in @($Providers)) {
        if ($null -eq $p) { continue }
        $mount = ''; $url = ''
        if ($p -is [hashtable]) {
            if ($p.ContainsKey('MountPoint')) { $mount = [string]$p['MountPoint'] }
            if ($p.ContainsKey('UrlNamespace')) { $url = [string]$p['UrlNamespace'] }
        } else {
            if ($p.PSObject.Properties['MountPoint']) { $mount = [string]$p.MountPoint }
            if ($p.PSObject.Properties['UrlNamespace']) { $url = [string]$p.UrlNamespace }
        }
        if ($url -match '^(?i)https://') { $url = Resolve-SyncRootUrl -Url $url -PersonalCid $PersonalCid }
        if (-not $mount -or $url -notmatch '^(?i)https://') { continue }
        $out += @{ path = (Get-FullRoot $mount); url = $url }
    }
    @($out | Sort-Object { $_.path.Length } -Descending)
}

function Get-SyncProviderRecords {
    <# OneDrive's provider records and the personal account id from the registry (read only):
       @{ providers = @(...); cid = '' }. Empty when OneDrive syncs nothing here. #>
    $providers = @()
    $cid = ''
    if (-not (Test-Path -LiteralPath $script:ProvidersKey)) { return @{ providers = @(); cid = '' } }
    try { $cid = [string](Get-ItemProperty -LiteralPath $script:PersonalKey -ErrorAction Stop).cid } catch { }
    foreach ($k in @(Get-ChildItem -LiteralPath $script:ProvidersKey -ErrorAction SilentlyContinue)) {
        try { $providers += Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { continue }
    }
    @{ providers = $providers; cid = $cid }
}

function Get-SyncRoots {
    <# The synced folders on this PC that exist: @(@{ path; url }), the longest path first. Read once
       per process and again after $script:RootsCacheSec seconds or with -Refresh (a library synced
       later shows up without a restart). #>
    param([switch]$Refresh)
    $age = ((Get-Date) - $script:RootsCachedAt).TotalSeconds
    if (-not $Refresh -and $null -ne $script:RootsCache -and $age -lt $script:RootsCacheSec) { return @($script:RootsCache) }
    $rec = Get-SyncProviderRecords
    $roots = @(ConvertTo-SyncRoots -Providers @($rec.providers) -PersonalCid ([string]$rec.cid) | Where-Object { Test-Path -LiteralPath $_.path -PathType Container })
    $script:RootsCache = $roots
    $script:RootsCachedAt = Get-Date
    @($roots)
}

function Get-SyncedWebUrl {
    <# The https address of the file at $Path (a full local path) in the folder OneDrive syncs it
       from, or $null when no synced folder holds it. The longest matching synced folder wins; path
       and folders are compared in full form, ignoring case, with 8.3 short names expanded.
       $Roots: from Get-SyncRoots (tests pass their own). #>
    param([Parameter(Mandatory)][string]$Path, [object[]]$Roots = $null)
    if ($null -eq $Roots) { $Roots = @(Get-SyncRoots) }
    $full = Get-FullRoot $Path
    if (-not $full) { return $null }
    $sorted = @(@($Roots) | Where-Object { $_ -is [hashtable] -and $_['path'] -and $_['url'] } |
        ForEach-Object { @{ path = (Get-FullRoot ([string]$_['path'])); url = [string]$_['url'] } } |
        Sort-Object { $_.path.Length } -Descending)
    foreach ($r in $sorted) {
        $u = ConvertTo-SyncedUrl -Root $r -Path $full
        if ($u) { return $u }
    }
    $null
}

Export-ModuleMember -Function Resolve-SyncRootUrl, ConvertTo-EscapedRootUrl, ConvertTo-SyncedUrl, ConvertTo-SyncRoots, Get-SyncRoots, Get-SyncedWebUrl
