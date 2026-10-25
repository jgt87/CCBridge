# Pester 3.4. Run: Invoke-Pester C:\Files\Apps\CCBridge\tests\ProjectPackage.Tests.ps1
# Packaging a project for a colleague (lib/ProjectPackage.psm1): what goes into the zip, what is left
# out and why, links never followed, open files still packed, and the sharing notes at its root.
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$env:CCBRIDGE_STATE_ROOT = Join-Path $env:TEMP ('ccb-test-state-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Import-Module (Join-Path $root 'lib\ProjectPackage.psm1') -Force
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

function Get-ZipEntries([string]$Path) {
    $z = [IO.Compression.ZipFile]::OpenRead($Path)
    try { @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
}

function Get-ZipText([string]$Path, [string]$Name) {
    $z = [IO.Compression.ZipFile]::OpenRead($Path)
    try { $r = New-Object IO.StreamReader($z.GetEntry($Name).Open()); try { $r.ReadToEnd() } finally { $r.Dispose() } } finally { $z.Dispose() }
}

Describe 'Package for sharing' {
    $proj = Join-Path $env:TEMP ('ccb-package-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $outside = Join-Path $env:TEMP ('ccb-package-outside-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $write = { param($rel, $text) $p = Join-Path $proj $rel; $null = New-Item -ItemType Directory -Force -Path (Split-Path $p); [IO.File]::WriteAllText($p, $text) }
    & $write 'index.html' '<!doctype html><title>Sales</title><script src="dist/app.js"></script>'
    & $write 'dist\app.js' 'console.log(1);'
    & $write 'src\main.js' 'export const a = 1;'
    & $write 'Scripts\Refresh-Data.ps1' '# refresh'
    & $write 'Runbooks\Exports\report.pdf' '%PDF-1.4'
    & $write 'Runbooks\Exports\Old-20260101-0900.zip' 'PK'
    & $write '.streamhub\project.json' '{}'
    & $write '.git\HEAD' 'ref: refs/heads/main'
    & $write 'node_modules\lib\index.js' 'module.exports = 1;'
    & $write 'bin\app.dll' 'MZ'
    & $write '.env' 'API_KEY=abc'
    & $write 'certs\server.pem' '-----BEGIN PRIVATE KEY-----'
    & $write '.env.example' 'API_KEY='
    & $write 'Source\sales.csv' "region,amount`nNorth,10"
    & $write 'docs\~$notes.docx' 'lock'
    & $write 'big.bin' ('x' * 3000)
    $null = New-Item -ItemType Directory -Force -Path $outside
    [IO.File]::WriteAllText((Join-Path $outside 'private.txt'), 'outside the project')
    cmd /c "mklink /J ""$(Join-Path $proj 'linked')"" ""$outside"" >nul 2>&1"
    $now = [datetime]'2026-10-25T09:30:00'

    It 'lists what goes in and what is left out, with the reason' {
        $p = Get-PackageFiles $proj -MaxFileBytes 2000
        $in = @($p.files | ForEach-Object { $_.rel })
        foreach ($f in 'index.html', 'dist/app.js', 'src/main.js', 'Scripts/Refresh-Data.ps1', 'Runbooks/Exports/report.pdf', '.env.example') { $in -contains $f | Should Be $true }
        $why = @{}; foreach ($x in $p.left) { $why[$x.path] = $x.reason }
        $why['.streamhub/'] | Should Be 'streamhub'
        $why['.git/'] | Should Be 'git'
        $why['node_modules/'] | Should Be 'packages'
        $why['bin/'] | Should Be 'build'
        $why['Source/'] | Should Be 'source'
        $why['linked/'] | Should Be 'link'
        $why['.env'] | Should Be 'secret'
        $why['certs/server.pem'] | Should Be 'secret'
        $why['Runbooks/Exports/Old-20260101-0900.zip'] | Should Be 'export'
        $why['docs/~$notes.docx'] | Should Be 'temp'
        $why['big.bin'] | Should Be 'large'
        @($in | Where-Object { $_ -like 'linked/*' }).Count | Should Be 0
    }
    It 'takes Source/ in only when asked' {
        $p = Get-PackageFiles $proj -IncludeSource
        @($p.files | ForEach-Object { $_.rel }) -contains 'Source/sales.csv' | Should Be $true
        @($p.left | Where-Object { $_.reason -eq 'source' }).Count | Should Be 0
    }
    It 'writes the zip with forward-slash entries and the sharing notes, without the left-out files' {
        $r = New-ProjectPackage $proj -MaxFileBytes 2000 -Now $now
        $r.rel | Should Match '^Runbooks/Exports/ccb-package-\w+-20261025-0930\.zip$'
        Test-Path -LiteralPath $r.full | Should Be $true
        $entries = Get-ZipEntries $r.full
        $entries -contains 'index.html' | Should Be $true
        $entries -contains 'dist/app.js' | Should Be $true
        $entries -contains 'README-SHARING.md' | Should Be $true
        @($entries | Where-Object { $_ -match '\\' }).Count | Should Be 0
        foreach ($bad in '.env', 'certs/server.pem', '.streamhub/project.json', '.git/HEAD', 'node_modules/lib/index.js', 'Source/sales.csv', 'linked/private.txt', 'big.bin', 'Runbooks/Exports/Old-20260101-0900.zip') { $entries -contains $bad | Should Be $false }
        $r.files | Should Be ($entries.Count - 1)
        $r.leftByReason['secret'] | Should Be 2
        (Format-PackageSummary $r) | Should Match 'Packed \d+ file\(s\) into Runbooks/Exports/.*Left out: .*passwords, keys or tokens \(\.env, certs/server\.pem\)'
    }
    It 'says in the sharing notes how to open it, what is left out and how to refresh the data' {
        $r = New-ProjectPackage $proj -MaxFileBytes 2000 -Now $now
        $r.rel | Should Match '-20261025-0930-2\.zip$'   # the first one is not overwritten
        $t = Get-ZipText $r.full 'README-SHARING.md'
        $t | Should Match 'Open index\.html in Edge'
        $t | Should Match 'files with passwords, keys or tokens: \.env, certs/server\.pem'
        $t | Should Match 'source data in Source/'
        $t | Should Match 'size limit is 0 MB|size limit is \d+ MB'
        $t | Should Match 'powershell -NoProfile -ExecutionPolicy Bypass -File Scripts\\Refresh-Data\.ps1'
        $t | Should Not Match ([regex]::Escape($env:TEMP))
        # Earlier packages are never packed again.
        Get-ZipEntries $r.full | Where-Object { $_ -like '*.zip' } | Should BeNullOrEmpty
    }
    It 'packs a file another program holds open' {
        $f = Join-Path $proj 'src\main.js'
        $held = New-Object IO.FileStream($f, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        try { $r = New-ProjectPackage $proj -Now $now.AddMinutes(1) } finally { $held.Dispose() }
        (Get-ZipEntries $r.full) -contains 'src/main.js' | Should Be $true
    }
    It 'never touches what the link points to' {
        Test-Path -LiteralPath (Join-Path $outside 'private.txt') | Should Be $true
    }

    cmd /c "rmdir ""$(Join-Path $proj 'linked')"" >nul 2>&1"
    Remove-Item -Recurse -Force $proj, $outside
}

Remove-Item -Recurse -Force $env:CCBRIDGE_STATE_ROOT -ErrorAction SilentlyContinue
