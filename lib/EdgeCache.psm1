# Edge's caches in StreamHub's own Edge profile (%LOCALAPPDATA%\CCBridge\edge-profile). Only caches:
# the web cache, compiled code, GPU and shader caches, service worker caches and Edge's component
# download cache. Never cookies, Local Storage, IndexedDB, sessions or extensions, so the Copilot
# sign-in stays. Edge locks these folders while it runs: the web cache is cleared at once through
# Edge (Network.clearBrowserCache), the folders at the next start before Edge opens
# (Start-CdpEdge calls Clear-EdgeCacheFolders when a clear was asked for).

$ErrorActionPreference = 'Stop'
foreach ($m in 'Log', 'Cdp') { Import-Module (Join-Path $PSScriptRoot "$m.psm1") }

$script:CacheFolders = @(
    'Default\Cache', 'Default\Code Cache', 'Default\GPUCache', 'Default\DawnWebGPUCache', 'Default\DawnGraphiteCache',
    'Default\Service Worker\CacheStorage', 'Default\Service Worker\ScriptCache',
    'GrShaderCache', 'ShaderCache', 'GraphiteDawnCache', 'component_crx_cache'
)

function Get-EdgeProfileDir { Join-Path $env:LOCALAPPDATA 'CCBridge\edge-profile' }
function Get-EdgeCacheFlag { Join-Path $env:LOCALAPPDATA 'CCBridge\edge-cache-clear.flag' }

function Get-FolderBytes([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $sum = [int64]0
    foreach ($f in [IO.Directory]::EnumerateFiles($Path, '*', [IO.SearchOption]::AllDirectories)) { try { $sum += (New-Object IO.FileInfo $f).Length } catch { } }
    $sum
}

function Get-EdgeCacheInfo {
    <# The size of the caches, the whole profile, and whether a clear waits for the next start. #>
    param([string]$ProfileDir = (Get-EdgeProfileDir))
    $cache = [int64]0
    foreach ($f in $script:CacheFolders) { $cache += Get-FolderBytes (Join-Path $ProfileDir $f) }
    [pscustomobject]@{ cacheBytes = $cache; profileBytes = (Get-FolderBytes $ProfileDir); pending = (Test-Path -LiteralPath (Get-EdgeCacheFlag)) }
}

function Test-EdgeProfileInUse {
    <# True when an Edge process uses StreamHub's profile (its folders are then locked). #>
    param([string]$ProfileDir = (Get-EdgeProfileDir))
    $needle = $ProfileDir.TrimEnd('\').ToLowerInvariant()
    try {
        [bool](@(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop | Where-Object { "$($_.CommandLine)".ToLowerInvariant().Contains($needle) }).Count)
    } catch { $true }   # unknown: treat as in use (never delete under a running Edge)
}

function Clear-EdgeCacheFolders {
    <# Deletes the cache folders while Edge does not use the profile. Returns the bytes freed, or
       -1 when Edge is running (nothing is touched then). #>
    param([string]$ProfileDir = (Get-EdgeProfileDir))
    if (Test-EdgeProfileInUse $ProfileDir) { return [int64]-1 }
    $freed = [int64]0
    foreach ($f in $script:CacheFolders) {
        $full = Join-Path $ProfileDir $f
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $before = Get-FolderBytes $full
        try { [IO.Directory]::Delete($full, $true); $freed += $before } catch { Write-CCBLog verbose edgecache "Could not remove ${f}: $($_.Exception.Message)" }
    }
    Remove-Item -LiteralPath (Get-EdgeCacheFlag) -ErrorAction SilentlyContinue
    Write-CCBLog info edgecache "Edge caches removed" @{ freedMB = [Math]::Round($freed / 1MB, 1) }
    $freed
}

function Request-EdgeCacheClear {
    <# Clears Edge's caches now as far as possible: the web cache through Edge when it runs (debug
       port $Port), the folders right away when Edge is closed, otherwise at the next start.
       Returns @{ freedNow; pending; info }. #>
    param([int]$Port = 9333)
    $before = Get-EdgeCacheInfo
    $httpCleared = $false
    try {
        $t = Get-CdpPageTarget -Port $Port
        $s = Connect-Cdp $t.webSocketDebuggerUrl
        try { $null = Invoke-Cdp $s 'Network.clearBrowserCache' @{ }; $httpCleared = $true } finally { Disconnect-Cdp $s }
    } catch { Write-CCBLog verbose edgecache "Web cache not cleared through Edge: $($_.Exception.Message)" }
    $freed = Clear-EdgeCacheFolders
    $pending = $false
    if ($freed -lt 0) { [IO.File]::WriteAllText((Get-EdgeCacheFlag), (Get-Date).ToString('s')); $pending = $true }
    $after = Get-EdgeCacheInfo
    $now = [Math]::Max([int64]0, $before.cacheBytes - $after.cacheBytes)
    Write-CCBLog info edgecache 'Edge cache clear asked' @{ freedNowMB = [Math]::Round($now / 1MB, 1); webCache = $httpCleared; pending = $pending }
    [pscustomobject]@{ freedNow = $now; pending = $pending; info = $after }
}

Export-ModuleMember -Function Get-EdgeProfileDir, Get-EdgeCacheFlag, Get-EdgeCacheInfo, Test-EdgeProfileInUse, Clear-EdgeCacheFolders, Request-EdgeCacheClear
