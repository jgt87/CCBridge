<#
.SYNOPSIS
  Builds dist\CCBridge-<version>.zip: everything needed to run CCBridge on a target machine
  (no UI source, tests or git data). The zip contains one folder, CCBridge\, with version.txt.
  Then publishes the version: an annotated git tag with the same name on the current commit
  (created locally and pushed), and a GitHub Release "StreamHub <version>" on that tag with
  the zip. A version always has its tag and its release; -NoPublish only builds the zip.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-release.ps1 -Version v0.1.0 -NotesFile notes.md
#>
param(
    [Parameter(Mandatory)][ValidatePattern('^v\d+\.\d+\.\d+$')][string]$Version,
    [string]$NotesFile,
    [switch]$NoPublish
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    # git and gh write progress and "not found" answers to stderr; with 'Stop' PowerShell 5.1 would
    # turn that into a terminating error, so stderr is read as text here and only the exit code counts.
    # Returns @{ code; lines } (lines always an array).
    $saved = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $saved }
    @{ code = $LASTEXITCODE; lines = $out }
}

function Invoke-Git {
    $r = Invoke-Native 'git' (@('-C', $root) + $args)
    if ($r.code) { throw "git $($args -join ' ') failed: $($r.lines -join ' ')" }
    $r.lines   # callers wrap the call in @(): one line stays one string, not its first letter
}

if (-not $NoPublish) {
    # Checks before anything is built: the tag must point at exactly what is in the zip.
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'The GitHub CLI (gh) is needed to publish; use -NoPublish to only build.' }
    if (@(Invoke-Git status --porcelain --untracked-files=no).Count) { throw 'There are uncommitted changes: commit them first, so the tag matches the release.' }
    $null = Invoke-Git fetch --tags origin
    $head = @(Invoke-Git rev-parse HEAD)[0]
    $branch = @(Invoke-Git rev-parse --abbrev-ref HEAD)[0]
    $remote = @(Invoke-Git ls-remote origin "refs/heads/$branch") | Select-Object -First 1
    if (-not $remote -or $remote.Split("`t")[0] -ne $head) { throw "Push $branch first: the release commit must be on GitHub." }
    $existing = @(Invoke-Git tag --list $Version)
    if ($existing.Count) {
        $at = @(Invoke-Git rev-list -n 1 $Version)[0]
        if ($at -ne $head) { throw "Tag $Version already exists on another commit ($($at.Substring(0, 7))). Choose the next version." }
    }
    if (-not (Invoke-Native 'gh' @('release', 'view', $Version, '--json', 'tagName')).code) { throw "Release $Version already exists on GitHub. Choose the next version." }
    if ($NotesFile -and -not (Test-Path -LiteralPath $NotesFile)) { throw "Notes file not found: $NotesFile" }
}

$dist = Join-Path $root 'dist'
$stage = Join-Path $env:TEMP ('ccbridge-release-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$app = Join-Path $stage 'CCBridge'
$null = New-Item -ItemType Directory -Force -Path $app, $dist

$include = @('ccbridge.ps1', 'start.cmd', 'install.ps1', 'check.cmd', 'probe.ps1', 'probe.cmd', 'capture.cmd', 'diagnostics.cmd', 'update.cmd', 'complexity-test.cmd', 'reply-timing.cmd', 'stream-shape.cmd', 'agent-capture.cmd', 'agent-test.cmd', 'render-test.cmd', 'sso-setup.cmd', 'README.md', 'AGENTS.md',
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
if ($NoPublish) { return }

# The tag: annotated, on the commit that was built, locally and on GitHub.
if (-not @(Invoke-Git tag --list $Version).Count) { $null = Invoke-Git tag -a $Version -m "StreamHub $Version" }
$null = Invoke-Git push origin "refs/tags/$Version"
"Tagged $Version at $commit and pushed the tag"

# The release on that tag, with the zip.
$ghArgs = @('release', 'create', $Version, $zip, '--verify-tag', '--title', "StreamHub $Version")
if ($NotesFile) { $ghArgs += @('--notes-file', $NotesFile) } else { $ghArgs += '--generate-notes' }
$r = Invoke-Native 'gh' $ghArgs
if ($r.code) { throw "gh release create failed: $($r.lines -join ' ')" }
"Released: $($r.lines | Select-Object -Last 1)"
$null = Invoke-Git fetch --tags origin   # the local copy knows the new tag right away
