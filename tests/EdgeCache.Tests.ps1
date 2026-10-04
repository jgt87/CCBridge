# Clearing Edge's caches in StreamHub's profile (lib/EdgeCache.psm1): caches go, the sign-in stays.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $root 'lib\EdgeCache.psm1') -Force

Describe 'Edge cache' {
    It 'removes only cache folders, never cookies, storage or extensions, and only while Edge does not use the profile' {
        $p = Join-Path $env:TEMP ('ccb-edge-' + [guid]::NewGuid().ToString('N'))
        $files = @{
            'Default\Cache\Cache_Data\f_0001' = 1000; 'Default\Code Cache\js\a' = 2000; 'GrShaderCache\data_0' = 500; 'component_crx_cache\x.crx' = 700
            'Default\Network\Cookies' = 300; 'Default\Local Storage\leveldb\000003.log' = 200; 'Default\Extensions\abc\1.0\manifest.json' = 100; 'Default\Preferences' = 50
        }
        foreach ($k in $files.Keys) { $full = Join-Path $p $k; New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null; [IO.File]::WriteAllBytes($full, (New-Object byte[] $files[$k])) }
        try {
            (Get-EdgeCacheInfo $p).cacheBytes | Should Be 4200
            Test-EdgeProfileInUse $p | Should Be $false
            Clear-EdgeCacheFolders $p | Should Be 4200
            foreach ($gone in 'Default\Cache', 'Default\Code Cache', 'GrShaderCache', 'component_crx_cache') { Test-Path (Join-Path $p $gone) | Should Be $false }
            foreach ($kept in 'Default\Network\Cookies', 'Default\Local Storage\leveldb\000003.log', 'Default\Extensions\abc\1.0\manifest.json', 'Default\Preferences') { Test-Path (Join-Path $p $kept) | Should Be $true }
            (Get-EdgeCacheInfo $p).cacheBytes | Should Be 0
        } finally { Remove-Item $p -Recurse -Force }
    }
    It 'leaves the folders of a profile Edge is using alone' {
        Mock -ModuleName EdgeCache Test-EdgeProfileInUse { $true }
        $p = Join-Path $env:TEMP ('ccb-edge-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $p 'Default\Cache') | Out-Null
        try {
            Clear-EdgeCacheFolders $p | Should Be -1
            Test-Path (Join-Path $p 'Default\Cache') | Should Be $true
        } finally { Remove-Item $p -Recurse -Force }
    }
}
