<#
.SYNOPSIS
  Builds dist\CCBridge-<version>.zip: everything needed to run CCBridge on a target machine
  (no UI source, tests or git data). The zip contains one folder, CCBridge\, with version.txt.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-release.ps1 -Version v0.1.0
#>
param([Parameter(Mandatory)][ValidatePattern('^v\d+\.\d+\.\d+$')][string]$Version)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$dist = Join-Path $root 'dist'
$stage = Join-Path $env:TEMP ('ccbridge-release-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$app = Join-Path $stage 'CCBridge'
$null = New-Item -ItemType Directory -Force -Path $app, $dist

$include = @('ccbridge.ps1', 'start.cmd', 'install.ps1', 'probe.ps1', 'probe.cmd', 'capture.cmd', 'diagnostics.cmd', 'update.cmd', 'complexity-test.cmd', 'reply-timing.cmd', 'stream-shape.cmd', 'README.md', 'AGENTS.md',
             'config', 'lib', 'mcp', 'prompts', 'templates', 'tools', 'ui')
foreach ($item in $include) {
    $src = Join-Path $root $item
    if (-not (Test-Path $src)) { throw "missing $item" }
    Copy-Item -LiteralPath $src -Destination $app -Recurse
}
# Never ship machine-specific files.
Get-ChildItem $app -Recurse -File | Where-Object { $_.Name -like '*.local.json' -or $_.Name -in 'capture-report.json', 'probe-report.txt' } |
    ForEach-Object { [IO.File]::Delete($_.FullName) }
[IO.File]::WriteAllText((Join-Path $app 'version.txt'), $Version)
# The commit the release was built from, shown next to the version in the web app.
$commit = try { (& git -C $root rev-parse --short HEAD 2>$null | Select-Object -First 1) } catch { $null }
if ($commit) { [IO.File]::WriteAllText((Join-Path $app 'commit.txt'), "$commit") }

$zip = Join-Path $dist "CCBridge-$Version.zip"
if (Test-Path $zip) { [IO.File]::Delete($zip) }
# Entries are written one by one with "/" separators: .NET Framework's CreateFromDirectory
# stores "\" in entry names, which some unzip tools turn into odd file names.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$fs = [IO.File]::Open($zip, [IO.FileMode]::CreateNew)
$archive = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in Get-ChildItem $stage -Recurse -File) {
        $name = $f.FullName.Substring($stage.Length + 1).Replace('\', '/')
        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $name, [IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $archive.Dispose(); $fs.Dispose() }
[IO.Directory]::Delete($stage, $true)
$size = (Get-Item $zip).Length
"Built $zip ($([Math]::Round($size / 1KB)) KB)"
